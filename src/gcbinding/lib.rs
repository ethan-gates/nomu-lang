//! M6 · 6.1.1 — the thin MMTk `VMBinding` for Nomu (NoGC to start; Q2, `m6-spec.md` §6.0.5).
//!
//! Adapted from mmtk-core's DummyVM reference binding (v0.32.0). The collection-side callbacks
//! (`Scanning`/`Collection`/`ReferenceGlue`, the copy paths of `ObjectModel`, most of `ActivePlan`)
//! are `unimplemented!()` — the NoGC plan never triggers them. 6.2–6.4 fill them in as collection,
//! precise roots, the write barrier, and actor teardown come online. The runtime stays C; this
//! crate is the only Rust (Q2), linked into every emitted program via the 6.1.0 section embed.

use core::ffi::c_void;
use std::sync::{Mutex, OnceLock};

use mmtk::util::copy::{CopySemantics, GCWorkerCopyContext};
use mmtk::util::opaque_pointer::*;
use mmtk::util::options::{GCTriggerSelector, PlanSelector};
use mmtk::util::{Address, ObjectReference};
use mmtk::vm::*;
use mmtk::{memory_manager, AllocationSemantics, MMTKBuilder, Mutator, MMTK};

// The runtime's pointer-map accessor (runtime.c, 6.1.3): managed-field byte offsets for a type-id.
unsafe extern "C" {
    fn nomu_gc_typemap(type_id: u64, out_count: *mut i32) -> *const i32;
    // 6.2.4 object sizing: the total byte size of every object of a type-id (header included), from
    // the codegen size table parallel to the pointer maps. `ObjectModel::get_current_size` reads it.
    fn nomu_gc_typesize(type_id: u64) -> u64;
    // Slice 4 (arrays): object kind (0 fixed / 1 variable-size array buffer) + array element stride.
    // A variable-size buffer is `{ header, cap, elems… }`: size/scan come from `cap` × stride, with
    // the per-element managed-pointer map read from `nomu_gc_typemap`.
    fn nomu_gc_typekind(type_id: u64) -> i32;
    fn nomu_gc_typestride(type_id: u64) -> u64;
    // 6.2.1 root scanning: walk a stopped carrier's stack (from its STW-saved context), invoking
    // `visit(slot, value, userdata)` per live GC root — `slot` is the stack address holding the
    // pointer. Reports nothing until the STW handshake saves carrier contexts (6.2.3).
    fn nomu_gc_walk_carrier(
        carrier_tls: *mut c_void,
        visit: extern "C" fn(*mut *mut c_void, *mut c_void, *mut c_void),
        userdata: *mut c_void,
    );
    // 6.2.2 VM-specific roots: walk every parked/runnable fiber's stack via the live-fiber registry
    // (on-CPU fibers are covered by their carrier's scan; done fibers hold no roots).
    fn nomu_gc_scan_parked_fibers(
        visit: extern "C" fn(*mut *mut c_void, *mut c_void, *mut c_void),
        userdata: *mut c_void,
    );
    // 6.2.3 STW handshake (built + validated in the C runtime). `Collection::stop_all_mutators`
    // wraps `stop` (quiesce every carrier at a safepoint), `resume_mutators` wraps `resume`.
    fn nomu_gc_stop_the_world();
    fn nomu_gc_resume_the_world();
    // 6.2.4: a carrier that triggers a collection inside `nomu_gc_alloc` (not at a Nomu poll) parks
    // here — it saves its context so its roots scan like any stopped carrier, marks itself stopped so
    // `stop_the_world` counts it as already parked, then blocks until `resume_the_world`.
    fn nomu_gc_block_for_gc();
}

// The live-mutator registry (one MMTk mutator per carrier, Q1). `ActivePlan::mutators` enumerates it
// so the collector can flush/scan every carrier; `Collection::stop_all_mutators` visits it after the
// STW quiesce. Stored as raw addresses (`*mut Mutator` isn't `Send`) and rematerialized as `&mut` on
// iteration — sound because MMTk only enumerates mutators at STW, when every carrier is stopped.
static MUTATORS: Mutex<Vec<usize>> = Mutex::new(Vec::new());

