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
// optimization and before `rewrite-statepoints-for-gc`), and `nomu-drop-frame-addresses` drops the markers
// instead (measurement only). Returns null on success.
LLVMErrorRef nomuRunPasses(LLVMModuleRef module, const char *pipeline, LLVMTargetMachineRef machine);

#ifdef __cplusplus
}
#endif

#endif
