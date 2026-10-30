# Retire the C floor — the runtime in Nomu all the way down

**Avenue:** Risk · **Type/Lifecycle:** `runtime · language · refactor` · **Size:** L · **Status:** in
progress; 223.1–223.6 built, short of the coordinator threads (with 158) and blocker 6 (192) ·
**Source:** [128](128-self-hosting-runtime.md), whose goal "remove Rust and C" this finishes; split out
when 128's other parts were built.

## What

After 197, `runtime.c` (965 lines) and `core.c` (95) remain under the Nomu scheduler and collector. By area, approximately: the GC type-descriptor accessors (290),
the GC coordinator and smoke threads (170), line input with its kqueue poller (140), carrier state (115:
the TLAB and mod-buffer slots and registries, the space-creation lock, the write-barrier slow path), the
forwarders into Nomu (50: `fiber_spawn`, `spawn_join`, `rt_sleep_ms`, `__nomu_gc_poll_slow`, the mailbox
calls), process globals (40), `main` (35), and the rest (60: the frame-index check, raw memory, the bounds
trap, `rt_print_double`, the current-fiber TLS slot). The asm floor ([128](128-self-hosting-runtime.md).2)
is separate and stays.
Ordered before [127 LXR](127-lxr-collector.md), within the Order rule in `horizon.md` (one change at a
time): this is a location change on GenImmix, and LXR is then built and compared on a runtime with no C
under it.

**Rule: from the floor up.** Moving a piece of C into Nomu while what it stands on stays in C adds edges
between the two: Nomu calling back into C for memory, a thread-local, or a lock. So each stage below
moves code only once everything it needs is expressible in Nomu, and the C it replaces is deleted in the
same stage. Until a stage lands, its C stays where it is and new runtime work does not add C beside it.

## Blockers

What Nomu cannot express today, each a blocker:
1. **Calls into the C library:** `pthread_create`, `pthread_mutex_*`, `__ulock_wait`/`__ulock_wake`,
   `kqueue`/`kevent`, `poll`, `read`, `nanosleep`, `posix_memalign`/`free`, `fprintf`/`abort`/`exit`,
   `getsectiondata`, some over C struct layouts (`struct kevent`, `pthread_mutex_t`). One-off codegen
   intrinsics can cover them one at a time; the general answer is [130 FFI](130-ffi-c-abi.md). Several
   already lower straight to libSystem (`getenv`, `kqueue`/`kevent`, the futex calls, thread create and
   join, the clocks); `RawPtr.alloc` still goes through C (`rt_raw_alloc`).
2. **Entry points called by foreign threads:** `pthread_create` runs a C function pointer on a new OS
   thread, and dyld calls `main`. Nomu functions use the GC calling convention and expect a carrier (the
   current fiber in TLS, a TLAB). `main` alone codegen can emit; thread entries need a C-ABI function safe
   to run with no fiber.
3. **Code that never reaches a safepoint:** the GC coordinator threads drive the stop-the-world, and a
   back-edge poll in their loops could park a coordinator on its own collection. The anchor shims
   (`spawn_join`, `rt_sleep_ms`, `__nomu_gc_poll_slow`) must be a separate frame directly below user code
   and read the return and frame addresses. Needs a no-polls, no-statepoints, never-inlined function
   property, and return-address and frame-address intrinsics. The runtime subset (149) rules out
   allocation, not polls or frame shape.
4. **Process-wide globals and thread-locals:** the stop-the-world flag, the scheduler handle, the
   write-barrier globals that inlined code reads, the Immix space pointer, the GC tuning globals and the
   run settings (198), the registries, and the TLS slots. Nomu has no global variables; C defines the
   storage and codegen loads it.
5. **Link-level control (minor):** the weak fallback `nomu_actor_drain`, and section lookup through
   `_mh_execute_header`, which `section$start$…` symbols can replace (the stack-map lookup already uses
   them).
6. **The asm floor into the runtime's object** (for [192](192-bazel-friendliness.md)): retiring the C files
   leaves `rtasm_arm64.s` (the context switch, fiber setup) assembled into the runtime archive. For the
   archive to go, so that every runtime byte comes from `nomu compile`, the asm moves into the runtime
   module's object, for example as module-level inline asm through LLVM (the backend already emits the
   stackmap keep directive that way). Needed only by 192, which waits for it.

Items 2–4 likely need runtime-tier language surface (a function property, globals, FFI declarations),
which needs agreement before it is added. Items 5 and 6, and item 1 done call by call as intrinsics, are
compiler-only.

## Work

