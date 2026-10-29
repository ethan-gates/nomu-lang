# Linux support — the compiler and the binaries it builds on Linux

**Avenue:** Infra · **Type/Lifecycle:** `driver · runtime · needs-design` · **Size:** L · **Status:** needs-design ·
**Source:** [159](159-gc-observability.md) chose Darwin's fastest clock for the collector's recorder, since
everything so far targets darwin-arm64; this task collects what Linux needs as such choices are made.

## What

`nomu` runs on Linux and builds Linux binaries (arm64 first, then x86-64). Until then, each Darwin-only
choice is listed here with what replaces it.

## Known Darwin-only dependencies

- **Clock.** The collector's recorder reads `mach_absolute_time` (raw ticks, converted with
  `mach_timebase_info` when the report is written). Linux: `clock_gettime(CLOCK_MONOTONIC)` (vDSO).
  `RawPtr.monotonicNanos` calls `clock_gettime_nsec_np`, and the `time_monotonic` builtin calls
  `clock_gettime` through `core.c`.
- **The collector's report.** It reads the executable's path with `_NSGetExecutablePath`, the wall clock
  with `clock_gettime_nsec_np(CLOCK_REALTIME)`, and the tick rate with `mach_timebase_info`. Linux:
  `/proc/self/exe` (`readlink`), `clock_gettime(CLOCK_REALTIME)`, nanosecond ticks.
- **Futex.** The scheduler and the STW handshake wait and wake through `__ulock_wait` / `__ulock_wake`
  (`runtime.c`). Linux: `futex(2)`.
- **Object format.** The GC metadata sections (`__DATA,__nomu_descs`, `__nomu_ptrmaps`, `__llvm_stackmaps`)
  are Mach-O sections located through `getsectiondata` / `_mh_execute_header` (`runtime.c`) and ld64's
  `section$start$` symbols (`LLVMGenGCMaps.swift`). Linux: ELF sections with `__start_` / `__stop_` symbols.
- **The link-time GC frame index.** `FrameIndex.swift` parses Mach-O (including `LC_DYLD_CHAINED_FIXUPS`)
  and ld64's link map (`-map`). Linux: ELF and the linker's map format.
- **Toolchain.** `Toolchain.swift` finds tools through `xcrun` and the SDK; links sign with `codesign`
  (`CodeSignature.swift`). Linux: the system or embedded linker ([216](216-embedded-toolchain.md)); no signing.
- **Target.** The triple, CPU and features are `arm64-apple-macosx` / `apple-m1` / `+neon`.
- **Context switch.** `rtasm_arm64.s` is the arm64 fiber switch, using Darwin's symbol naming. Linux arm64:
  ELF naming; x86-64: a new switch.
- **Syscall floor.** [128](128-self-hosting-runtime.md) plans direct `svc` syscalls on Linux only (Darwin's raw
  syscall ABI is unstable).
- **Host code.** The compiler and tools import `Darwin` (`PerfReport.swift`, `ArtifactStore.swift`, the
  planner, `compiler-test`); Linux: `Glibc`.

## Refs

[216 embedded toolchain](216-embedded-toolchain.md), [128 self-hosting runtime](128-self-hosting-runtime.md),
[159 GC observability](159-gc-observability.md).
