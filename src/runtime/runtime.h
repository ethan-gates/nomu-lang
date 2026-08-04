// Nomu runtime — shared ABI (M4.13).
//
// The boundary between generated user code, the C core floor, and the privileged
// runtime. Anything the generated `user.c` or the other C files call is declared
// here; each `.c` includes this header. (Design: m4.13-spec.md; compiler.md §1.)
#ifndef NOMU_RUNTIME_H
#define NOMU_RUNTIME_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>    // generated code lowers `print` to printf
#include <pthread.h>  // generated actor code uses pthread_mutex_t directly

// ---- Shared object model ----
typedef struct { size_t refcount; } ObjectHeader;

// A closure value: code pointer + captured environment (heap-allocated, bump-and-leak).
typedef struct { void* fn; void* env; } Closure;

// String: length-prefixed, null-terminated, heap-allocated data.
typedef struct { char* data; int64_t len; } String;

// A fiber is opaque outside the privileged runtime; generated code only holds handles.
typedef struct Fiber Fiber;

// A structured spawn handle: a fiber whose result we will join.
typedef struct { Fiber* fiber; } SpawnHandle;

// ---- Allocation seam (privileged; the heap alloc/free the generated code uses) ----
void* rt_alloc(size_t size);
void  rt_free(void* p);

// ---- Core floor: pure value primitives ----
String rt_str_lit(const char* data, int64_t len);
String rt_str_concat(String a, String b);

// ---- Privileged: blocking primitives + structured concurrency ----
int64_t rt_sleep_ms(int64_t ms);
String  rt_read_line(int fd);
Fiber*  fiber_spawn(void* (*fn)(void*), void* arg);
void*   spawn_join(SpawnHandle* h);

// ---- Actor mutex (opaque, heap-allocated) ----
// The C backend inlines a `pthread_mutex_t` in the actor struct; the LLVM backend has no portable
// `pthread_mutex_t` layout, so it holds an opaque `void*` to a runtime-allocated mutex instead.
void* rt_mutex_new(void);
void  rt_mutex_lock(void* m);
void  rt_mutex_unlock(void* m);

// ---- GC root scanning (M8.4.3; m8.4-spec.md D4) ----
// Parse the process's `__llvm_stackmaps` section into a return-address → live-GC-slot index.
// Idempotent; called lazily by the walk. Inert until M6 turns on collection.
void nomu_gc_stackmap_init(void);
// Called once per distinct live GC root found while walking a stack: `slot` is the stack address
// the pointer lives at, `value` is the pointer. (M6's collector updates `*slot` on relocation.)
typedef void (*nomu_root_visitor)(void** slot, void* value, void* userdata);
// Walk the current stack for GC roots, from the caller's frame up, invoking `visit` per root
// (D4 single-stack walk). Shaped for M6 reuse: it drives a libunwind cursor, so a parked fiber's
// saved context can be walked the same way (M6 passes the fiber's context instead of the current).
void nomu_gc_walk_current(nomu_root_visitor visit, void* userdata);

#endif