// The C root visitor (matches `nomu_root_visitor`): record each reported root **slot** — the stack
// location holding the pointer, not just the pointer — as an updatable `SimpleSlot`, so MMTk can
// rewrite it in place after evacuation moves the object (6.2.4). `userdata` is a `&mut Vec` of slots.
extern "C" fn nomu_collect_root_slot(
    slot: *mut *mut c_void,
    _value: *mut c_void,
    userdata: *mut c_void,
) {
    let slots = unsafe { &mut *(userdata as *mut Vec<NomuVMSlot>) };
    slots.push(NomuVMSlot::from_address(Address::from_mut_ptr(slot)));
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

    // 6.2.4: evacuate `from` to a fresh copy-space slot. Size/align come from the codegen tables
    // (fixed per type-id), so the copy is a flat byte move — the header (type-id) rides along and the
    // managed fields inside are re-traced/updated separately by `scan_object`. Used by Immix.
    fn copy(
        from: ObjectReference,
        semantics: CopySemantics,
        copy_context: &mut GCWorkerCopyContext<NomuVM>,
    ) -> ObjectReference {
        let bytes = Self::get_current_size(from);
        let dst = copy_context.alloc_copy(
            from,
            bytes,
            Self::get_align_when_copied(from),
            Self::get_align_offset_when_copied(from),
            semantics,
        );
        unsafe {
            std::ptr::copy_nonoverlapping::<u8>(from.to_raw_address().to_ptr(), dst.to_mut_ptr(), bytes);
        }
        let to_obj = Self::get_reference_when_copied_to(from, dst);
        copy_context.post_copy(to_obj, bytes, semantics);
        to_obj
    }
    // Delayed-copy path (compacting collectors slide objects, so the move may overlap — `copy`, not
    // `copy_nonoverlapping`). Not exercised by Immix, but correct if the plan ever compacts.
    fn copy_to(from: ObjectReference, to: ObjectReference, _region: Address) -> Address {
        let bytes = Self::get_current_size(from);
        let dst = Self::ref_to_object_start(to);
        unsafe {
            std::ptr::copy::<u8>(from.to_raw_address().to_ptr(), dst.to_mut_ptr(), bytes);
        }
        dst + bytes
    }
    // 6.2.4: object size comes from the codegen side table keyed by the header type-id (the low 32
    // bits of the header word at the object base, as `scan_object` reads it) — every object of a
    // type-id is fixed-size, so no object parsing. Fixed size means copied size equals current size.
    fn get_current_size(object: ObjectReference) -> usize {
        let base = object.to_raw_address();
        let type_id = unsafe { base.load::<u32>() } as u64;
        if unsafe { nomu_gc_typekind(type_id) } != 0 {
            // Variable-size array buffer `{ header, cap, elems… }`: size = header/cap prefix (16) +
            // cap × element stride. `cap` is the *allocated* extent, so this accounts the whole object.
            let cap = unsafe { (base + 8usize).load::<i64>() } as usize;
            let stride = unsafe { nomu_gc_typestride(type_id) } as usize;
            return 16 + cap * stride;
        }
        unsafe { nomu_gc_typesize(type_id) as usize }
    }
    fn get_size_when_copied(object: ObjectReference) -> usize {
        Self::get_current_size(object)
    }
    // Every Nomu heap object is a sequence of 8-byte slots (header + i64/pointer fields) allocated
    // 8-aligned by `rt_alloc`, so the copy alignment is a constant 8 with no offset.
    fn get_align_when_copied(_object: ObjectReference) -> usize {
        8
    }
    fn get_align_offset_when_copied(_object: ObjectReference) -> usize {
        0
    }
    // OBJECT_REF_OFFSET is 0 (the reference points at the object/header start), so the copied
    // reference is just the destination region start.
    fn get_reference_when_copied_to(_from: ObjectReference, to: Address) -> ObjectReference {
        ObjectReference::from_raw_address(to + OBJECT_REF_OFFSET).unwrap()
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
        MUTATORS.lock().unwrap().len()
    }
    // Every Nomu thread that allocates is a carrier (an MMTk mutator); GC worker threads never call in
    // here as mutators. A conservative `true` matches the NoGC stub and the single-role thread model.
    fn is_mutator(_tls: VMThread) -> bool {
        true
    }
    // Look up the mutator bound to a carrier by its tls token (the `pthread_self` passed at bind).
    fn mutator(tls: VMMutatorThread) -> &'static mut Mutator<NomuVM> {
        let want = tls.0 .0.to_address();
        for &m in MUTATORS.lock().unwrap().iter() {
            let mutator = unsafe { &mut *(m as *mut Mutator<NomuVM>) };
            if mutator.mutator_tls.0 .0.to_address() == want {
                return unsafe { &mut *(m as *mut Mutator<NomuVM>) };
            }
        }
        panic!("no mutator bound for tls {want}");
    }
    // Enumerate every registered mutator. Only called at STW (all carriers stopped), so handing out
    // `&mut` to each is sound — no carrier is concurrently touching its mutator.
    fn mutators<'a>() -> Box<dyn Iterator<Item = &'a mut Mutator<NomuVM>> + 'a> {
        let ptrs: Vec<usize> = MUTATORS.lock().unwrap().clone();
        Box::new(ptrs.into_iter().map(|m| unsafe { &mut *(m as *mut Mutator<NomuVM>) }))
    }
}

