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


/// Print usage information to stdout
void printUsage(in string argv0, in string ldcPath)
{
    import std.process : execute;
    import std.stdio : stdout;

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
    import std.process : enviroment;

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

// In driver/ldmd.cpp
extern(C++) int cppmain(int argc, char **argv);

/+ Having a main() in D-source solves a few issues with building/linking with
 + DMD on Windows, with the extra benefit of implicitly initializing the D runtime.
 +/
int main()
{
    // For now, even just the frontend does not work with GC enabled, so we need
    // to disable it entirely.
    import core.memory;
    GC.disable();

    import core.runtime;
    auto args = Runtime.cArgs();
    return cppmain(args.argc, cast(char**)args.argv);
}
