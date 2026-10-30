// What emitted code needs to know about the OS and architecture it runs on. The target is the host
// (`LLVMBridge` builds for the default triple), so the values come from the compiler's own build. Every
// OS-specific value the egress uses lives here, so a new OS is one more case (Linux: task 218).
struct TargetPlatform {
    enum OS { case darwin, linux }
    let os: OS
    let isArm64: Bool

    static let host: TargetPlatform = {
        #if os(Linux)
        let os = OS.linux
        #else
        let os = OS.darwin
        #endif
        #if arch(arm64)
        return TargetPlatform(os: os, isArm64: true)
        #else
        return TargetPlatform(os: os, isArm64: false)
        #endif
    }()

    // `mmap` protection and flags for private, zero-filled anonymous memory. `PROT_READ | PROT_WRITE` is the
    // same everywhere; `MAP_ANON` is 0x1000 on darwin and `MAP_ANONYMOUS` 0x20 on Linux.
    var protReadWrite: Int32 { 0x1 | 0x2 }
    var mapPrivateAnonymous: Int32 {
        switch os {
        case .darwin: return 0x0002 | 0x1000
        case .linux:  return 0x02 | 0x20
        }
    }

    // Whether the carrier-local slot is read and written in place. On darwin-arm64 it is the thread's TSD
    // array (`TPIDRRO_EL0`) indexed by the key, as libpthread reads it. Elsewhere it goes through
    // `pthread_getspecific` / `pthread_setspecific` until a direct form is written (glibc keeps keys in a
    // two-level table inside its thread descriptor, so its direct read differs).
    var readsCarrierLocalDirectly: Bool { os == .darwin && isArm64 }
}
