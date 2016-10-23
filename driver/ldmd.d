//===-- driver/ldmd.d - General LLVM codegen helpers ----------*- D -*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
// Wrapper allowing use of LDC as drop-in replacement for DMD.
//
// The reason why full command line parsing is required instead of just
// rewriting the names of a few switches is an annoying impedance mismatch
// between the way how DMD handles arguments and the LLVM command line library:
// DMD allows all switches to be specified multiple times – in case of
// conflicts, the last one takes precedence. There is no easy way to replicate
// this behavior with LLVM, save parsing the switches and re-emitting a cleaned
// up string.
//
// DMD also reads switches from the DFLAGS enviroment variable, if present. This
// is contrary to what C compilers do, where CFLAGS is usually handled by the
// build system. Thus, conflicts like mentioned above occur quite frequently in
// practice in makefiles written for DMD, as DFLAGS is also a natural name for
// handling flags there.
//
// In order to maintain backwards compatibility with earlier versions of LDMD,
// unknown switches are passed through verbatim to LDC. Finding a better
// solution for this is tricky, as some of the LLVM arguments can be
// intentionally specified multiple times to get a certain effect (e.g. pass,
// linker options).
//
// Just as with the old LDMD script, arguments can be passed through unmodified
// to LDC by using -Csomearg.
//
// If maintaining this wrapper is deemed too messy at some point, an alternative
// would be to either extend the LLVM command line library to support the DMD
// semantics (unlikely to happen), or to abandon it altogether (except for
// passing the LLVM-defined flags to the various passes).
//
// Note: This program inherited ugly C-style string handling and memory leaks
// from DMD, but this should not be a problem due to the short-livedness of
// the process.
//
//===----------------------------------------------------------------------===//


// We reuse DMD's response file parsing routine for maximum compatibilty - it
// handles quotes in a very peculiar way.
extern(C++) int response_expand(size_t *pargc, char ***pargv);
extern(C++) void browse(const char *url);


/// Prints a formatted error message to stderr and exit program
void error(Args...)(string fmt, Args args)
{
    import std.stdio : stderr;
    stderr.write("Error: ");
    stderr.writefln(fmt, args);
    cleanExit(1);
}


/// Prints a formatted warning message to stderr
void warning(Args...)(string fmt, Args args)
{
    import std.stdio : stderr;
    stderr.write("Warning: ");
    stderr.writefln(fmt, args);
}


/// Terminates D runtime and exits program
void cleanExit(int exitCode=0)
{
    import core.runtime : Runtime;
    import core.stdc.stdlib : exit;
    Runtime.terminate();
    exit(exitCode);
}


/// execute the given program with args
int execute(string [] args)
{
    import std.process : spawnProcess, wait;
    return wait(spawnProcess(args));
}


