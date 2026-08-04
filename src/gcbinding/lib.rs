//! M6 · 6.1.0 — toolchain bring-up probe.
//!
//! A throwaway C-ABI symbol whose only job is to prove the Rust crate builds under bazel
//! (`rules_rust`) and links two ways: into the `nomuc` compiler build, and into a
//! `nomuc`-emitted program (via the embedded prebuilt archive). No MMTk, no `VMBinding`
//! logic yet — that starts at 6.1.1. Delete this symbol once the real binding lands.

/// Fixed sentinel (`"NOMU_GC\0"` as big-endian bytes) so a caller can confirm the symbol
/// both linked and executed.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_probe() -> u64 {
    0x4E4F_4D55_5F47_4300
}

/// 6.1.1 bring-up: reference an MMTk type so the crate (and its transitive graph) is actually
/// compiled and linked before any `VMBinding` logic exists. Returns `size_of::<Address>()` (8).
/// Throwaway once the real binding lands.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_mmtk_probe() -> u64 {
    core::mem::size_of::<mmtk::util::Address>() as u64
}
