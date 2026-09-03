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
    ret

// The fresh-fiber trampoline: the first rtSwitch into a seeded fiber `ret`s here. Call entry(arg) with a
// terminated frame chain. If entry returns (the fiber ran to completion), fall into a trap — the
// completion path (switching back to the scheduler) is wired by the scheduler rung; a return here in the
// isolation test means the fiber failed to switch back, which is a bug worth catching loudly.
.p2align 2
_rtFiberTrampoline:
    mov x29, #0          // no parent frame
    mov x0, x20          // arg
    blr x19              // entry(arg)
    brk #0x1             // fiber returned unexpectedly — trap