/// Print usage information to stdout
void printUsage(in string argv0, in string ldcPath)
{
    auto fmt = "
Usage:
  dmd files.d ... { -switch }

  files.d        D source files
  @cmdfile       read arguments from cmdfile
  -allinst       generate code for all template instantiations
  -betterC       omit generating some runtime information and helper functions
  -boundscheck=[on|safeonly|off]   bounds checks on, in @safe only, or off
  -c             do not link
  -color[=on|off]   force colored console output on or off
  -conf=path     use config file at path
  -cov           do code coverage analysis
  -cov=nnn       require at least nnn%% code coverage
  -D             generate documentation
  -Dddocdir      write documentation file to docdir directory
  -Dffilename    write documentation file to filename
  -d             silently allow deprecated features
  -dw            show use of deprecated features as warnings (default)
  -de            show use of deprecated features as errors (halt compilation)
  -debug         compile in debug code
  -debug=level   compile in debug code <= level
  -debug=ident   compile in debug code identified by ident
  -debuglib=name    set symbolic debug library to name
  -defaultlib=name  set default library to name
  -deps          print module dependencies (imports/file/version/debug/lib)
  -deps=filename write module dependencies to filename (only imports)
  -dip25         implement http://wiki.dlang.org/DIP25 (experimental)
  -g             add symbolic debug info
  -gc            add symbolic debug info, optimize for non D debuggers
  -gs            always emit stack frame
  -gx            add stack stomp code
  -H             generate 'header' file
  -Hddirectory   write 'header' file to directory
  -Hffilename    write 'header' file to filename
  --help         print help and exit
  -Ipath         where to look for imports
  -ignore        ignore unsupported pragmas
  -inline        do function inlining
  -Jpath         where to look for string imports
  -Llinkerflag   pass linkerflag to link
  -lib           generate library rather than object files
  -m32           generate 32 bit code
  -m64           generate 64 bit code
  -main          add default main() (e.g. for unittesting)
  -man           open web browser on manual page\n";
static if (false)
{
    fmt ~= "-map           generate linker .map file";
}
    fmt ~= "
  -noboundscheck no array bounds checking (deprecated, use -boundscheck=off)
  -O             optimize
  -o-            do not write object file
  -odobjdir      write object & library files to directory objdir
  -offilename    name output file to filename
  -op            preserve source path for output files\n";
static if (false)
{
    fmt ~= "-profile       profile runtime performance of generated code";
}
    fmt ~= "
  -profile=gc    profile runtime allocations
  -release       compile release version
  -run srcfile args...   run resulting program, passing args
  -shared        generate shared library (DLL)
  -transition=id help with language change identified by 'id'
  -transition=?  list all language changes
  -unittest      compile in unit tests
  -v             verbose
  -vcolumns      print character (column) numbers in diagnostics
  -verrors=num   limit the number of error messages (0 means unlimited)
  -vgc           list all gc allocations including hidden ones
  -vtls          list all variables going into thread local storage
  --version      print compiler version and exit
  -version=level compile in version code >= level
  -version=ident compile in version code identified by ident
  -w             warnings as errors (compilation will halt)
  -wi            warnings as messages (compilation will continue)
  -X             generate JSON file
  -Xffilename    write JSON file to filename\n\n";

    import std.stdio : stdout;

    execute([ldcPath, "-version"]);
    stdout.writefln(fmt, argv0);
}


/// Parses an enviroment variable for flags and returns them as a list of
/// arguments.
///
/// This corresponds to getenv_setargv() in DMD, but we need to duplicate it
/// here since it is defined as private in mars.d.
string[] parseEnvVar(string envVarName)
{
    import std.process : environment;

    string[] args;
    string arg;
    bool escape;
    bool quote;

    foreach(char c; environment.get(envVarName))
    {
        switch (c)
        {
            case '\\':
                if (escape) arg ~= c;
                escape = !escape;
                break;
            case '"':
                if (escape)
                {
                    arg ~= c;
                    escape = false;
                }
                else quote = !quote;
                break;
            case ' ':
            case '\t':
                if (quote) arg ~= c;
                else if (arg.length)
                {
                    args ~= arg;
                    arg = "";
                }
                break;
            default:
                if (escape) error(
                    `unknown escape sequence in %s: \%s`,
                    envVarName, c
                );
                arg ~= c;
                break;
        }
    }

    if (arg.length) args ~= arg;

    return args;
}

unittest
{
    import std.process : environment;

    enum varName = "LDMD_UNITTEST_PARSEENVVAR";
    environment[varName] =
        `-dflag1 -dflag2 -dflag3="some string with \\ \" chars and \\ "`;
    auto args = parseEnvVar(varName);
    environment.remove(varName);

    assert(args.length == 3);
    assert(args[0] == "-dflag1");
    assert(args[1] == "-dflag2");
    assert(args[2] == `-dflag3=some string with \ " chars and \ `);
}


enum BoundsCheck
{
    defaultVal, off, safeOnly, on
}

enum Color
{
    automatic, on, off
}

enum Debug
{
    none, normal, pretendC
}

