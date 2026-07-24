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

#endif
