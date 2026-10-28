"""`opt_binary`: an executable built with `compilation_mode=opt` whatever the build's own mode.

A test that runs `nomu` (the driver's `build_tests`) takes it through `opt_binary`, so `bazel test` without `-c opt`
still runs the optimized compiler: a fastbuild `nomu` is several times slower on every compile.
"""

def _opt_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_opt = transition(
    implementation = _opt_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _opt_binary_impl(ctx):
    binary = ctx.attr.binary[0][DefaultInfo]
    exe = ctx.executable.binary
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = exe, is_executable = True)
    runfiles = ctx.runfiles(files = [exe]).merge(binary.default_runfiles)
    return [DefaultInfo(executable = out, files = depset([out]), runfiles = runfiles)]

opt_binary = rule(
    implementation = _opt_binary_impl,
    attrs = {
        "binary": attr.label(cfg = _opt, executable = True, mandatory = True),
    },
    executable = True,
)