enum Deprecated
{
    allow, warn, error
}

enum Model
{
    automatic, m32, m64
}

enum Warnings
{
    none, asErrors, informational
}

struct Params
{
    bool allinst;
    Deprecated useDeprecated = Deprecated.warn;
    bool compileOnly;
    bool coverage;
    bool emitSharedLib;
    bool pic;
    bool emitMap;
    bool multiObj;
    Debug debugInfo = Debug.none;
    bool alwaysStackFrame;
    Model targetModel = Model.automatic;
    bool profile;
    bool verbose;
    bool vcolumns;
    bool vdmd;
    bool vgc;
    bool logTlsUse;
    uint errorLimit;
    bool errorLimitSet;
    Warnings warnings = Warnings.none;
    bool optimize;
    bool noObj;
    string objDir;
    string objName;
    bool preservePaths;
    bool generateDocs;
    string docDir;
    string docName;
    bool generateHeaders;
    string headerDir;
    string headerName;
    bool generateJson;
    string jsonName;
    bool ignoreUnsupportedPragmas;
    bool enforcePropertySyntax;
    bool enableInline;
    bool emitStaticLib;
    bool quiet;
    bool release;
    BoundsCheck boundsChecks = BoundsCheck.defaultVal;
    bool emitUnitTests;
    string[] modulePaths;
    string[] importPaths;
    bool debugFlag;
    uint debugLevel;
    string[] debugIdentifiers;
    uint versionLevel;
    string[] versionIdentifiers;
    string[] linkerSwitches;
    string[] transitions;
    string defaultLibName;
    string debugLibName;
    string moduleDepsFile;
    bool printModuleDeps;
    Color color = Color.automatic;
    bool useDIP25;
    string conf;

    bool hiddenDebugB;
    bool hiddenDebugC;
    bool hiddenDebugF;
    bool hiddenDebugR;
    bool hiddenDebugX;
    bool hiddenDebugY;

    string[] unknownSwitches;

    bool run;
    string[] files;
    string[] runArgs;
}