// The STW handshake itself is built and validated in the C runtime (6.2.3): `nomu_gc_stop_the_world`
// / `nomu_gc_resume_the_world` (the `__nomu_stop_world` poll flag + `__nomu_gc_poll_slow` quiesce),
// exercised end-to-end by `tools/gc-smoke-stw.sh`. These MMTk `Collection` wrappers — `stop_all_mutators`
// calls `nomu_gc_stop_the_world` then visits each mutator, `resume_mutators` calls the resume, etc. —
// stay `unimplemented!()` until the plan flip (NoGC→Immix): they need MMTk mutator enumeration
// (`ActivePlan::mutators`) and only fire once a collecting plan drives GC.
pub struct VMCollection;
impl Collection<NomuVM> for VMCollection {
    // Runs on a GC worker: quiesce every carrier at a safepoint (the 6.2.3 C handshake), then let MMTk
    // flush each stopped mutator's allocation buffers. After this returns, roots are scanned via
    // `scan_roots_in_mutator_thread` (carrier contexts) + `scan_vm_specific_roots` (parked fibers).
    fn stop_all_mutators<F>(_tls: VMWorkerThread, mut mutator_visitor: F)
    where
        F: FnMut(&'static mut Mutator<NomuVM>),
    {
        unsafe {
            nomu_gc_stop_the_world();
        }
        for mutator in VMActivePlan::mutators() {
            mutator_visitor(mutator);
        }
    }
    fn resume_mutators(_tls: VMWorkerThread) {
        unsafe {
            nomu_gc_resume_the_world();
        }
    }
    // The carrier that triggered this GC blocks in the C runtime until the collection resumes.
    fn block_for_gc(_tls: VMMutatorThread) {
        unsafe {
            nomu_gc_block_for_gc();
        }
    }
    // MMTk asks us to run a GC worker on its own OS thread. The tls token is the worker's own address
    // (a unique per-thread opaque pointer); `start_worker` drives the worker's collect loop.
    fn spawn_gc_thread(_tls: VMThread, ctx: GCThreadContext<NomuVM>) {
        match ctx {
            GCThreadContext::Worker(worker) => {
                std::thread::spawn(move || {
                    let ptr = worker.as_ref() as *const _ as *mut c_void;
                    let tls = VMWorkerThread(VMThread(OpaquePointer::from_address(
                        Address::from_mut_ptr(ptr),
                    )));
                    memory_manager::start_worker(mmtk(), tls, worker);
                });
            }
        }
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
    // 6.2.1: consume the LLVM stack maps for one carrier (an MMTk mutator, Q1) and report its live
    // roots as slots. The carrier is stopped at a safepoint (STW, 6.2.3); its saved context is keyed
    // by the tls token bound at `nomu_gc_bind_mutator` (its `pthread_self`). Precise, not
    // conservative (6.0.5): every reported slot comes from a statepoint stack map.
    fn scan_roots_in_mutator_thread(
        _tls: VMWorkerThread,
        mutator: &'static mut Mutator<NomuVM>,
        mut factory: impl RootsWorkFactory<NomuVMSlot>,
    ) {
        let carrier_tls = mutator.mutator_tls.0 .0.to_address().to_mut_ptr::<c_void>();
        let mut slots: Vec<NomuVMSlot> = Vec::new();
        unsafe {
            nomu_gc_walk_carrier(
                carrier_tls,
                nomu_collect_root_slot,
                &mut slots as *mut Vec<NomuVMSlot> as *mut c_void,
            );
        }
        if !slots.is_empty() {
            factory.create_process_roots_work(slots);
        }
    }
    // 6.2.2: VM-specific roots = every parked/runnable fiber's stack, via the global live-fiber
    // registry (a fiber currently on a carrier is covered by that carrier's scan above). Nomu has no
    // mutable global GC roots. Precise, slot-based, same as the carrier path.
    fn scan_vm_specific_roots(_tls: VMWorkerThread, mut factory: impl RootsWorkFactory<NomuVMSlot>) {
        let mut slots: Vec<NomuVMSlot> = Vec::new();
        unsafe {
            nomu_gc_scan_parked_fibers(
                nomu_collect_root_slot,
                &mut slots as *mut Vec<NomuVMSlot> as *mut c_void,
            );
        }
        if !slots.is_empty() {
            factory.create_process_roots_work(slots);
        }
    }
    // 6.1.3: dispatch through the codegen-emitted pointer map. Read the type-id from the object
    // header (slot 0), fetch its managed-field byte offsets, and report each as a slot. Inert under
    // NoGC (never called); exercised at 6.2 when tracing turns on.
    fn scan_object<SV: SlotVisitor<NomuVMSlot>>(
        _tls: VMWorkerThread,
        object: ObjectReference,
        slot_visitor: &mut SV,
    ) {
        let base = object.to_raw_address();
        // The type-id is the low 32 bits of the header word (`reserved` is the high half, 6.1.2).
        let type_id = unsafe { base.load::<u32>() } as u64;
        let mut count: i32 = 0;
        let offs = unsafe { nomu_gc_typemap(type_id, &mut count) };
        if unsafe { nomu_gc_typekind(type_id) } != 0 {
            // Array buffer: apply the per-element managed-pointer map at each of the `cap` element
            // slots. Slots beyond `len` are zero-initialized (rt_alloc zeroing + copy-only-live on
            // grow), so their managed offsets hold null and MMTk skips them — scanning `cap` is safe.
            let cap = unsafe { (base + 8usize).load::<i64>() } as isize;
            let stride = unsafe { nomu_gc_typestride(type_id) } as usize;
            for i in 0..cap {
                let elem_base = base + 16usize + (i as usize) * stride;
                for j in 0..count as isize {
                    let off = unsafe { *offs.offset(j) } as usize;
                    slot_visitor.visit_slot(mmtk::vm::slot::SimpleSlot::from_address(elem_base + off));
                }
            }
            return;
        }
        for i in 0..count as isize {
            let off = unsafe { *offs.offset(i) } as usize;
            slot_visitor.visit_slot(mmtk::vm::slot::SimpleSlot::from_address(base + off));
        }
    }
    // Post-root-scan notification (6.2.4). Nothing to flush on our side — roots are reported eagerly
    // from the stopped carriers' contexts, not incrementally.
    fn notify_initial_thread_scan_complete(_partial_scan: bool, _tls: VMWorkerThread) {}
    // No return barrier: carriers reach a safepoint cooperatively (the 6.2.3 poll), not via a stack
    // return barrier.
    fn supports_return_barrier() -> bool {
        false
    }
    // Only used by collectors that re-scan roots in a second STW (e.g. mark-compact). Immix's single
    // STW never calls this; leave it flagged so a plan that does reach it surfaces loudly.
    fn prepare_for_roots_re_scanning() {
        unimplemented!("root re-scanning is unused under Immix (6.2.4)")
    }
}

// ---- C-ABI entry points ----

/// Initialize MMTk with a fixed heap (idempotent). Plan is **GenImmix** (6.3): a generational
/// collector — a copying nursery over an Immix mature space — driven by the generational write
/// barrier (the `__nomu_write_barrier` seam, filled at 6.3.1). `NOMU_GC_PLAN` selects a plan for
/// differential debugging.
///
/// Env knobs for validation:
///   - `NOMU_GC_PLAN=nogc`         — pre-flip plan (no collection).
///   - `NOMU_GC_PLAN=immix`        — the 6.2 non-generational moving plan (barrier is a no-op).
///   - `NOMU_GC_PLAN=genimmix`     — default; generational (nursery + write barrier).
///   - `NOMU_GC_STRESS=<bytes>`    — precise collect every `<bytes>` allocated (collect-on-every-alloc
///                                   stress); also forces the mature Immix space to defrag every GC so
///                                   evacuation (the copy paths) actually runs, not just in-place marking.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_init(heap_bytes: usize) {
    if SINGLETON.get().is_some() {
        return;
    }
    // Default GenImmix (6.3): a generational plan whose mature space is Immix. `NOMU_GC_PLAN` picks
    // a plan for differential debugging: `nogc` (allocate-never-collect, pre-flip), `immix` (the 6.2
    // non-generational moving plan, no write barrier needed), or `genimmix` (default). NoGC skips
    // collection init below; the generational write barrier is inert under NoGC/Immix (their mutator
    // barrier is `NoBarrier`, so the post-barrier the codegen seam always calls is a no-op).
    let plan = match std::env::var("NOMU_GC_PLAN").as_deref() {
        Ok("nogc") => PlanSelector::NoGC,
        Ok("immix") => PlanSelector::Immix,
        _ => PlanSelector::GenImmix,
    };
    let nogc = matches!(plan, PlanSelector::NoGC);
    // `NOMU_GC_HEAP=<bytes>` shrinks the fixed heap to force frequent *real* (heap-pressure) GCs — the
    // generational-barrier validation path, distinct from `NOMU_GC_STRESS` (which drives GC off a byte
    // counter and, under GenImmix, can re-trip during the collector's own evacuation allocations).
    let heap_bytes = std::env::var("NOMU_GC_HEAP")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(heap_bytes);
    let mut builder = MMTKBuilder::new();
    let _ = builder.options.plan.set(plan);
    let _ = builder
        .options
        .gc_trigger
        .set(GCTriggerSelector::FixedHeapSize(heap_bytes));
    // One GC worker keeps collection deterministic while the flip stabilizes (perf-tune later).
    let _ = builder.options.threads.set(1);
    if let Some(bytes) = std::env::var("NOMU_GC_STRESS").ok().and_then(|s| s.parse::<usize>().ok()) {
        let _ = builder.options.stress_factor.set(bytes);
        let _ = builder.options.precise_stress.set(true);
        // Immix only moves objects when it defrags; force it so the stress mode exercises evacuation.
        let _ = builder.options.immix_always_defrag.set(true);
    }
    let instance = memory_manager::mmtk_init::<NomuVM>(&builder);
    let _ = SINGLETON.set(instance);
    // Enable collection: spawn GC workers (via `spawn_gc_thread`) and let the plan trigger GCs. Skip
    // under NoGC, which never collects. The tls is the initializing (main) thread's opaque token.
    if !nogc {
        let tls = VMThread(OpaquePointer::from_address(unsafe { Address::from_usize(1) }));
        memory_manager::initialize_collection(mmtk(), tls);
    }
}

/// Bind one MMTk mutator for a carrier thread (Q1: one `Mutator` per carrier). `tls` is an opaque
/// per-thread token (the runtime passes `pthread_self`); under NoGC its content is unused. Returns
/// the boxed mutator as an opaque handle the runtime stores thread-locally and passes to `nomu_gc_alloc`.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_bind_mutator(tls: *mut c_void) -> *mut Mutator<NomuVM> {
    let tls = VMMutatorThread(VMThread(OpaquePointer::from_address(Address::from_mut_ptr(tls))));
    let handle = Box::into_raw(memory_manager::bind_mutator(mmtk(), tls));
    // Register the carrier's mutator so the collector can enumerate it at STW (6.2.4).
    MUTATORS.lock().unwrap().push(handle as usize);
    handle
}

