// Nomu's passes inside LLVM's code generator, registered from Swift through this C interface.
#ifndef NOMU_LLVM_PASSES_H
#define NOMU_LLVM_PASSES_H

#include "llvm-c/Error.h"
#include "llvm-c/TargetMachine.h"
#include "llvm-c/Types.h"

#ifdef __cplusplus
extern "C" {
#endif

// Adds the frame-address split (`FrameAddressSplit.cpp`) to every code-generation pipeline built after this
// call, in this process. Idempotent.
void nomuRegisterFrameAddressSplit(void);

// LLVMRunPasses, with Nomu's IR passes available by name in `pipeline`: `nomu-track-frame-addresses` turns
// the pointers marked with `nomu.frame.addr` into tracked values (`TrackFrameAddresses.cpp`; run it after
// optimization and before `rewrite-statepoints-for-gc`), `nomu-drop-frame-addresses` drops the markers
// instead (measurement only), and `nomu-expand-stack-checks` expands each function's stack-check placeholder
// and deletes the copies inlining made (`StackChecks.cpp`; after optimization, before the rewrite), and
// `nomu-indirect-large-values` passes values too large for registers through explicit
// pointers (`LargeValues.cpp`; after optimization, before those two), and `nomu-bundle-calls` gives every
// call that can stop an empty `deopt` bundle (`CallBundles.cpp`; before any inlining), and
// `nomu-split-reference-aggregates` keeps references in aggregates visible at stops (`ReferenceAggregates.cpp`;
// after the stack checks are expanded, before the rewrite). Returns null on success.
LLVMErrorRef nomuRunPasses(LLVMModuleRef module, const char *pipeline, LLVMTargetMachineRef machine);

// Marks the stack-check placeholder `nomu.stack.check` as touching only inaccessible memory, not throwing
// and always returning (`StackChecks.cpp`).
void nomuMarkStackCheckPlaceholder(LLVMValueRef function);
// Split `function`, whose frame is `need` bytes or less, into a wrapper (its name, checking for `need`
// bytes below its SP) and an unchecked body (`<name>.frame`). Returns the body.
LLVMValueRef nomuSplitLargeFrame(LLVMValueRef function, uint64_t need);

#ifdef __cplusplus
}
#endif

#endif