Params parseArgs (string[] originalArgs, in string ldcPath)
{
    import std.string : fromStringz, toStringz;
    import std.algorithm : map, canFind, startsWith;

    string[] args;

    // response_expand is in C++ and expects C-strings
    // that need to be converted front and back with allocations
    // at each step.
    // we only do that if one switch starts with '@'
    if (originalArgs.map!(a => a[0]).canFind('@'))
    {
        import core.stdc.stdlib : malloc, free;
        import core.stdc.string : memcpy;

        auto argc = args.length;
        char**argv = cast(char**)malloc(argc * (char*).sizeof);
        foreach(i, a; originalArgs)
        {
            char *s = cast(char*)malloc(a.length+1);
            memcpy(s, a.ptr, a.length);
            s[a.length - 1] = '\0';
            argv[i] = s;
        }
        if (response_expand(&argc, &argv))
        {
            error("Could not read response file");
        }
        args = new string[argc];
        for (size_t i=0; i<argc; ++i)
        {
            args[i] = fromStringz(argv[i]).idup;
            free(argv[i]);
        }
        free(argv);
    }
    else
    {
        args = originalArgs;
    }

    args ~= parseEnvVar("DFLAGS");

    Params result;


    argLoop:
    for (size_t i = 1; i < originalArgs.length; ++i)
    {
        string a = originalArgs[i];

        void noArg()
        {
            error("argument expected for switch %s", a);
        }

        void argError()
        {
            result.unknownSwitches ~= a;
        }

        if (a[0] == '-')
        {
            auto p = a[1 .. $];
            if (p == "allinst") result.allinst = true;
            else if (p == "de") result.useDeprecated = Deprecated.error;
            else if (p == "d") result.useDeprecated = Deprecated.error;
            else if (p == "dw") result.useDeprecated = Deprecated.warn;
            else if (p == "c") result.compileOnly = true;
            else if (p.startsWith("color"))
            {
                result.color = Color.on;
                p = p[5 .. $];
                if (p == "=off") result.color = Color.off;
                else if (p != "=on") argError();
            }
            else if (p.startsWith("conf=")) result.conf = p[5 .. $];
            // FIXME: ldmd.cpp calls `strcmp(p+1, "cov")==0` hence `p == "cov"` here
            //        but this will not return 0 if p[4] != '\0'
            //        it means that result.coverage always set to true
            //        and "-cov=..." case is not tested at all
            else if (p == "cov")
            {
                // For "-cov=...", the whole cmdline switch is forwarded to LDC.
                // For plain "-cov", the cmdline switch must be explicitly forwarded
                // and result.coverage must be set to true to that effect.
                //result.coverage = (p[3] != '=');
                result.coverage = true;
            }
            else if (p == "dip25") result.useDIP25 = true;
            // backward compatibility with old dylib switch
            else if (p == "shared" || p == "dylib") result.emitSharedLib = true;
            else if (p == "fPIC") result.pic = true;
            else if (p == "map") result.emitMap = true;
            else if (p == "multiobj") result.multiObj = true;
            else if (p == "g") result.debugInfo = Debug.normal;
            else if (p == "gc") result.debugInfo = Debug.pretendC;
            else if (p == "gs") result.alwaysStackFrame = true;
            else if (p == "gt") error("use -profile instead of -gt");
            else if (p == "m32") result.targetModel = Model.m32;
            else if (p == "m64") result.targetModel = Model.m64;
            else if (p == "profile") result.profile = true;
            else if (p.startsWith("transition=")) result.transitions ~= p[11 .. $];
            else if (p == "v") result.verbose = true;
            else if (p == "vcolumns") result.vcolumns = true;
            else if (p == "vdmd") result.vdmd = true;
            else if (p == "vgc") result.vgc = true;
            else if (p == "vtls") result.logTlsUse = true;
            else if (p == "v1") error("use DMD 1.0 series compiles for -v1 switch");
            else if (p.startsWith("verrors"))
            {
                import std.ascii : isDigit;
                import std.conv : to;
                p = p[7 .. $];
                if (p.length >= 2 && p[0] == '=')
                {
                    p = p[1 .. $];
                    try
                    {
                        result.errorLimit = p.to!uint;
                        result.errorLimitSet = true;
                    }
                    catch (Exception) argError();
                }
                else argError();
            }
            else if (p == "w") result.warnings = Warnings.asErrors;
            else if (p == "wi") result.warnings = Warnings.informational;
            else if (p == "O") result.optimize = true;
            else if (p.startsWith("o"))
            {
                p = p[1 .. $];
                if (!p.length) error("-o no longer supported, use -of or -od");
                switch (p[0]) {
                case '-':
                    result.noObj = true;
                    break;
                case 'd':
                    if (p.length < 2) noArg();
                    result.objDir = p[1 .. $];
                    break;
                case 'f':
                    if (p.length < 2) noArg();
                    result.objName = p[1 .. $];
                    break;
                case 'p':
                    if (p.length > 1) argError();
                    result.preservePaths = true;
                    break;
                default:
                    result.unknownSwitches ~= a;
                    continue argLoop;
                }
            }
            else if (p == "D") result.generateDocs = true;
            else if (p.startsWith("Dd"))
            {
                result.generateDocs = true;
                if (p.length < 3) noArg();
                result.docDir = p[2 .. $];
            }
            else if (p.startsWith("Df"))
            {
                result.generateDocs = true;
                if (p.length < 3) noArg();
                result.docName = p[2 .. $];
            }
            else if (p == "H") result.generateHeaders = true;
            else if (p.startsWith("Hd"))
            {
                result.generateHeaders = true;
                if (p.length < 3) noArg();
                result.headerDir = p[2 .. $];
            }
            else if (p.startsWith("Hf"))
            {
                result.generateHeaders = true;
                if (p.length < 3) noArg();
                result.headerName = p[2 .. $];
            }
            else if (p == "X") result.generateJson = true;
            else if (p.startsWith("Xf"))
            {
                result.generateJson = true;
                if (p.length < 3) noArg();
                result.jsonName = p[2 .. $];
            }
            else if (p == "ignore") result.ignoreUnsupportedPragmas = true;
            else if (p == "property") result.enforcePropertySyntax = true;
            else if (p == "inline") result.enableInline = true;
            else if (p == "lib") result.emitStaticLib = true;
            else if (p == "quiet") result.quiet = true;
            else if (p == "release") result.release = true;
            else if (p == "noboundscheck")
            {
                warning("The -noboundscheck switch is deprecated, " ~
                    "use -boundscheck=off instead.");
                result.boundsChecks = BoundsCheck.off;
            }
            else if (p == "boundscheck=on") result.boundsChecks = BoundsCheck.on;
            else if (p == "boundscheck=safeonly") result.boundsChecks = BoundsCheck.safeOnly;
            else if (p == "boundscheck=off") result.boundsChecks = BoundsCheck.off;
            else if (p == "unittest") result.emitUnitTests = true;
            else if (p.startsWith("I")) result.modulePaths ~= p[1 .. $];
            else if (p.startsWith("J")) result.importPaths ~= p[1 .. $];
            else if (p.startsWith("debug") &&
                    (p.length == 5 || (p.length > 6 && p[5] == '=')))
            {
                // Parse:
                //      -debug
                //      -debug=number
                //      -debug=identifier
                import std.ascii : isDigit;
                import std.conv : to;
                if (p.length == 5) result.debugFlag = true;
                else if (isDigit(p[6]))
                {
                    try
                    {
                        result.debugLevel = p[6 .. $].to!int;
                    }
                    catch(Exception) argError();
                }
                else result.debugIdentifiers ~= p[6 .. $];
            }
            else if (p.startsWith("version=") && p.length > 8)
            {
                // Parse:
                //      -version=number
                //      -version=identifier
                import std.ascii : isDigit;
                import std.conv : to;
                if (isDigit(p[8]))
                {
                    try
                    {
                        result.versionLevel = p[8 .. $].to!int;
                    }
                    catch(Exception) argError();
                }
                else result.versionIdentifiers ~= p[8 .. $];
            }
            else if (p == "-b") result.hiddenDebugB = true;
            else if (p == "-c") result.hiddenDebugC = true;
            else if (p == "-f") result.hiddenDebugF = true;
            else if (p == "-help")
            {
                printUsage(originalArgs[0], ldcPath);
                cleanExit(0);
            }
            else if (p == "-version")
            {
                execute([ldcPath, "--version"]);
                cleanExit(0);
            }
            else if (p == "-r") result.hiddenDebugR = true;
            else if (p == "-x") result.hiddenDebugX = true;
            else if (p == "-y") result.hiddenDebugY = true;
            else if (p.startsWith("L")) result.linkerSwitches ~= p[1 .. $];
            else if (p.startsWith("defaultlib="))
                result.defaultLibName = p[11 .. $];
            else if (p.startsWith("debuglib="))
                result.debugLibName = p[9 .. $];
            else if (p.startsWith("deps=")) result.moduleDepsFile = p[5 .. $];
            else if (p == "deps") result.printModuleDeps = true;
            else if (p == "man")
            {
                browse("http://wiki.dlang.org/LDC");
                cleanExit(0);
            }
            else if (p == "run")
            {
                auto runargCount = (
                        (i >= originalArgs.length) ?
                            args.length :
                            originalArgs.length
                    ) - i - 1;
                if (runargCount)
                {
                    result.run = true;
                    result.files ~= args[i + 1];
                    result.runArgs = args[i+2 .. i+runargCount+1];
                    i += runargCount;
                }
                else noArg();
            }
            else if (p.startsWith("C"))
            {
                result.unknownSwitches ~= "-"~p[2 .. $];
            }
            else
            {
                result.unknownSwitches ~= a;
            }
        }
        else
        {
            // FIXME: static if (target windows) {
            import std.path : extension;
            if (extension(a) == ".exe")
            {
                result.objName = a;
                continue argLoop;
            }
            // }
            result.files ~= a;
        }

    }

    if (!result.files.length)
    {
        printUsage(originalArgs[0], ldcPath);
        error("No source file specified.");
    }

    return result;
}

