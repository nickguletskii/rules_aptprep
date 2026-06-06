"""Minimal platform transition wrapper for the e2e cc cross-build.

`platform_transition_binary` rebuilds its `src` under a fixed `--platforms`
value (the `platform` attr) and re-exposes the resulting binary. This lets
`bazel test //...` exercise the aarch64 cross build with no special command-line
flags: the aarch64 toolchain is selected by toolchain resolution because the
configured target's platform is `:linux_aarch64`.

A `genrule` would NOT transition its deps to another platform; an explicit
Starlark transition (with the `_allowlist_function_transition` attr required for
outgoing transitions) is the supported mechanism on Bazel 8.x and 9.x.
"""

def _impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "_bin")
    src = ctx.attr.src[0][DefaultInfo].files.to_list()[0]
    ctx.actions.symlink(output = out, target_file = src)
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
    )]

def _platforms_transition(_settings, attr):
    return {"//command_line_option:platforms": str(attr.platform)}

platform_transition = transition(
    implementation = _platforms_transition,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

platform_transition_binary = rule(
    implementation = _impl,
    attrs = {
        "src": attr.label(mandatory = True, cfg = platform_transition),
        "platform": attr.label(mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