/// Allocate `size` bytes (aligned to `align`) through the given carrier's mutator — the runtime
/// allocation seam. Returns the object start (raw, uninitialized; the C runtime zeroes it). This is
/// the bump-pointer fast path that 8.4's `__nomu_gc_alloc` seam will eventually inline (§6.0.10);
/// for now the C `rt_alloc` calls it out-of-line.
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_alloc(mutator: *mut Mutator<NomuVM>, size: usize, align: usize) -> *mut c_void {
    alloc_semantic(mutator, size, align, AllocationSemantics::Default)
}

/// Generational write barrier post-hook (M6 · 6.3.1). Called by the runtime `rt_gc_write_barrier`
/// *after* the codegen `__nomu_write_barrier` seam stores `val` into `*slot` of the managed object
/// `src`. Under GenImmix the mutator's barrier is the object-remembering `ObjectBarrier`: this checks
/// `src`'s log bit and, on the first mature-object mutation, records `src` in the remembered set so a
/// nursery collection treats the freshly-written cross-generation pointer as a root. Under NoGC/Immix
/// the mutator barrier is `NoBarrier`, so this is a no-op — the seam calls it unconditionally and the
/// plan decides whether it does anything, keeping the barrier collector-agnostic (6.0.5; LXR refills
/// the same seam later). `target` is `None` when the stored value is null (no cross-gen pointer to
/// remember); `slot` is the field address (an updatable `SimpleSlot`).
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_write_barrier_post(
    mutator: *mut Mutator<NomuVM>,
    src: *mut c_void,
    slot: *mut c_void,
    target: *mut c_void,
) {
    let m = unsafe { &mut *mutator };
    let src = ObjectReference::from_raw_address(Address::from_mut_ptr(src))
        .expect("write barrier: null source object");
    let slot = NomuVMSlot::from_address(Address::from_mut_ptr(slot));
    let target = ObjectReference::from_raw_address(Address::from_mut_ptr(target));
    memory_manager::object_reference_write_post::<NomuVM>(m, src, slot, target);
}