Stages, each deleting the C it replaces:
- **223.1 The floor.** Blockers 1 and 4: the `Runtime` namespace, globals in Nomu, the carrier-local
  slot, and raw memory lowered straight to libSystem. Blocker 3 (the no-polls, frame-shaped function property) waits for
  223.3, where the forwarders show what it needs. Deletes the C globals and `rt_raw_alloc`.

  **Globals** are task [224](224-globals.md): a module-private top-level `let`, a constant folded at compile
  time or computed once at startup, under one rule for user code and the runtime.

  The runtime follows the same rule ([224](224-globals.md)). The stop-the-world flag, the write barrier's
  values, the carrier-local slot's key and the space pointer live in `Runtime.staticStorage` blocks: the
  global holding a block is a folded constant (a fixed address), the values inside are written once at
  boot through `RawPtr`, and each read is one load, as with the C globals today; codegen's inline poll and
  barrier reference the blocks by symbol. Cold values (the scheduler handle, the run settings) may be
  startup globals. State that changes after startup (the
  stop-the-world flag, the registries, stdin's buffer) is `RawPtr` memory written through `RawPtr`'s
  loads, stores and atomics. The runtime's privileges are the `Runtime` namespace and `RawPtr` constants.
  **Escape hatch:** the first time a measurement shows the rule costs the runtime performance, the
  runtime gets the exemption it needs.

  The runtime module initializes first (everything depends on it), on the main thread before the
  scheduler boots, under the runtime subset. Creating the space at startup instead of on the first
  allocation makes the space pointer and barrier globals constants, which 223.2's fast path relies on.
  Until 223.5 makes `main` Nomu, C's `main` calls the generated initializer first. User-module
  initializers may allocate, so they run on the main fiber before `main`'s body.

  **Runtime intrinsics live on `Runtime`.** Privileged operations are spelled on `Runtime`, a type with
  no values that only the runtime tier may name, so every privileged call is visibly one and sema rejects
  it elsewhere (`../../internals/runtime-subset.md` §5). `RawPtr` and `Ptr<T>` keep only the unsafe
  raw-memory surface of [125](125-unsafe-raw-memory.md) (`alloc`, `free`, `load`, `store`, `advanced`,
  `zeroBytes`, `copyBytes`, the atomics, identity and conversions); whether user code may use it is a
  separate question.

  Work:
  - **223.1.1** `Runtime`. **Built.** `RuntimeIntrinsics.swift` (sema) checks the 54 runtime intrinsics
    as `Runtime.<name>(…)`: the 47 that were `RawPtr` statics keep their names, and the seven that were
    pointer methods take the pointer as an argument (`Runtime.ctxSwitch(from:to:)`,
    `fiberInit(context:stackTop:entry:arg:)`, `threadCreate(handle:entry:arg:)`, `threadJoin(handle:)`,
    `callEntry(_:arg:)`, `futexWait(at:expected:timeoutMicros:)`, `futexWake(at:all:)`). They lower to the
    same intrinsic ids as before, so `llvmgen` is unchanged. `RawPtr` keeps the 125 surface. Sema's
    `runtimeTier` admits `Runtime` in the `runtime` package and in suite fixtures built with
    `test.runtime_prelude` or the new `test.runtime_tier` (`runtime_tier` in `cfg.yaml` and the suite,
    set on the twelve scheduler-substrate fixtures from 128.1). Elsewhere `Runtime` does not exist: naming
    it is the ordinary `undefined name 'Runtime'` error. A type declared or imported as `Runtime` stays an
    ordinary type. 301 call sites in `runtime.nomu` and
    about 160 in 24 fixtures were rewritten. Tests: four sema unit tests (rejected outside the tier,
    accepted inside, a user type named `Runtime`, the intrinsics gone from `RawPtr`) and the
    `runtime-intrinsic-rejected` suite case.
  - **223.1.2** Globals: [224](224-globals.md).1–224.3 (the runtime's globals hold only numbers and
    `RawPtr`, so 224.4 is not needed here). **Built.**
  - **223.1.3** Static storage: `Runtime.staticStorage(bytes:align:)`, legal only as a runtime global's
    initializer with literal arguments; reserves zeroed bytes in the data section and folds to their
    address. The stop-the-world flag's home; the inline poll reads it by symbol. **Built.** Sema admits the
    call only as a global's whole initializer (the call's span is recorded while the initializer is
    checked), with integer literals, `bytes` above 0 and `align` a power of two up to 4096; the global is a
    constant `RawPtr`, and a global reading it keeps the read, so the block is reserved once. The egress
    folds static-storage globals first, emitting a zeroed `[bytes x i8]` block under
    `Mangle.staticStorage` (`nomu_static_<name>` for the runtime, `<global>::storage` elsewhere; weak-ODR
    from the runtime's files) with the global's value its address. `runtime.nomu` declares
    `let rtStopWorld = Runtime.staticStorage(bytes: 4, align: 4)`; the inline poll loads
    `nomu_static_rtStopWorld`, and C declares it `extern` and writes it from the coordinator threads until
    223.5 moves them, so `__nomu_stop_world` is gone. Tests: three sema unit tests (the constant and the
    read kept, the sites rejected, the argument rules), `Mangle.staticStorage`, and suite cases
    `static-storage` (debug and release: zeroed, aligned, writable across calls, one block for an alias).
  - **223.1.4** The carrier-local slot: `Runtime.carrierLocal()` / `Runtime.setCarrierLocal(p)`, a
    direct TSD read on a key held in a startup constant, checked against `pthread_getspecific` once.
    Replaces `tlsGet`/`tlsSet` and the C `_Thread_local` words as 223.2 moves their state. **Built.** The
    key is `nomu_carrier_key`, an `Int64` the `runtime` package defines; `nomu_runtime_init` creates it
    (`pthread_key_create`) before anything else, writes a sentinel through `pthread_setspecific`, compares
    the direct read with `pthread_getspecific`, aborts with a message if they differ, and clears the slot.
    A read is `mrs TPIDRRO_EL0`, the low three bits masked (as libpthread and Go do on darwin), an
    invariant load of the key, and one load of `[tp + key*8]`; a write is one store there (as Go writes its
    own slot). The register read is side-effecting asm marked gc-leaf, so it is redone after any call and
    is never a statepoint. A host that is not arm64 falls back to `pthread_getspecific`/`setspecific`
    calls until 218. `rt_tls_get`, `rt_tls_set` and their `_Thread_local` word in `core.c` are deleted;
    the 22 call sites in `runtime.nomu` and the scheduler examples are renamed. The TLAB and mod-buffer
    `_Thread_local` words stay in C for 223.2. Tests: the scheduler and stop-the-world suite cases
    (`scheduler-tls` exercises the slot across four carriers); an arm64 binary shows the read as
    `mrs`/`and`/`ldr`/`ldr` with the key load hoisted.
  - **223.1.5** `RawPtr.alloc`/`free` lowered to `posix_memalign` (zero-filled) and `free`. **Built.**
    Each module emits `__nomu_raw_alloc`, an internal gc-leaf helper with `rt_raw_alloc`'s behavior: null
    for no bytes, the alignment raised to a pointer's, `posix_memalign` then `memset`, "out of memory" and
    exit 1 on failure. `RawPtr.alloc` and `Ptr<T>.alloc` call it; `free` is a direct, gc-leaf libc call.
    Neither call is a statepoint now (`rt_raw_alloc` and `rt_raw_free` were not gc-leaf, and the runtime
    object made 290 and 228 calls to them): the runtime object's stack-map records went from 964 to 446 and
    its stack-map section from 64 KB to 30 KB, with its code size unchanged (the helper is `noinline`;
    inlined, it grew the code 6.5% and its own calls became statepoints). Sound because a collection waits
    for every carrier to reach a poll or park, which these calls never do, so no collection can see a frame
    suspended in one; the old records were never used. `rt_raw_alloc`
    and `rt_raw_free` are deleted from `runtime.c` and `runtime.h`. Tests: `raw-mem` checks a zero-byte
    allocation is null and pins the object's references (no `rt_raw_`, `posix_memalign` present); the
    out-of-memory exit was checked by hand (the suite asserts only clean exits).
  - **223.1.6** The heap as a zeroed reservation. **Built.** `RawPtr.alloc` zero-fills with `memset`,
    which writes every page, so the first managed allocation made the whole 256 MiB heap and its tables
    resident: any program with one managed allocation peaked at 262 MB. `Runtime.reserveZeroed(bytes:align:)`
    (runtime tier, subset-legal) lowers to `__nomu_reserve_zeroed`, an emitted gc-leaf, `noinline` helper
    that maps private anonymous memory (zero by the kernel's guarantee, resident only once touched),
    rounds the size up to whole pages, raises the alignment to at least a page (`getpagesize`, since it
    differs by platform), maps `bytes + align` and unmaps the unaligned head and the tail; never freed,
    null for no bytes, "out of memory" and exit 1 on a failed map. `rtImmixNew` reserves the heap and
    its line, block, free-list, defrag and log-bit tables this way. OS-specific values (the `mmap` flags,
    whether the carrier-local slot is read in place) moved into `TargetPlatform` (llvmgen) so Linux is
    one more case ([218](218-linux-support.md) lists both). Measured: `globals_startup` 262 MB → 1 MB;
    `gc_string_field` 490 MB → 397 MB (the rest is its own allocation, which overruns the heap on
    purpose). Release builds, 15 runs each with `hyperfine`: `globals_startup` 15.0 → 2.2 ms;
    `gc_footprint` 17.8 → 5.9 ms and 271 → 18 MB; `binary_tree` 842 → 826 ms (within noise) and 288 →
    165 MB, since its peak live heap no longer drags the untouched blocks in; `micro_alloc` unchanged (it
    never creates the heap). Returning freed pages is [225](225-return-memory-to-the-os.md). Tests: a sema unit test,
    and the GC suite cases, which all run on the reserved heap.
  - **223.1.7** The C globals become runtime-module globals. C declares them `extern` until the stage
    that deletes its user lands. **Built.** `runtime.nomu` declares startup globals, which
    `nomu_runtime_init` computes before the scheduler boots in their proven order:
    - the run settings, read from the environment in Nomu (`rtNurseryReserveOverride`, `rtMatureFloor`,
      `rtGcStress`, `rtGcExternalDriver`; `rtEnvParseInt` follows `atol`);
    - the scheduler, `rtSched = nomuSchedNew()`;
    - the heap, created at startup instead of on the first allocation: `rtSpace = rtImmixNew(rtHeapBlocks)`
      and the barrier's `rtHeapLo`, `rtHeapHi`, `rtLogbitBase`. Creation measured at about 30 µs and three
      page faults (400 runs, a program with one allocation against one with none).

    Nomu code reads these globals directly, and generated code by symbol with invariant loads
    (`loadRuntimeGlobal`). The allocation function lost its double-checked lock and creation path; the
    barrier lost its "active" flag, and its region shift is the constant 3. The six intrinsics that loaded
    the C globals (`schedHandle`, `gcSelfhostSpace`, `gcNurseryReserve`, `gcMatureFloor`, `gcStress`,
    `gcExternalDriver`) are deleted, since a read through one was invisible to the startup ordering
    analysis; eight `rt_prelude` examples read the globals instead. C loses the barrier and setting
    globals, the space pointer and its mutex, and the environment parsing for the settings; it reads
    `nomu_g_rtSched` and `nomu_g_rtGcExternalDriver` as externs. Found on the way: `__nomu_selfhost_alloc`
    anchors the collector's walk with its own frame and return addresses, so it must be a separate frame
    below user code. Without the creation path it became small enough for release builds to inline,
    which broke the anchor (63 release cases under GC pressure crashed); it is now `noinline`, the shape
    it always had in practice (`binary_tree` makes the same calls and runs at the same speed). Tests: the
    suite, whose GC legs all run on the startup heap.
- **223.2 Carrier state and the allocation fast path.** One carrier record behind one carrier-local
  slot, holding the current fiber, the TLAB and the mod-buffer; bind, registry, reset and drain in Nomu,
  the registry growable (the C tables stop at 256 carriers). Deletes `rt_self_tlab_get`,
  `rt_tlab_reset_all`, the mod-buffer functions and `rt_tls_get`/`rt_tls_set`. The inline allocation is
  rebuilt on it:
  - *Today*, every allocation does an acquire load of the space pointer and a null branch, calls
    `rt_self_tlab_get`, bumps, then adds the heap base to a heap-relative cursor. That call is a GC
    statepoint (it is missing from `gcLeafRuntimeFns`; the stack map has a record at its return address),
    so references live across an allocation are spilled and reloaded. The C it calls is built at `-O0`
    (`runtimeArchiveRecipe` passes no optimization flag), so it sets up a frame and calls the
    thread-local thunk through `blr`.
  - *After*: the TLAB pointer is read first, and a null one takes a cold bind, so the per-allocation
    space load and branch go away (223.1.7 already creates the space at startup). Cursor and limit are addresses, so the
    heap-base add goes away. Nothing on the hit path is a statepoint.
  - *The carrier-local read.* A fiber can resume on another carrier after a park, so the read must happen
    again after any park and never be cached across a call. Options: a gc-leaf call to a getter;
    `pthread_getspecific` on a key the runtime creates; or the thread's TSD slot read directly (`mrs
    tpidrro_el0`, then `ldr [tp, key*8]`) as inline asm with side effects, which is how libpthread's own
    `pthread_getspecific` reads it and how Go reaches its TLS on darwin/arm64. A scratch check returned
    the `pthread_setspecific` value for a dynamic key. Recommended: the direct read, checked against
    `pthread_getspecific` once at bind; Linux's form goes on [218](218-linux-support.md)'s list.
  - *Measured in isolation*, a C bump loop costs about 2.25 ns per bump whichever way the TLAB pointer is
    reached (`-O0` getter, `-O2` getter, `pthread_getspecific`, direct read, register): the cursor's load
    and store chain bounds it. The gain is in the statepoint, the call and the space load around the read.
  - *Inlining*: `__nomu_selfhost_alloc` is `noinline` because its slow path reads its own frame and
    return addresses to anchor the collector's walk. Inlining the hit path into user code means moving
    that anchor capture into an out-of-line slow-path function.
  - *Layout*: 64 bytes, `{ cursor, limit, block, line, stressLimit, stressBytes, allocObjects,
    allocBytes }`; the last two are [159](159-gc-observability.md).6's counts.
  - *Measure* against a baseline taken first: an allocation-bound Nomu benchmark with references live
    across allocations, the instructions at one inlined allocation site, and stack-map records per binary.

  Decisions:
  - **The current fiber is a field of the record.** The slot holds the record; a fiber read is slot →
    record → fiber, one load more than today, and an allocation is slot → record. Allocation runs far more
    often than fiber reads, which sit on the park and spawn paths. The other forms were the fiber in the
    slot pointing to its carrier's record (the extra load moves to every allocation) and two keys (no
    extra load, two slots to keep consistent at every switch).
  - **The registry is an intrusive list.** Each record has a `next` field; a carrier joins with one CAS
    when it binds, and stop-the-world walks the list. Records live for the process, so nothing is ever
    removed, and there is no lock and no growth. A growable array under a lock was the alternative.
  - **The barrier slow path moves here from 223.3.** `rt_gc_write_barrier` is the mod-buffer's only C
    user, and once the mod-buffer is in the record, C reaching it would mean a Nomu getter called from C,
    the edge the floor-up rule forbids. It never polls, so it needs no new function property, only the
    gc-leaf call site it has today.
  - **Binding is lazy.** A null record takes a cold bind on the miss path: one predictable branch per
    allocation. Binding eagerly (the main thread at runtime init, each carrier at start) would remove the
    branch, but a thread that allocates unbound would crash; 223.2.5 tries it if the branch shows.

  Work:
  - **223.2.1** Baseline: an allocation-bound benchmark with references live across allocations, the
    instructions at one allocation site, and stack-map records per binary, before any change. **Done.**
    New benchmark `examples/benchmarks/alloc_live`: 20,000 rounds each build a 1000-node list front to
    back (the previous head live across every allocation) and walk it; 98% mutator time (`gc_record`: 9
    cycles, 3.4 ms of 156 ms). `tools/stackmap-count.py` counts stack-map records. Apple M3 Max, release,
    `hyperfine -N`, 20 runs:

    | | wall | peak RSS | stack-map records (user / runtime / other) |
    |---|---|---|---|
    | `alloc_live` | 145.7 ± 0.8 ms | 76 MB | 18 / 458 / 6 |
    | `binary_tree` | 776.9 ± 7.6 ms | 165 MB | 38 / 458 / 6 |

    `binary_tree` spends 37% of its time collecting (40 cycles), so it is the mixed case.

    The hit path, by disassembly. User code calls `__nomu_selfhost_alloc` (1 instruction), which runs 17
    on a hit: a frame, the call to `rt_self_tlab_get`, cursor and limit, the bump, and the `rtHeapLo` load
    and add (LLVM already sank the `rtSpace` load to the miss path). `rt_self_tlab_get`, built at `-O0`,
    runs 17 more and calls dyld's `_tlv_get_addr` twice, 8 each. Total: 51 instructions and four
    call-return pairs per allocation. Every reference live across the allocation is spilled before the
    call and reloaded after it, because the call to `__nomu_selfhost_alloc` is a statepoint.

    When a root shaped as a struct or enum (an `Option<Node>`) is live across the allocation, codegen
    calls `__nomu_gc_alloc_rooted` instead, a `noinline` wrapper kept so the call's deopt bundle survives
    to the statepoint rewrite; it adds a frame (4 instructions, one more call). Both benchmarks take this
    path. The slow path's anchor then names the wrapper's frame, one below user code, so 223.2.4 has to
    handle both forms.
  - **223.2.2** The carrier record and its registry: the slot holds the record, the fiber becomes a
    field; bind, reset and drain in Nomu; the barrier slow path in Nomu. Deletes `rt_self_tlab_get`,
    `rt_tlab_reset_all`, `rt_self_modbuf_get`, `rt_modbuf_reset_all`, `rt_modbuf_drain`,
    `rt_gc_write_barrier`, their `_Thread_local` words and tables. **Built.** The record is 128 bytes
    (`runtime.nomu`, "The carrier record"): the 64-byte TLAB at 0, so a record is its own TLAB pointer and
    `rtTlabAlloc`/`rtImmixRefill` are unchanged; the fiber at 64; the mod-buffer header at 72; the registry
    link at 96. The registry head is `rtCarriers`, a static-storage word. `rtCarrierBind` allocates,
    pushes with a CAS and stores the record in the slot; `rtSchedLoop` binds on entry, and `rtCarrier()`
    binds a thread that reaches allocation or the barrier unbound. The twelve fiber readers use
    `rtCurrentFiber()`. The resets run at the end of the three Nomu collect functions, after the collect
    interval closes, so C calls nothing new; the minor's drain is `rtCarriersDrainModBufs`. The barrier's
    slow path is `rtRememberStore`, the routine the mailbox stores already used, called from
    `__nomu_remember` as a gc-leaf call (`markCallGCLeaf`); `runtimePreludeFn` names a prelude function
    from codegen. The `gcSelfModBuf` and `gcDrainModBufs` intrinsics are deleted (`gen_barrier` reads
    `rtSelfModBuf()`). The allocation function reads the record from the slot with a null branch to the
    bind, so `rt_self_tlab_get` goes here rather than in 223.2.3. Measured against a baseline taken in the
    same session: `alloc_live` 153.6 → 117.5 ms (−23.5%), `binary_tree` 803.6 → 653.2 ms (−19%);
    stack-map records 482 → 472 and 502 → 492.

    Found on the way and fixed: the root walk skipped a spawned fiber that had not started (state 0), whose
    argument at fib+192, the spawn's managed closure environment, is its only reference. A collection while
    fibers waited to start freed the environment; the fiber read a garbage depth from it and spawned
    without end (46 GB resident before the system killed it). The walk now roots fib+192 when non-null,
    and `rtSchedFiberMain` clears it on the first switch-in, so a started fiber's word never goes stale.
    Tests: `gc-many-carriers` (511 fibers, 320 carriers, collections while fibers are queued; 30 of 30 runs
    clean), the full tier (751 passed), `nm` showing none of the deleted C symbols.
  - **223.2.3** The fast path on the record: cursor and limit as addresses; no space load, no base add, no
    call on the hit path. **Built.** `rtImmixRefill` stores `heapLo + offset` for the hole's start and
    end, `rtTlabAlloc` turns the cursor back into a pointer from the heap base, and the inline hit returns
    the old cursor directly; the `rtSpace` load moved into the miss block. The collector's own copy
    allocator (`rtImmixAlloc`) keeps its heap-relative cursor in the space descriptor. The hit path is 20
    instructions with no call: the frame, the slot read (`mrs`, mask, two loads for the key, the slot), the
    null branch, the bump, the return. Against 223.2.1's 51 instructions and four call-return pairs.
    Measured in one session (baseline / 223.2.2 / 223.2.3): `alloc_live` 154.0 / 117.1 / 115.8 ms,
    `binary_tree` 801.9 / 651.6 / 658.7 ms (the last within noise). The gain is 223.2.2's; this step's
    own is about 1% on `alloc_live`. Stack-map records unchanged. Tests: the full tier (751 passed).
  - **223.2.4** The hit path inlined into user code, with the anchor capture in an out-of-line slow-path
    function. **Built.** `__nomu_gc_alloc` is the hit path, `alwaysinline`: the slot read, a null branch,
    the bump. A miss calls `__nomu_alloc_slow`, `noinline`, which captures the anchor (its return and frame
    addresses name the allocating function, which calls it directly), gets the record through `rtCarrier()`
    (binding one on a thread that has none) and calls `rtTlabAlloc`. With shaped roots live across the
    allocation, `rtAllocManaged` emits the hit path in the allocating function itself and the slow call
    carries the `deopt` bundle, as the poll does; `__nomu_gc_alloc_rooted` and its extra frame are gone.
    `__nomu_selfhost_alloc` is renamed with it. In a loop the hit path is 9 instructions (`mrs`, mask, the
    slot load, the null branch, cursor and limit, the add, the compare, the store), with the key's load
    hoisted out. Measured in one session (baseline / 223.2.3 / 223.2.4): `alloc_live` 154.6 / 116.6 /
    117.7 ms (within noise; its loop still runs the write barrier on each new node and reloads the
    `Option` home slot), `binary_tree` 804.8 / 656.1 / 578.7 ms (−12% for this step, −28% for 223.2).
    Stack-map records 472 → 470 and 492 → 490. Tests: the full tier (751 passed), `--check-reproducible`
    (1689 identical), the 18 Bazel test targets.
  - **223.2.5** Measure against 223.2.1's baseline. **Done.** All builds in one session, `hyperfine -N`,
    30 runs each:

    | | `alloc_live` | `binary_tree` |
    |---|---|---|
    | baseline (223.2.1) | 145.8 ± 1.5 ms | 792.1 ± 4.5 ms |
    | 223.2.2, the record in Nomu | 111.8 ± 1.4 ms | 651.7 ± 5.0 ms |
    | 223.2.3, addresses | 110.5 ± 1.5 ms | 656.5 ± 3.2 ms |
    | 223.2.4, the hit path inlined | 109.7 ± 1.8 ms | 582.3 ± 6.2 ms |
    | eager bind (experiment) | 109.9 ± 1.7 ms | 581.9 ± 6.8 ms |

    223.2 overall: `alloc_live` −25%, `binary_tree` −26%. The hit path went from 51 instructions and four
    call-return pairs to 9 instructions inline; stack-map records 482 → 470 and 502 → 490. The eager
    bind (the null branch removed, every allocating thread bound up front) measured within noise on both,
    so the lazy bind stays. `alloc_live`'s loop is now bound by the write barrier on each new node and
    the `Option` home-slot reload.
- **223.3 The forwarders.** `fiber_spawn`, `spawn_join`, `rt_sleep_ms`, `__nomu_gc_poll_slow` and the
  mailbox calls become frame-shaped Nomu functions reading the scheduler handle from a global. **Built,**
  by a route that needs no language surface: codegen emits the forwarders, as it emits
  `__nomu_alloc_slow`, so blocker 3's function property is not needed for them.
  - The forwarders that park the caller (`__nomu_gc_poll_slow`, `__nomu_spawn_join`, `__nomu_sleep_ms`)
    are `noinline` internal functions built by `schedForwarder` (`LLVMGenRuntime.swift`): each reads its
    caller's anchor (`emitCallerAnchor`, the return address and the frame address + 16, as C's
    `RT_USER_ANCHOR` did) and `rtSched`, and calls the Nomu scheduler function. They use no GC strategy,
    so their calls add no stack-map records; the walk of a parked fiber starts at the caller's frame.
    Release builds turn the call into a tail call after the anchor is read, and promote the join's handle
    load into the caller.
  - The others are direct calls at the site with `rtSched` loaded there: `nomuSchedSpawn` at a spawn,
    `nomuSchedActorSend` at a send, `nomuSchedMailboxPop` in the drain loop (the last two called with the
    managed mailbox and message, so they stay tracked across the call).
  - Deleted from C: `fiber_spawn`, `spawn_join`, `rt_sleep_ms`, `rt_mailbox_pop`, `rt_actor_send`,
    `__nomu_gc_poll_slow`, and the actor mutex `rt_mutex_*`, which had no callers; with their
    `runtime.h` declarations and `SpawnHandle`. `RT_USER_ANCHOR` stays for `rt_read_line` (223.5).
  - Tests: the full tier (754 passed; `escape-stack` and `subset-poll` now check the poll slow path as a
    defined symbol), `--check-reproducible` (1707 identical), the 18 Bazel test targets, and `nm` showing
    none of the deleted C symbols.
- **223.4 GC metadata.** The type-descriptor accessors and the frame-index check, over `section$start$…`
  symbols. **Built.**
  - The accessors are Nomu functions in `runtime.nomu` ("GC type descriptors"): `rtTypeSize`,
    `rtTypeKind`, `rtTypeStride`, `rtShapedCount`, `rtTypeHeaderSize`, `rtHeaderPtrCount`,
    `rtHeaderOffsetAt`, and the enumerator `rtLiveCount` / `rtLiveOffsetAt`, reading the descriptor and
    pointer-map sections through `Runtime.gcDescBase()` and `Runtime.gcPtrmapBase()` (linker
    section-bracket symbols, like `gcStackmapBase`). `gcTypeCount` stays an intrinsic, lowered inline as
    the section's size over the 32-byte record; `rtDescSize` replaces `gcDescSize`. Thirteen per-field
    intrinsics are deleted; 101 call sites were rewritten.
  - The enumerator keeps no scratch state: a shaped type's count and indexed offset each walk the encoded
    map, recursing into sub-shapes, so any thread may call them. The C version's two `_Thread_local`
    scratch buffers are gone. A shaped tag's logical right shift is a division by a power of two from a
    startup table (`rtShrLogical`), since Nomu has no shift operator.
  - `Runtime.loadInt32(_:at:)` is a sign-extending 32-bit load (one `ldrsw`) for the `int32` descriptor
    fields and map entries, since Nomu has no 32-bit integer type. When it has one, `RawPtr.load` as that
    type replaces the intrinsic.
  - `Runtime.fatal(_:)` writes a string literal and a newline to standard error and aborts (gc-leaf;
    `write` and `abort` joined `gcLeafRuntimeFns`). The frame-index check uses it: a startup global
    (`rtFrameIndexChecked`) reads the index's magic and version and stops a binary linked without
    `nomu build`. 223.6's bounds trap can use it too.
  - Deleted from C: the descriptor accessors, `nomu_gc_live_offsets` and its scratch buffers, the
    frame-index check, and `getsectiondata` / `_mh_execute_header`, the section half of blocker 5.
    `runtime.c` is 414 lines, from 889 at the start of 223.2.
  - Measured: `binary_tree` 593.4 → 402.7 ms (−32%), the collector's per-field reads now inlined loads in
    place of `-O0` C calls. Tests: the full tier (754 passed), `--check-reproducible` (1707 identical), the
    18 Bazel test targets; the frame-index failure by hand (a copy with its magic overwritten prints the
    message and exits with SIGABRT).
- **223.5 Entry points.** `main` emitted by codegen; thread entries as C-ABI functions safe without a
  fiber; the coordinator threads (shaped by [158](158-gc-packaging.md)), the run-setting parsing, and line
  input with its poller. The coordinator threads move with 158; the rest is staged here.
  - **223.5.1 `main` from codegen.** **Built.**
    - `emitProcessEntry` (`LLVMGenRuntime.swift`) emits `int main(void)` into the entry object: the
      runtime's init function, `rt_gc_threads_start` (the coordinator threads, C until 158), and
      `nomuSchedBoot` with `rtCarrierCount` carriers. Its loads of `rtSched` and `rtCarrierCount` are plain,
      since the init call that stores them is in the same function. The first fiber's entry is an emitted
      internal `__nomu_main_entry` (`ptr (ptr)`, no GC strategy, as C's was) calling the program's `main`.
    - `NOMU_CARRIERS` is the runtime startup global `rtCarrierCount` (4 unless set to 1 or more).
    - The drain loop: each module compiles alone, so the entry object cannot know whether another module
      uses actors. `nomu_actor_drain` is now weak-ODR in every module that uses actors, and creating an
      actor stores its address in the scheduler's drain slot (`registerActorDrain`, `sched`+120). The
      first send follows a creation and takes the scheduler lock, which orders the store before any
      mailbox fiber reads the slot. `nomuSchedBoot` loses its drain parameter. An actor-less program
      links no drain loop. Considered: an extern-weak import (needs a `-U` link flag on Mach-O) and the
      entry object always emitting the drain (actor code in every binary).
    - Fixed on the way: a program with actors in two modules failed to link (`duplicate symbol
      '_nomu_actor_drain'`, each module's copy external). Suite case `actor-two-modules`. Exporting an
      actor type across modules fails separately; that is [171](171-modules-cleanup.md).9.
    - Deleted from C: `main`, `__rt_main_entry`, the weak `nomu_actor_drain`, and the `nomuSchedNew` /
      `nomuSchedBoot` declarations. `runtime.c` is 376 lines.
    - Tests: the full tier (754 passed) before the new case, then the fast tier with it (344 passed);
      `--check-reproducible` (1719 identical); the 18 Bazel test targets; `nm` showing no `main` or drain in
      the runtime archive and no drain loop in an actor-less binary.
  - **223.5.2 Line input in Nomu.** **Built.** `rt_read_line` becomes an emitted forwarder
    (`schedForwarder`) over a Nomu `rtReadLine`: the runtime's futex lock, a `RawPtr` buffer, an intrusive
    waiter list, a started flag under the stdin lock for the one-time poller start, and the poller on
    `Runtime.threadCreate` over the `kqueue`/`kevent` intrinsics. The readiness check is a new
    `Runtime.poll(fd:)` intrinsic lowered to libSystem `poll`, keeping today's behavior; the stdlib's I/O
    design revisits it. Deletes line input, the poller and `RT_USER_ANCHOR`.
    - **The line is a collected `String`.** The runtime copies the line into a raw buffer and returns its
      pointer and length; the emitted code builds a `small` string (15 bytes or fewer) or an `allocHeap`
      one, then frees the raw buffer. Today's lines are immortal `calloc` buffers never freed, one leak per
      line. The second copy is the cost: the allocation is a safepoint, so the runtime cannot keep the
      stdin lock held across it. Considered: an immortal `String` built by the runtime through a new
      `Runtime` intrinsic (one copy, the leak kept).
    - **Scope:** the stdin poller as it is (one kqueue, one waiter list, one-shot arming); a general fd
      poller belongs to the stdlib's I/O design. Only the macOS path is ported; C's blocking-`read`
      fallback goes, and Linux adds `epoll` here ([218](218-linux-support.md)).
    - As built: `rtReadLine` and the poller (`rtStdinPollerMain`, on `Runtime.threadCreate`) are in
      `runtime.nomu` ("Line input and the stdin poller"), with their state in one static-storage block
      (`rtStdin`); the buffer keeps a head offset, so a line is taken without moving the rest. `readLine`
      calls an emitted `__nomu_read_line` (`EgressBuiltins.readLineFn`): a GC frame that calls the parking
      forwarder `__nomu_read_line_park`, builds the string from the returned `{count, bytes}` block, and
      frees it. After the heap allocation only gc-leaf calls follow, so the fresh buffer stays put until
      it is returned. `Runtime.poll(fd:)` lowers to `poll` over one stack `pollfd`; `poll` and `read` are
      now gc-leaf.
    - Deleted from C: line input, the poller, `RT_USER_ANCHOR`, `nomuSchedCurrent`'s declaration (and the
      Nomu function, which only C called), the C `String` type and `nomu_str_make`. `runtime.c` is 224
      lines, holding only the GC driver threads, `rt_free` and the bounds trap.
    - Tests: suite case `read-line-long` (lines of 15 and 16 bytes, 38, 10,000 past the first 8 KiB
      buffer, and an unterminated 20-byte tail, under GC stress with collections while the heap lines are
      held). The full tier (756 passed), `--check-reproducible` (1725 identical), the 18 Bazel test
      targets, and `nm` showing no C line-input symbols.
- **223.6 The remainder.** **Built,** except `runtime.c` leaving the archive, which waits for the
  coordinator threads (158). `rt_print_double` (shortest round-trip formatting, today `snprintf`), the
  bounds trap, the timing helper; then the C members leave the runtime archive. Blocker 6 follows for
  192.
  - **`print(Double)`:** codegen emits the same loop as an LLVM function (`snprintf("%.*g")` at rising
    precision until `strtod` reads the value back, `.0` appended to an integer-looking result, out
    through `printf`). A location change, with the algorithm unchanged; a shortest round-trip algorithm
    in Nomu is [227](227-double-formatting-in-nomu.md). Considered: the loop in `runtime.nomu` over
    runtime-only `snprintf`/`strtod` intrinsics (its output must still go through `printf`'s buffer).
  - **The asm self-test** (`rt_asm_selftest`, `Runtime.asmSelfTest`, the `asmswitch` case) is deleted:
    `fiberswitch` drives the same round-trip from Nomu.
  - **The bounds trap** becomes a `runtime.nomu` function with the same message (`rtBufInt`,
    `Runtime.writeFd`, `Runtime.fatal`), its calls still gc-leaf. **The timing helper** (`time_monotonic`)
    lowers to the `Runtime.monotonicNanos` call (the same `CLOCK_MONOTONIC`). `rt_free` has no callers and
    goes.
  - `core.c` leaves the archive; `runtime.c` stays, holding only the coordinator threads, until 158.
  - As built: `EgressBuiltins.printDoubleFn` emits `__nomu_print_double` (internal, no GC strategy, its
    calls gc-leaf). `rtBoundsTrap` is in `runtime.nomu`. `core.c` is deleted, with its embedding
    (`embed.sh`, the genrule, `EmbeddedSources.coreC`) and archive member. The archive is `runtime.o`
    (only `rt_gc_threads_start` exported, 214 lines) and `rtasm.o`.
  - Tests: new suite cases `double-print` (edge values: shortest forms, all 17 digits, the smallest
    subnormal, the smallest normal, the largest finite value, infinities, NaN, plus `time_monotonic`)
    and `double-core` (an existing example no case ran); both outputs identical to the old compiler's.
    The bounds trap by hand: the same message and exit status 134 as the old compiler (the suite cannot
    expect a nonzero exit). The full tier (755 passed, `asmswitch` removed), `--check-reproducible` (1731
    identical), the 18 Bazel test targets.

## Refs

`src/runtime/embedded/runtime.c`, `core.c`, `runtime.h`; `runtimeArchiveRecipe`
(`src/driver/sources/RuntimeArchive.swift`); `nomuSelfhostAlloc`, `gcLeafRuntimeFns`
(`src/llvmgen/LLVMGenRuntime.swift`); `PointerIntrinsics.swift` (sema), `SSAIRToLLVM.swift` (intrinsic
lowering). `../../internals/runtime-subset.md` §5 (runtime intrinsics on `Runtime`),
`../../language/modules.md` (globals), `../../internals/unsafe-memory.md`.
[128](128-self-hosting-runtime.md), [158](158-gc-packaging.md), [159](159-gc-observability.md),
[127](127-lxr-collector.md), [130](130-ffi-c-abi.md), [192](192-bazel-friendliness.md),
[218](218-linux-support.md), [222](222-public-compile-time-constants.md).
