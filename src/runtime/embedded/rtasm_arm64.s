// Task 128.2 · asm floor (arm64 / AArch64, Mach-O). The irreducible per-arch assembly for the
// self-hosted scheduler: a context switch and a fresh-fiber trampoline. No libSystem call swaps one
// fiber's registers and stack for another's, so this is genuinely hand-written (selfhosted-scheduler.md
// §2.1). The x86-64 counterpart is a separate file, deferred until an x86 build target exists.
//
// Context buffer layout — 21 × 8-byte slots (168 bytes), the callee-saved set the AArch64 PCS requires a
// function to preserve (so a switch that saves exactly these is a valid "return" into the other context):
//   [0..72]   x19–x28   (10 general callee-saved)
//   [80]      x29 (fp)
//   [88]      x30 (lr)  — the address execution resumes at when this context is restored
//   [96]      sp
//   [104..160] d8–d15   (8 SIMD/FP callee-saved, low 64 bits)
// This saved set is the contract the GC's parked-fiber walk reads (runtime.md §6), so it is spelled out
// here rather than left to the assembler.

.section __TEXT,__text,regular,pure_instructions
.p2align 2

// void rtSwitch(void* from, void* to)
//   x0 = from context buffer (save current registers into it)
//   x1 = to   context buffer (restore from it, then return into its saved lr)
.global _rtSwitch
_rtSwitch:
    // Save the current callee-saved set into *from.
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
    mov x9, sp
    str x9, [x0, #96]
    stp d8,  d9,  [x0, #104]
    stp d10, d11, [x0, #120]
    stp d12, d13, [x0, #136]
    stp d14, d15, [x0, #152]

    // Restore the saved set from *to.
    ldp x19, x20, [x1, #0]
    ldp x21, x22, [x1, #16]
    ldp x23, x24, [x1, #32]
    ldp x25, x26, [x1, #48]
    ldp x27, x28, [x1, #64]
    ldp x29, x30, [x1, #80]
    ldr x9, [x1, #96]
    mov sp, x9
    ldp d8,  d9,  [x1, #104]
    ldp d10, d11, [x1, #120]
    ldp d12, d13, [x1, #136]
    ldp d14, d15, [x1, #152]
    // `ret` jumps to x30, which is now *to*'s saved return address — resuming that context.
    ret

// void rtFiberInit(void* ctx, void* stackTop, void* entry, void* arg)
//   Seed a fresh fiber's context buffer so the first rtSwitch into it lands in the trampoline below with
//   the entry function in x19 and its argument in x20. `stackTop` is the high end of the fiber stack
//   (the stack grows down); it is aligned down to 16 for the AArch64 ABI.
//   x0 = ctx, x1 = stackTop, x2 = entry, x3 = arg
.global _rtFiberInit
_rtFiberInit:
    and  x9, x1, #0xfffffffffffffff0     // align stackTop down to 16
    str  x9, [x0, #96]                   // sp
    adrp x10, _rtFiberTrampoline@PAGE
    add  x10, x10, _rtFiberTrampoline@PAGEOFF
    str  x10, [x0, #88]                  // lr = trampoline (first rtSwitch `ret`s here)
    str  x2, [x0, #0]                    // x19 = entry
    str  x3, [x0, #8]                    // x20 = arg
    str  xzr, [x0, #80]                  // fp = 0, terminating the frame-pointer chain
    str  x28, [x0, #72]                  // x28 = the creator's (the scheduler then sets its own fibers')
    ret

// The fresh-fiber trampoline: the first rtSwitch into a seeded fiber `ret`s here. Call entry(arg) with a
// terminated frame chain. If entry returns (the fiber ran to completion), fall into a trap — the
// completion path (switching back to the scheduler) is wired by the scheduler rung; a return here in the
// isolation test means the fiber failed to switch back, which is a bug worth catching loudly. Global, so a
// backtrace names it: it is every fiber's bottom frame, and the link strips local symbols.
.global _rtFiberTrampoline
.p2align 2
_rtFiberTrampoline:
    mov x29, #0          // no parent frame
    mov x0, x20          // arg
    blr x19              // entry(arg)
    brk #0x1             // fiber returned unexpectedly — trap

// The platform layer's stack switch: every libc call from generated code and the runtime goes through a
// stub here, `_nomu_libc_<name>` for libc's `<name>` (`design/plans/tasks/104-fiber-stack-strategy.md`,
// "Calls into libc"; codegen's list is `LLVMGen.libcViaCarrier`, which must match the stubs below). No
// stack bound is assumed for code Nomu does not own, so on a fiber's stack the call runs on its carrier's
// stack instead: just below the SP the carrier saved when it switched into the fiber (the carrier is
// suspended in rtSwitch, so everything below that SP is free), past a 256-byte margin. Off a fiber's stack
// (a carrier's own loop, a signal handler on its alternate stack, startup code, a test's own fibers) the
// stub branches straight to the function. Arguments and results pass through untouched. A variadic
// function's stub also copies the caller's outgoing argument area, where Darwin passes variadic arguments
// (64 bytes: eight of them), to the new stack.
//   x28 = the running fiber (0 off any fiber): its stack base at +208, size at +312, and its carrier's
//   context buffer at +232, whose saved SP is at +96 (`runtime/scheduler.nomu`).
// The switch itself, branching to `target`; `varargs` 1 also copies the outgoing argument area.
.macro NOMU_SWITCH target, varargs
    cbz  x28, 1f
    ldr  x9, [x28, #208]                 // the fiber's stack base
    ldr  x10, [x28, #312]                // its size
    mov  x11, sp
    sub  x12, x11, x9
    cmp  x12, x10
    b.hs 1f                              // SP outside the fiber's stack
    ldr  x12, [x28, #232]                // the carrier's context
    cbz  x12, 1f
    ldr  x12, [x12, #96]                 // the carrier's saved SP
    sub  x12, x12, #256
    stp  x29, x30, [x12, #-32]!          // a frame record on the carrier's stack, chained to the fiber's
    str  x11, [x12, #16]                 // the fiber's SP
    mov  x29, x12
.if \varargs
    sub  x12, x12, #64
    ldp  x9, x10, [x11, #0]
    stp  x9, x10, [x12, #0]
    ldp  x9, x10, [x11, #16]
    stp  x9, x10, [x12, #16]
    ldp  x9, x10, [x11, #32]
    stp  x9, x10, [x12, #32]
    ldp  x9, x10, [x11, #48]
    stp  x9, x10, [x12, #48]
.endif
    mov  sp, x12
    bl   \target
    ldr  x11, [x29, #16]
    ldp  x29, x30, [x29]
    mov  sp, x11
    ret
1:  b    \target
.endm

.macro NOMU_LIBC name, varargs
.global _nomu_libc_\name
.p2align 2
_nomu_libc_\name:
    NOMU_SWITCH _\name, \varargs
.endm

NOMU_LIBC abort, 0
NOMU_LIBC clock_gettime_nsec_np, 0
NOMU_LIBC close, 0
NOMU_LIBC creat, 0
NOMU_LIBC dprintf, 1
NOMU_LIBC exit, 0
NOMU_LIBC free, 0
NOMU_LIBC getenv, 0
NOMU_LIBC getpagesize, 0
NOMU_LIBC kevent, 0
NOMU_LIBC kqueue, 0
NOMU_LIBC mach_absolute_time, 0
NOMU_LIBC mach_timebase_info, 0
NOMU_LIBC malloc, 0
NOMU_LIBC mmap, 0
NOMU_LIBC mprotect, 0
NOMU_LIBC munmap, 0
NOMU_LIBC pipe, 0
NOMU_LIBC poll, 0
NOMU_LIBC posix_memalign, 0
NOMU_LIBC printf, 1
NOMU_LIBC pthread_create, 0
NOMU_LIBC pthread_getspecific, 0
NOMU_LIBC pthread_join, 0
NOMU_LIBC pthread_key_create, 0
NOMU_LIBC pthread_setspecific, 0
NOMU_LIBC putchar, 0
NOMU_LIBC raise, 0
NOMU_LIBC read, 0
NOMU_LIBC sigaction, 0
NOMU_LIBC sigaltstack, 0
NOMU_LIBC snprintf, 1
NOMU_LIBC strlen, 0
NOMU_LIBC strpbrk, 0
NOMU_LIBC strtod, 0
NOMU_LIBC write, 0
NOMU_LIBC __ulock_wait, 0
NOMU_LIBC __ulock_wake, 0
NOMU_LIBC _NSGetExecutablePath, 0

// The memory routines: `memcpy`, `memmove`, `memset`, `bzero` and `memcmp`, defined here so that every
// call in a Nomu binary binds to them, the ones LLVM emits on its own included (a local definition wins
// over libSystem's; libSystem's own calls keep its). Small sizes are done here in straight-line code with
// overlapping loads and stores, using no stack; larger ones go to libSystem's tuned routines
// (`_platform_memmove`, `_platform_memset`, `_platform_memcmp`) through the stack switch above
// (`design/plans/tasks/104-fiber-stack-strategy.md`, 104.3.4). The copy loads everything before it stores,
// so `memcpy` is also a correct `memmove`.

// void* memmove(void* dst, const void* src, size_t n); memcpy is the same routine.
.global _memcpy
.global _memmove
.p2align 4
_memcpy:
_memmove:
    add  x4, x1, x2                      // source end
    add  x5, x0, x2                      // destination end
    cmp  x2, #16
    b.hi Lmove_17
    cmp  x2, #8
    b.lo Lmove_0_7
    ldr  x6, [x1]
    ldur x7, [x4, #-8]
    str  x6, [x0]
    stur x7, [x5, #-8]
    ret
Lmove_0_7:
    tbz  x2, #2, Lmove_0_3
    ldr  w6, [x1]
    ldur w7, [x4, #-4]
    str  w6, [x0]
    stur w7, [x5, #-4]
    ret
Lmove_0_3:
    cbz  x2, Lmove_done
    lsr  x9, x2, #1
    ldrb w6, [x1]
    ldurb w7, [x4, #-1]
    ldrb w8, [x1, x9]
    strb w6, [x0]
    strb w8, [x0, x9]
    sturb w7, [x5, #-1]
Lmove_done:
    ret
Lmove_17:
    cmp  x2, #32
    b.hi Lmove_33
    ldr  q0, [x1]
    ldur q1, [x4, #-16]
    str  q0, [x0]
    stur q1, [x5, #-16]
    ret
Lmove_33:
    cmp  x2, #64
    b.hi Lmove_65
    ldp  q0, q1, [x1]
    ldp  q2, q3, [x4, #-32]
    stp  q0, q1, [x0]
    stp  q2, q3, [x5, #-32]
    ret
Lmove_65:
    cmp  x2, #128
    b.hi Lmove_large
    ldp  q0, q1, [x1]
    ldp  q2, q3, [x1, #32]
    ldp  q4, q5, [x4, #-64]
    ldp  q6, q7, [x4, #-32]
    stp  q0, q1, [x0]
    stp  q2, q3, [x0, #32]
    stp  q4, q5, [x5, #-64]
    stp  q6, q7, [x5, #-32]
    ret
Lmove_large:
    NOMU_SWITCH __platform_memmove, 0

// void bzero(void* dst, size_t n): memset to 0.
.global _bzero
.p2align 2
_bzero:
    mov  x2, x1
    mov  w1, #0
    b    _memset

// void* memset(void* dst, int c, size_t n)
.global _memset
.p2align 4
_memset:
    dup  v0.16b, w1
    add  x5, x0, x2                      // destination end
    cmp  x2, #16
    b.hi Lset_17
    fmov x6, d0
    cmp  x2, #8
    b.lo Lset_0_7
    str  x6, [x0]
    stur x6, [x5, #-8]
    ret
Lset_0_7:
    tbz  x2, #2, Lset_0_3
    str  w6, [x0]
    stur w6, [x5, #-4]
    ret
Lset_0_3:
    cbz  x2, Lset_done
    strb w6, [x0]
    cmp  x2, #2
    b.lo Lset_done
    sturh w6, [x5, #-2]
Lset_done:
    ret
Lset_17:
    cmp  x2, #32
    b.hi Lset_33
    str  q0, [x0]
    stur q0, [x5, #-16]
    ret
Lset_33:
    cmp  x2, #64
    b.hi Lset_65
    stp  q0, q0, [x0]
    stp  q0, q0, [x5, #-32]
    ret
Lset_65:
    cmp  x2, #128
    b.hi Lset_large
    stp  q0, q0, [x0]
    stp  q0, q0, [x0, #32]
    stp  q0, q0, [x5, #-64]
    stp  q0, q0, [x5, #-32]
    ret
Lset_large:
    NOMU_SWITCH __platform_memset, 0

// int memcmp(const void* a, const void* b, size_t n): the sign of the first differing byte's difference
// (as unsigned bytes), 0 when none differs. Words are compared big-endian (`rev`), so the first difference
// decides.
.global _memcmp
.p2align 4
_memcmp:
    add  x4, x0, x2
    add  x5, x1, x2
    cmp  x2, #8
    b.hi Lcmp_9
    cmp  x2, #4
    b.lo Lcmp_0_3
    ldr  w6, [x0]                        // 4..8: the first and last 4 bytes, as one big-endian word
    ldr  w7, [x1]
    ldur w8, [x4, #-4]
    ldur w9, [x5, #-4]
    rev  w6, w6
    rev  w7, w7
    rev  w8, w8
    rev  w9, w9
    orr  x6, x8, x6, lsl #32
    orr  x7, x9, x7, lsl #32
    cmp  x6, x7
    b.ne Lcmp_order
    mov  w0, #0
    ret
Lcmp_0_3:
    cbz  x2, Lcmp_equal
    ldrb w6, [x0], #1
    ldrb w7, [x1], #1
    subs w6, w6, w7
    b.ne Lcmp_byte
    sub  x2, x2, #1
    b    Lcmp_0_3
Lcmp_byte:
    mov  w0, w6
    ret
Lcmp_equal:
    mov  w0, #0
    ret
Lcmp_9:
    cmp  x2, #16
    b.hi Lcmp_large
    ldr  x6, [x0]
    ldr  x7, [x1]
    cmp  x6, x7
    b.ne Lcmp_word
    ldur x6, [x4, #-8]
    ldur x7, [x5, #-8]
    cmp  x6, x7
    b.ne Lcmp_word
    mov  w0, #0
    ret
Lcmp_word:
    rev  x6, x6
    rev  x7, x7
    cmp  x6, x7
Lcmp_order:
    cset w0, hi
    csinv w0, w0, wzr, hs                // 1 when a's byte is greater, -1 when smaller
    ret
Lcmp_large:
    NOMU_SWITCH __platform_memcmp, 0

// void* rtThreadStart(void* rec): every thread Nomu creates starts here (`Runtime.threadCreate`). `rec` is
// a malloc'd { entry, arg }: x28 is set to 0 (no fiber runs yet on this thread, which the libc-call switch
// above reads), the record freed, then entry(arg) called and its result returned. x28 is callee-saved, so
// the caller's is restored.
.global _rtThreadStart
.p2align 2
_rtThreadStart:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    str  x28, [sp, #32]
    mov  x28, #0
    ldp  x9, x10, [x0]
    stp  x9, x10, [sp, #16]
    bl   _free
    ldp  x9, x0, [sp, #16]
    blr  x9
    ldr  x28, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
