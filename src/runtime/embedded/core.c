// Nomu core floor (M4.13) — the C primitive value operations that Nomu can't yet
// express (String has no in-language buffer primitive). Pure: depends only on the
// allocation seam. Shrinks as primitives migrate into the Nomu stdlib.
// (Design: m4.13-spec.md §1, the standard-library C floor.)
#include "runtime.h"
#include <stdint.h>
#include <string.h>
#include <stdlib.h>   // strtod — shortest round-trip Double formatting
#include <time.h>

// Print a Double: the fewest significant digits that round-trip back to the same value, always
// with a decimal point (so a whole-valued Double reads as `42.0`, never `42`), then a newline.
void rt_print_double(double x) {
    char buf[32];
    // 17 significant digits round-trip any IEEE-754 double; stop at the first precision that does.
    int prec = 17;
    for (int p = 1; p < 17; p++) {
        snprintf(buf, sizeof buf, "%.*g", p, x);
        if (strtod(buf, NULL) == x) { prec = p; break; }
    }
    snprintf(buf, sizeof buf, "%.*g", prec, x);
    // If %g emitted a plain integer (no '.', exponent, or inf/nan letters), append ".0".
    if (!strpbrk(buf, ".eEnN")) {
        size_t n = strlen(buf);
        buf[n] = '.'; buf[n + 1] = '0'; buf[n + 2] = '\0';
    }
    printf("%s\n", buf);
}

// ===========================================================
//                         Strings
// ===========================================================
// Nothing here — the `String` type is off the C floor (task 121). The four `StringBase` ops are all
// codegen: `fromStaticUTF8` (string literals, `LLVMGen.lowerStringLit`), `allocHeap` (`__stringAllocHeap` in
// `SSAIRToLLVM`), `count` (`strLen`), and `bytePointer()` (`strPtr`). The surface — `eq`/`lt`/`byte(at:)`/
// `concat`/`count`/`isEmpty` — is Nomu over those (core.nomu). The only String construction still in C is the
// privileged `rt_read_line` (I/O), which builds its result with the `nomu_str_make` inline helper.

// Get monotonic time for benchmarking
int64_t __void_timemonotonic_int(void) {
    struct timespec ts;

    // Using CLOCK_MONOTONIC for stable duration benchmarking.
    // If you need real calendar time since 1970, swap with CLOCK_REALTIME.
    clock_gettime(CLOCK_MONOTONIC, &ts);

    // Cast variables to 64-bit first to avoid integer overflow
    // during the 1-billion multiplication step.
    return ((int64_t)ts.tv_sec * 1000000000LL) + (int64_t)ts.tv_nsec;
}

// ---- Asm-floor isolation self-test (task 128.2) ----
// Drives the arm64 context switch in isolation before any scheduler rides it (selfhosted-scheduler.md
// §6): seed a fiber, switch into it, the fiber records its argument and switches back. If the round-trip
// preserved everything, the recorded value is intact. Test scaffolding — the production completion path
// (fiber → scheduler) is wired by the scheduler rung; here the fiber switches back by hand. Returns 1 on
// success, 0 on failure. Reached from Nomu as the `__sysAsmSelfTest` intrinsic.
#if defined(__aarch64__)
extern void rtSwitch(void* from, void* to);
extern void rtFiberInit(void* ctx, void* stackTop, void* entry, void* arg);

static uint64_t rt_asm_ctx_main[21];
static uint64_t rt_asm_ctx_fiber[21];
static uint8_t  rt_asm_stack[65536] __attribute__((aligned(16)));
static volatile int64_t rt_asm_witness;

static void rt_asm_fiber_entry(void* arg) {
    rt_asm_witness = (int64_t)(intptr_t)arg;      // prove: running on the fiber, arg delivered
    rtSwitch(rt_asm_ctx_fiber, rt_asm_ctx_main);  // hand control back to the caller's context
    // unreached — the trampoline traps if control ever returns here
}

int64_t rt_asm_selftest(void) {
    rt_asm_witness = 0;
    rtFiberInit(rt_asm_ctx_fiber, rt_asm_stack + sizeof(rt_asm_stack),
                (void*)rt_asm_fiber_entry, (void*)(intptr_t)42);
    rtSwitch(rt_asm_ctx_main, rt_asm_ctx_fiber);  // into the fiber; it records 42 and switches back
    return rt_asm_witness == 42 ? 1 : 0;
}
#else
// No asm floor for this arch yet (x86-64 deferred). Report "not implemented".
int64_t rt_asm_selftest(void) { return 0; }
#endif

// ---- Carrier-local slot for the self-hosted scheduler (task 128.1.6) ----
// One thread-local word — the running fiber handle (`rt_current` for the Nomu scheduler), reached from
// Nomu as `RawPtr.tlsGet()` / `RawPtr.tlsSet(v)`. On macOS the stable TLS mechanism is the compiler's
// `_Thread_local` (dyld's thread-local variable support, a libSystem-tier facility), matching the
// platform decision that macOS binds the stable platform floor rather than a hand-rolled register read
// (selfhosted-scheduler.md §3.3). The one-instruction `rtTLSGet` over the arch thread-pointer register
// (arm64 TPIDRRO_EL0) is the Linux/optimization path, deferred with the Linux target. Distinct from the C
// scheduler's own `rt_current` in runtime.c — a program links one scheduler, never both.
static _Thread_local void* rt_self_current = NULL;
void* rt_tls_get(void)      { return rt_self_current; }
void  rt_tls_set(void* v)   { rt_self_current = v; }
