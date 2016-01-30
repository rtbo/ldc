// Tests LDC-specific attributes

// RUN: %ldc -O -c -output-ll -of=%t.ll %s && FileCheck %s < %t.ll

import ldc.attributes;

//---- @(section) -----------------------------------------------------

// CHECK-DAG: @{{.*}}mySectionedGlobali ={{.*}} section ".mySection"
@(section(".mySection")) int mySectionedGlobal;

// CHECK-DAG: define void @{{.*}}sectionedfoo{{.*}} section "funcSection"
@(section("funcSection")) void sectionedfoo() {}

//---------------------------------------------------------------------


// CHECK-LABEL: define i32 @_Dmain
void main() {
  sectionedfoo();
}