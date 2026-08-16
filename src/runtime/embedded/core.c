// Nomu core floor (M4.13) — the C primitive value operations that Nomu can't yet
// express (String has no in-language buffer primitive). Pure: depends only on the
// allocation seam. Shrinks as primitives migrate into the Nomu stdlib.
// (Design: m4.13-spec.md §1, the standard-library C floor.)
#include "runtime.h"
#include <stdint.h>
#include <string.h>
#include <stdlib.h>   // strtod — shortest round-trip Double formatting

// Print a Double: the fewest significant digits that round-trip back to the same value, always
// with a decimal point (so a whole-valued Double reads as `42.0`, never `42`), then a newline.
void rt_print_double(double x) {
    char buf[32];
    // 17 significant digits round-trip any IEEE-754 double; stop at the first precision that does.
    int prec = 17;
    for (int p = 1; p < 17; p++) {
        snprintf(buf, sizeof buf, "%.*g", p, x);
        if (strtod(buf, NULL) == x) { prec = p; break; }
    }
    snprintf(buf, sizeof buf, "%.*g", prec, x);
    // If %g emitted a plain integer (no '.', exponent, or inf/nan letters), append ".0".
    if (!strpbrk(buf, ".eEnN")) {
        size_t n = strlen(buf);
        buf[n] = '.'; buf[n + 1] = '0'; buf[n + 2] = '\0';
    }
    printf("%s\n", buf);
}

// ===========================================================
//                         Strings
// ===========================================================
String rt_str_lit(const char* data, int64_t len) {
    return (String){ .data = (char*)data, .len = len };
}

String rt_str_concat(String a, String b) {
    int64_t len = a.len + b.len;
    // Immortal (non-moving) buffer: String is `{ addr0 data, i64 len }` (Q6), so `data` is an
    // untracked raw pointer a moving collector would leave dangling — pin the buffer (M6 · 6.2.4).
    char* data = (char*)rt_alloc_immortal(sizeof(ObjectHeader) + len + 1) + sizeof(ObjectHeader);
    memcpy(data, a.data, (size_t)a.len);
    memcpy(data + a.len, b.data, (size_t)b.len);
    data[len] = '\0';
    return (String){ .data = data, .len = len };
}

const uint64_t FNV_PRIME = 1099511628211ULL;
const uint64_t FNV_OFFSET_BASIS = 14695981039346656037ULL;
int64_t __string_hash_int(String s) {
    uint64_t hash = FNV_OFFSET_BASIS;
    char* key = s.data;
    while (*key) {
        hash ^= (uint64_t)(unsigned char)(*key);
        hash *= FNV_PRIME;
        key++;
    }
    return hash;
}

// Byte equality. Returns 0/1 as int64_t; codegen truncates to the Bool i1 (a portable ABI, and
// no dependency on a platform boolean type).
int64_t __string_eq_bool_string(String l, String r) {
    if (l.len != r.len) return 0;
    return memcmp(l.data, r.data, (size_t)l.len) == 0;
}