/**
 * Appends the LDC command line parameters corresponding to the given set of
 * parameters to r.
 */
void buildCommandLine(ref string[] args, in ref Params p)
{
    import std.format : format;

    void pushSwitches(in string prefix, in string[] vals)
    {
        import std.algorithm : each, map;
        vals.map!(v => prefix~v).each!(sw => args ~= sw);
    }

    if (p.allinst) args ~= "-allinst";

    if (p.useDeprecated == Deprecated.allow) args ~= "-d";
    else if (p.useDeprecated == Deprecated.error) args ~= "-de";

    if (p.compileOnly) args ~= "-c";

    if (p.coverage) args ~= "-cov";

    if (p.emitSharedLib) args ~= "-shared";

    if (p.pic) args ~= "-relocation-model=pic";

    if (p.emitMap)
        warning("Map file generation not yet supported by LDC.");

    if (!p.emitStaticLib && ((!p.multiObj && !p.compileOnly) || p.objName.length))
        args ~= "-singleobj";

    if (p.debugInfo == Debug.normal) args ~= "-g";
    else if (p.debugInfo == Debug.pretendC) args ~= "-gc";

    if (p.alwaysStackFrame) args ~= "-disable-fp-elim";

    if (p.targetModel == Model.m32) args ~= "-m32";
    else if (p.targetModel == Model.m64) args ~= "-m64";

    if (p.profile)
        warning("CPU profile generation not yet supported by LDC.");

    if (p.verbose) args ~= "-v";

    if (p.vcolumns) args ~= "-vcolumns";

    if (p.vgc) args ~= "-vgc";

    if (p.logTlsUse) args ~= "-transition=tls";

    if (p.errorLimitSet)
        args ~= format("-verrors=%s", p.errorLimit);

    if (p.warnings == Warnings.asErrors) args ~= "-w";
    else if (p.warnings == Warnings.informational) args ~= "-wi";

    if (p.optimize) args ~= "-O3";

    if (p.noObj) args ~= "-o-";
    if (p.objDir.length) args ~= format("-od=%s", p.objDir);
    if (p.objName.length) args ~= format("-of=%s", p.objName);

    if (p.preservePaths) args ~= "-op";

    if (p.generateDocs) args ~= "-D";
    if (p.docDir.length) args ~= format("-Dd=%s", p.docDir);
    if (p.docName.length) args ~= format("-Df=%s", p.docName);

    if (p.generateHeaders) args ~= "-H";
    if (p.headerDir.length) args ~= format("-Hd=%s", p.headerDir);
    if (p.headerName.length) args ~= format("-Hf=%s", p.headerName);

    if (p.generateJson) args ~= "-X";
    if (p.jsonName.length) args ~= format("-Xf=%s", p.jsonName);

    if (p.ignoreUnsupportedPragmas) args ~= "-ignore";

    if (p.enforcePropertySyntax) args ~= "-property";

    if (p.enableInline)
    {
        // -inline also influences .di generation with DMD.
        args ~= "-enable-inlining";
        args ~= "-Hkeep-all-bodies";
    }

    if (p.emitStaticLib) args ~= "-lib";

    // -quiet is the default in (newer?) frontend versions, just ignore it.

    if (p.release) args ~= "-release"; // Also disables boundscheck

    if (p.boundsChecks == BoundsCheck.on)
        args ~= "-boundscheck=on";
    else if (p.boundsChecks == BoundsCheck.safeOnly)
        args ~= "-boundscheck=safeonly";
    else if (p.boundsChecks == BoundsCheck.off)
        args ~= "-boundscheck=off";

    if (p.emitUnitTests) args ~= "-unittest";

    pushSwitches("-I=", p.modulePaths);

    pushSwitches("-J=", p.importPaths);

    if (p.debugFlag) args ~= "-d-debug";
    if (p.debugLevel) args ~= format("-d-debug=%s", p.debugLevel);
    pushSwitches("-d-debug=", p.debugIdentifiers);

    if (p.versionLevel) args ~= format("-d-version=%s", p.versionLevel);
    pushSwitches("-d-version=", p.versionIdentifiers);

    pushSwitches("-L=", p.linkerSwitches);

    pushSwitches("-transition=", p.transitions);

    if (p.defaultLibName.length) args ~= format("-defaultlib=%s", p.defaultLibName);

    if (p.moduleDepsFile.length) args ~= format("-deps=%s", p.moduleDepsFile);
    if (p.printModuleDeps) args ~= "-deps";

    if (p.color == Color.on) args ~= "-enable-color";
    else if (p.color == Color.off) args ~= "-disable-color";

    if (p.useDIP25) args ~= "-dip25";

    if (p.conf.length) args ~= format("-conf=%s", p.conf);

    if (p.hiddenDebugB) args ~= "-hidden-debug-b";
    if (p.hiddenDebugC) args ~= "-hidden-debug-c";
    if (p.hiddenDebugF) args ~= "-hidden-debug-f";
    if (p.hiddenDebugR) args ~= "-hidden-debug-r";
    if (p.hiddenDebugX) args ~= "-hidden-debug-x";
    if (p.hiddenDebugY) args ~= "-hidden-debug-y";

    args ~= p.unknownSwitches;

    if (p.run) args ~= "-run";

    args ~= p.files;

    args ~= p.runArgs;
}


