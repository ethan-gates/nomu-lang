target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32-ni:1"
target triple = "arm64-apple-macosx15.0.0"
declare void @stop()
declare void @use(ptr addrspace(1))
declare i64 @read(ptr addrspace(1))
declare ptr addrspace(1) @nomu.frame.addr(ptr)
define i64 @f() gc "statepoint-example" {
  %slot = alloca [4 x i64], align 8
  %p = call ptr addrspace(1) @nomu.frame.addr(ptr %slot) "gc-leaf-function"
  call void @use(ptr addrspace(1) %p)
  call void @stop()
  %q = getelementptr i8, ptr addrspace(1) %p, i64 8
  %v = call i64 @read(ptr addrspace(1) %q) "gc-leaf-function"
  ret i64 %v
}
