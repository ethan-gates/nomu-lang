# Raw pointers made by offsetting null

**Avenue:** Risk (correctness) · **Type/Lifecycle:** `runtime · llvmgen · bug` · **Size:** S · **Status:**
done ·
**Source:** [261](261-actor-follow-ups.md).4, where LLVM compiled the message pool's `rtMsgFree` to a single
`brk`.

## What

`RawPtr.null.advanced(by: a)` is how the runtime turns an integer address back into a pointer. It lowers to
a `getelementptr` from null (`gepByte`), and a pointer so made keeps null's provenance: LLVM may treat any load
or store through it as undefined behavior. In `rtMsgFree` (`slab = RawPtr.null.advanced(by: a - (a & mask))`,
then a load from `slab`) it did, and replaced the whole function with a trap. The runtime has 19 more such
sites (`scheduler.nomu` 10, among them the mailbox queue's `rtMailboxTake`; `stackwalk.nomu` 3; `channel.nomu`,
`io.nomu`, `stackmove.nomu` 2 each). They work today only because the optimizer has not yet seen enough to
prove the same.

## Decision

The idiom stood in for an integer-to-pointer conversion the API lacks, and the integers existed only because
atomics were `Int`-typed or a slot was typed `Int` where it held a pointer. Options weighed: lower a null-based
`advanced` as `inttoptr` (keeps the idiom and fixes it by pattern); add `RawPtr.fromInt` (an honest conversion,
but keeps the round trip, and `inttoptr` tells LLVM nothing of where a pointer points); atomics on `RawPtr`
words (no round trip at all). Decided: atomics on `RawPtr` words, and every slot holding a number typed `Int`,
so the runtime turns no integer back into an address. `fromInt` waits for a caller that has only an integer
(an address the OS hands over).

## Work

- **263.1** Done. `atomicLoad` (typed from context), `atomicStore`, `atomicExchange` and `atomicCas` take an
  `Int` or a `RawPtr` word (`PointerIntrinsics.atomicWordArg`; the lowering takes the operands' type). The
  runtime's 19 sites:
  - pointers kept atomically, now `RawPtr` words: the run queue's ring and entries, the carrier's slot, the
    global queue heads, the mailbox's head, tail and links (`rtMailboxTake`, `rtMailboxPush`);
  - tagged pointers, read as `RawPtr` and untagged with `advanced(by: -1)`: a run-queue mailbox entry, a
    `select` waiter's tag, the timer's tagged waiter;
  - numbers that were carried as pointers, now `Int`: the derived-pointer list's offsets (`rtQueuePushInt`),
    the shadow-top save (`rtShadowSave`/`rtShadowPopTo` and codegen's save slots), the stack check's room
    (`Runtime.ctxSwitch` takes an `Int` message, given a pointer's type only at the asm call);
  - the stack anchor: `rtAnchorAt` off a fiber turned its integer back into an address; every caller is a
    fiber parking or resumed, so that branch is now a fatal error.

  No GEP from null is left in the runtime or the generated IR; no function of a built program begins with a
  trap. Sema tests: `testAtomicsOnRawPtrWords`, `testAtomicCasRejectsMixedWords`,
  `testAtomicWordRejectsOtherTypes`, `testCtxSwitchMessageMayBeAnInt`. Full tier passes.

## Refs

`llvmgen/LLVMGenRuntime.swift` (`gepByte`), `llvmgen/SSAIRToLLVM.swift` (`__rawAdvanced`),
`runtime/msgpool.nomu` (`rtMsgSlabOf`, which offsets the message pointer itself).
