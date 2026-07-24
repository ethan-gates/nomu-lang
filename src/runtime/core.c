// Nomu core floor (M4.13) — the C primitive value operations that Nomu can't yet
// express (String has no in-language buffer primitive). Pure: depends only on the
// allocation seam. Shrinks as primitives migrate into the Nomu stdlib.
// (Design: m4.13-spec.md §1, the standard-library C floor.)
#include "runtime.h"
#include <string.h>

String rt_str_lit(const char* data, int64_t len) {
    return (String){ .data = (char*)data, .len = len };
}

String rt_str_concat(String a, String b) {
    int64_t len = a.len + b.len;
    char* data = (char*)rt_alloc(sizeof(ObjectHeader) + len + 1) + sizeof(ObjectHeader);
    memcpy(data, a.data, (size_t)a.len);
    memcpy(data + a.len, b.data, (size_t)b.len);
    data[len] = '\0';
    return (String){ .data = data, .len = len };
}