/// Allocate `size` bytes in **immortal** space (M6 · 6.2.4): non-moving, never reclaimed. The String
/// interim routes its `rt_str_concat`/`rt_read_line` buffers here so their raw `addr0` `data` pointer
/// (`{ addr0, i64 }`, Q6) stays valid under a moving collector — the buffers leak until real heap-
/// boxing (the D6 spill seam + Q6) lands. `rt_str_lit` needs no allocation (it wraps static rodata).
#[unsafe(no_mangle)]
pub extern "C" fn nomu_gc_alloc_immortal(mutator: *mut Mutator<NomuVM>, size: usize, align: usize) -> *mut c_void {
    alloc_semantic(mutator, size, align, AllocationSemantics::Immortal)
}

// Shared alloc path: bump-allocate through the mutator, then run MMTk's post-alloc (initializes
// object metadata — VO/log/mark bits — that a collecting plan relies on; a no-op under NoGC). The
// C runtime zeroes the returned memory, so the header (type-id) is 0 until codegen stamps it.
fn alloc_semantic(
    mutator: *mut Mutator<NomuVM>,
    size: usize,
    align: usize,
    semantics: AllocationSemantics,
) -> *mut c_void {
    let m = unsafe { &mut *mutator };
    let addr = memory_manager::alloc::<NomuVM>(m, size, align, 0, semantics);
    if addr.is_zero() {
        return std::ptr::null_mut();
    }
    let obj = ObjectReference::from_raw_address(addr).unwrap();
    memory_manager::post_alloc::<NomuVM>(m, obj, size, semantics);
    addr.to_mut_ptr()
}