/// Returns the OS-dependent length limit for the command line when invoking
/// subprocesses.
size_t maxCommandLineLen()
{
    version(Posix)
    {
        import core.sys.posix.unistd : sysconf, _SC_ARG_MAX;
        // http://www.in-ulm.de/~mascheck/various/argmax – the factor 2 is just
        // a wild guess to account for the enviroment.
        return sysconf(_SC_ARG_MAX) / 2;
    }
    else version(Windows)
    {
        // http://blogs.msdn.com/b/oldnewthing/archive/2003/12/10/56028.aspx
        return 32767;
    }
    else
    {
        static assert(false,
            "Do not know how to determine maximum command line length.");
    }
}

/// returns whether the given exeName has execution permissions
bool canExecute(string exeName)
{
    version(Windows)
    {
        import std.file : exists;
        return exists(exeName) || exists(exeName ~ ".exe");
    }
    version (Posix)
    {
        import core.sys.posix.unistd : access, R_OK, X_OK;
        import std.string : toStringz;

        enum mode = R_OK | X_OK;
        return !access(toStringz(exeName), mode);
    }
}

/// find a program by name within Path environment variable
string findProgramByName(string exeName)
{
    version (Posix)
    {
        import std.algorithm : splitter;
        import std.path : chainPath;
        import std.process : environment;
        import std.conv : to;

        auto paths = splitter(environment["PATH"], ':');
        foreach (p; paths)
        {
            auto exePath = chainPath(p, exeName).to!string;
            if (canExecute(exePath)) return exePath;
        }
    }
    version (Windows)
    {
        import std.algorithm : splitter;
        import std.process : environment;
        import std.conv : to;
        import core.sys.windows.winbase : SearchPathW;

        auto pathExts = environment.get("PATHEXT", ";.exe").splitter(';');
        foreach (ext; pathExts)
        {
            enum bufSize = 1024;
            wchar[bufSize] staticBuf;
            wchar[] buf = staticBuf[];
            immutable fullExeName = exeName ~ ext;
            immutable len = SearchPathW(null, toStringz(fullExeName), null, bufSize, buf.ptr, null);
            if (len > 0)
            {
                if (len > buf.length)
                {
                    buf = new wchar[len];
                    enforce(SearchPathW(null, toStringz(fullExeName), null, len, buf.ptr, null) == len);
                    return buf[0 .. len-1].to!string;
                }
                else
                {
                    return buf[0 .. len].to!string;
                }
            }
        }
    }
    return "";
}

