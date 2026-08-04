//! M6 · 6.1.1 — the thin MMTk `VMBinding` for Nomu (NoGC to start; Q2, `m6-spec.md` §6.0.5).
//!
//! Adapted from mmtk-core's DummyVM reference binding (v0.32.0). The collection-side callbacks
//! (`Scanning`/`Collection`/`ReferenceGlue`, the copy paths of `ObjectModel`, most of `ActivePlan`)
//! are `unimplemented!()` — the NoGC plan never triggers them. 6.2–6.4 fill them in as collection,
//! precise roots, the write barrier, and actor teardown come online. The runtime stays C; this
//! crate is the only Rust (Q2), linked into every emitted program via the 6.1.0 section embed.

use core::ffi::c_void;
use std::sync::OnceLock;

use mmtk::util::copy::{CopySemantics, GCWorkerCopyContext};
use mmtk::util::opaque_pointer::*;
use mmtk::util::options::{GCTriggerSelector, PlanSelector};
use mmtk::util::{Address, ObjectReference};
use mmtk::vm::*;
use mmtk::{memory_manager, AllocationSemantics, MMTKBuilder, Mutator, MMTK};

// ---- 6.1.0 bring-up probe (throwaway; still force-resolved by the section-embed link) ----

/// Fixed sentinel (`"NOMU_GC\0"`) proving the archive linked + executes. Retired with the rest of
/// the 6.1.0 scaffolding once emitted programs call the real allocation seam.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_probe() -> u64 {
    0x4E4F_4D55_5F47_4300
}

// ---- VMBinding ----

pub type NomuVMSlot = mmtk::vm::slot::SimpleSlot;

#[derive(Default)]
pub struct NomuVM;

impl VMBinding for NomuVM {
    type VMObjectModel = VMObjectModel;
    type VMScanning = VMScanning;
    type VMCollection = VMCollection;
    type VMActivePlan = VMActivePlan;
    type VMReferenceGlue = VMReferenceGlue;
    type VMSlot = NomuVMSlot;
    type VMMemorySlice = mmtk::vm::slot::UnimplementedMemorySlice;

    const MAX_ALIGNMENT: usize = 1 << 6;
}

// The single MMTk instance. Populated by `nomu_gc_init`; 6.1.1's per-carrier mutators bind against
// it (Q1).
static SINGLETON: OnceLock<Box<MMTK<NomuVM>>> = OnceLock::new();

fn mmtk() -> &'static MMTK<NomuVM> {
    SINGLETON.get().expect("MMTk not initialized (nomu_gc_init)")
}

// ---- Object model (offset 0; copy paths unused under NoGC — real header/type-id is 6.1.2/6.1.3) ----

pub struct VMObjectModel;

const OBJECT_REF_OFFSET: usize = 0;
const OBJECT_HEADER_OFFSET: usize = 0;

impl ObjectModel<NomuVM> for VMObjectModel {
    const GLOBAL_LOG_BIT_SPEC: VMGlobalLogBitSpec = VMGlobalLogBitSpec::side_first();
    const LOCAL_FORWARDING_POINTER_SPEC: VMLocalForwardingPointerSpec =
        VMLocalForwardingPointerSpec::in_header(0);
    const LOCAL_FORWARDING_BITS_SPEC: VMLocalForwardingBitsSpec =
        VMLocalForwardingBitsSpec::side_first();
    const LOCAL_MARK_BIT_SPEC: VMLocalMarkBitSpec =
        VMLocalMarkBitSpec::side_after(Self::LOCAL_FORWARDING_BITS_SPEC.as_spec());
    const LOCAL_LOS_MARK_NURSERY_SPEC: VMLocalLOSMarkNurserySpec =
        VMLocalLOSMarkNurserySpec::side_after(Self::LOCAL_MARK_BIT_SPEC.as_spec());
    const OBJECT_REF_OFFSET_LOWER_BOUND: isize = OBJECT_REF_OFFSET as isize;

    fn copy(
        _from: ObjectReference,
        _semantics: CopySemantics,
        _copy_context: &mut GCWorkerCopyContext<NomuVM>,
    ) -> ObjectReference {
        unimplemented!()
    }
    fn copy_to(_from: ObjectReference, _to: ObjectReference, _region: Address) -> Address {
        unimplemented!()
    }
    fn get_current_size(_object: ObjectReference) -> usize {
        unimplemented!()
    }
    fn get_size_when_copied(object: ObjectReference) -> usize {
        Self::get_current_size(object)
    }
    fn get_align_when_copied(_object: ObjectReference) -> usize {
        unimplemented!()
    }
    fn get_align_offset_when_copied(_object: ObjectReference) -> usize {
        unimplemented!()
    }
    fn get_reference_when_copied_to(_from: ObjectReference, _to: Address) -> ObjectReference {
        unimplemented!()
    }
    fn get_type_descriptor(_reference: ObjectReference) -> &'static [i8] {
        unimplemented!()
    }
    fn ref_to_object_start(object: ObjectReference) -> Address {
        object.to_raw_address().sub(OBJECT_REF_OFFSET)
    }
    fn ref_to_header(object: ObjectReference) -> Address {
        object.to_raw_address().sub(OBJECT_HEADER_OFFSET)
    }
    fn dump_object(_object: ObjectReference) {
        unimplemented!()
    }
}

// ---- Collection-side stubs — unreachable under NoGC; filled at 6.2 (roots/STW) & 6.4 (teardown) ----

