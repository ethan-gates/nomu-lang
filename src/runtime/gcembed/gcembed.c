// M6 · 6.1.0 — read nomuc's own embedded GC-archive section.
//
// The nomuc link inserts the Rust/MMTk static archive into the `__DATA,__nomu_gc` Mach-O
// section (via `-Wl,-sectcreate`), so nomuc stays a single atomic file: the archive rides
// inside the executable and is extracted to a cache file at emitted-program link time. This is
// the same `getsectiondata` path runtime.c uses for `__llvm_stackmaps`. Throwaway alongside the
// 6.1.0 probe once 6.1.1 lands the real binding + distribution.

#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>

// Pointer to the embedded archive bytes (NULL if the section is absent — e.g. a nomuc built
// without the embed); *size receives the byte length.
const void *nomu_gc_embedded_section(unsigned long *size) {
    return getsectiondata(&_mh_execute_header, "__DATA", "__nomu_gc", size);
}