/// Tries to locate an executable with the given name, or an invalid path if
/// nothing was found. Search paths:
///    1. Directory where this binary resides.
///    2. System PATH.
string locateBinary(string exeName)
{
    import driver.exe_path : prependBinDir;

    auto path = prependBinDir(exeName);
    if (canExecute(path)) return path;

    return findProgramByName(exeName);
}



/// Generate a unique filename based on provided model.
/// Every '%' in model will be replaced by a random hexa char (from 0 to f).
/// The function checks that the proposed filename does not exist.
string getUniqueTempFile(string model)
{
    import std.file : tempDir, exists, isDir;
    import std.path : chainPath;
    import std.conv : to;
    import std.random : uniform;

    string result;
    immutable td = tempDir();
    enum maxAttempts = 32;
    int attempts = 0;
    do
    {
        auto fn = model.dup;
        foreach (ref c; fn)
        {
            if (c == '%') c = "0123456789abcdef"[uniform(0, 15)];
        }
        result = chainPath(td, fn).to!string;
        ++attempts;
    }
    while(attempts < maxAttempts && (!exists(result) || isDir(result)));

    if (attempts >= maxAttempts)
        error("Cannot generate a unique file name");

    return result;
}

// In driver/exe_path.cpp
extern(C++, exe_path) void initialize(const(char)* argv0);

