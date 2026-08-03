"""M8.1 · 8.1.1 — module extension that fetches the pinned llvm-project source (`@llvm-raw`)
and pyyaml, so `llvm_configure` (loaded from `@llvm-raw`) can generate `@llvm-project`.

We can't `http_archive(@llvm-raw)` directly in MODULE.bazel and then load `configure.bzl` from
it — a `use_repo_rule` repo isn't visible as a bzl source in the same module. Creating it inside
an extension and exposing it via `use_repo` makes it loadable (this mirrors the overlay's own
`utils/bazel/extensions.bzl`). Design: m8-spec.md §8.1.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# LLVM 23 — release/23.x @ 2026-07-31 (see MODULE.bazel note).
_LLVM_COMMIT = "af6b25907abe4bf391dc17d3d1106cc58a0252b6"

_PYYAML_BUILD = """\
load("@rules_python//python:defs.bzl", "py_library")

package(
    default_visibility = ["//visibility:public"],
    licenses = ["notice"],  # BSD/MIT-like (PyYAML)
)

py_library(
    name = "yaml",
    srcs = glob(["yaml/*.py"]),
)
"""

def _llvm_raw_impl(_module_ctx):
    http_archive(
        name = "llvm-raw",
        build_file_content = "# empty",
        integrity = "sha256-BRccRYlAeIfQHCTA+i9PViwOP6UrX8MoYeVO0o/zjyI=",
        strip_prefix = "llvm-project-" + _LLVM_COMMIT,
        urls = ["https://github.com/llvm/llvm-project/archive/" + _LLVM_COMMIT + ".tar.gz"],
    )
    http_archive(
        name = "pyyaml",
        url = "https://github.com/yaml/pyyaml/archive/refs/tags/5.1.zip",
        sha256 = "f0a35d7f282a6d6b1a4f3f3965ef5c124e30ed27a0088efb97c0977268fd671f",
        strip_prefix = "pyyaml-5.1/lib3",
        build_file_content = _PYYAML_BUILD,
    )

llvm_raw = module_extension(implementation = _llvm_raw_impl)