pub struct VMActivePlan;
impl ActivePlan<NomuVM> for VMActivePlan {
    fn number_of_mutators() -> usize {
        unimplemented!()
    }
    fn is_mutator(_tls: VMThread) -> bool {
        true
    }
    fn mutator(_tls: VMMutatorThread) -> &'static mut Mutator<NomuVM> {
        unimplemented!()
    }
    fn mutators<'a>() -> Box<dyn Iterator<Item = &'a mut Mutator<NomuVM>> + 'a> {
        unimplemented!()
    }
}

pub struct VMCollection;
impl Collection<NomuVM> for VMCollection {
    fn stop_all_mutators<F>(_tls: VMWorkerThread, _mutator_visitor: F)
    where
        F: FnMut(&'static mut Mutator<NomuVM>),
    {
        unimplemented!()
    }
    fn resume_mutators(_tls: VMWorkerThread) {
        unimplemented!()
    }
    fn block_for_gc(_tls: VMMutatorThread) {
        unimplemented!()
    }
    fn spawn_gc_thread(_tls: VMThread, _ctx: GCThreadContext<NomuVM>) {
        unimplemented!()
    }
}

pub struct VMReferenceGlue;
impl ReferenceGlue<NomuVM> for VMReferenceGlue {
    type FinalizableType = ObjectReference;
    fn set_referent(_reference: ObjectReference, _referent: ObjectReference) {
        unimplemented!()
    }
    fn get_referent(_object: ObjectReference) -> Option<ObjectReference> {
        unimplemented!()
    }
    fn clear_referent(_object: ObjectReference) {
        unimplemented!()
    }
    fn enqueue_references(_references: &[ObjectReference], _tls: VMWorkerThread) {
        unimplemented!()
    }
}

pub struct VMScanning;
impl Scanning<NomuVM> for VMScanning {
    fn scan_roots_in_mutator_thread(
        _tls: VMWorkerThread,
        _mutator: &'static mut Mutator<NomuVM>,
        _factory: impl RootsWorkFactory<NomuVMSlot>,
    ) {
        unimplemented!()
    }
    fn scan_vm_specific_roots(_tls: VMWorkerThread, _factory: impl RootsWorkFactory<NomuVMSlot>) {
        unimplemented!()
    }
    fn scan_object<SV: SlotVisitor<NomuVMSlot>>(
        _tls: VMWorkerThread,
        _object: ObjectReference,
        _slot_visitor: &mut SV,
    ) {
        unimplemented!()
    }
    fn notify_initial_thread_scan_complete(_partial_scan: bool, _tls: VMWorkerThread) {
        unimplemented!()
    }
    fn supports_return_barrier() -> bool {
        unimplemented!()
    }
    fn prepare_for_roots_re_scanning() {
        unimplemented!()
    }
}

// ---- C-ABI entry points ----

/// Initialize MMTk with a fixed heap (idempotent). Plan is **NoGC** (allocates, never collects) —
/// set explicitly, since MMTk 0.32's default plan is GenImmix. 6.2 switches the plan to Immix, then
/// 6.3 to GenImmix (§6.0.4).
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_init(heap_bytes: usize) {
    if SINGLETON.get().is_some() {
        return;
    }
    let mut builder = MMTKBuilder::new();
    let _ = builder.options.plan.set(PlanSelector::NoGC);
    let _ = builder
        .options
        .gc_trigger
        .set(GCTriggerSelector::FixedHeapSize(heap_bytes));
    let mmtk = memory_manager::mmtk_init::<NomuVM>(&builder);
    let _ = SINGLETON.set(mmtk);
}

// A placeholder mutator TLS for bring-up (single-thread probe). Real per-carrier `VMMutatorThread`
// wiring lands with the runtime side of 6.1.1 (Q1).
fn dummy_tls() -> VMMutatorThread {
    VMMutatorThread(VMThread(OpaquePointer::from_address(Address::ZERO)))
}

/// Bind one MMTk mutator for a carrier thread (Q1: one `Mutator` per carrier). `tls` is an opaque
/// per-thread token (the runtime passes `pthread_self`); under NoGC its content is unused. Returns
/// the boxed mutator as an opaque handle the runtime stores thread-locally and passes to `nomu_gc_alloc`.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_bind_mutator(tls: *mut c_void) -> *mut Mutator<NomuVM> {
    let tls = VMMutatorThread(VMThread(OpaquePointer::from_address(Address::from_mut_ptr(tls))));
    Box::into_raw(memory_manager::bind_mutator(mmtk(), tls))
}

/// Allocate `size` bytes (aligned to `align`) through the given carrier's mutator — the runtime
/// allocation seam. Returns the object start (raw, uninitialized; the C runtime zeroes it). This is
/// the bump-pointer fast path that 8.4's `__nomu_gc_alloc` seam will eventually inline (§6.0.10);
/// for now the C `rt_alloc` calls it out-of-line.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_alloc(mutator: *mut Mutator<NomuVM>, size: usize, align: usize) -> *mut c_void {
    let addr =
        memory_manager::alloc::<NomuVM>(unsafe { &mut *mutator }, size, align, 0, AllocationSemantics::Default);
    addr.to_mut_ptr()
}

/// 6.1.1 bring-up probe: init NoGC, bind a mutator, allocate `size` bytes through MMTk, and return
/// the allocation address (0 on failure). Proves MMTk initializes and allocates under `NomuVM`
/// before the runtime is wired to per-carrier mutators. Throwaway.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_alloc_probe(size: usize) -> u64 {
    nomu_gc_init(1 << 24); // 16 MiB fixed heap
    let mutator = Box::leak(memory_manager::bind_mutator(mmtk(), dummy_tls()));
    let addr = memory_manager::alloc::<NomuVM>(mutator, size, 8, 0, AllocationSemantics::Default);
    addr.as_usize() as u64
}