/+ Having a main() in D-source solves a few issues with building/linking with
 + DMD on Windows, with the extra benefit of implicitly initializing the D runtime.
 +/
int main(string[] args)
{
    import core.memory : GC;
    import core.runtime : Runtime;
    import std.string : toStringz;
    import std.stdio : write, writeln;
    import std.algorithm : map, sum;
    import std.file : remove;

    // For now, even just the frontend does not work with GC enabled, so we need
    // to disable it entirely.
    GC.disable();

    // initialize exe_path C++ module
    exe_path.initialize(toStringz(args[0]));

    string ldcExeName = import("LDC_EXE_NAME");
    // ".exe" is handled by findProgramByName
    // version (Windows)
    // {
    //     ldcExeName ~= ".exe";
    // }
    string ldcPath = locateBinary(ldcExeName);
    if (!ldcPath.length) error("Could not locate "~ldcExeName~"executable");

    string[] ldcArgs = [ ldcPath ];
    Params p = parseArgs(args, ldcPath);
    buildCommandLine(ldcArgs, p);
    if (p.vdmd)
    {
        write(" -- Invoking:");
        foreach (arg; ldcArgs) write(" " ~ arg);
        writeln();
    }

    // Check if we need to write out a response file.
    // FIXME: is this really useful? response file is exanded into
    //        command line args by LDMD, not processed by LDC
    immutable totalLen = args.map!(a => a.length).sum();
    if (totalLen > maxCommandLineLen())
    {
        // we need to write a response file
        auto rspFn = getUniqueTempFile("ldmd-%%-%%-%%-%%.rsp");
        {
            import std.stdio : File;

            auto rspF = File(rspFn, "w");
            foreach (a; ldcArgs[1..$]) // leave out ldcArgs[0] (exe name)
            {
                rspF.writeln(a);
            }
        }
        string rspArg = "@" ~ rspFn;
        immutable code = execute([args[0]] ~ rspArg);
        remove(rspFn);
        return code;
    }

    return execute(ldcArgs);
}
