"""A bespoke, version-stable `cc_toolchain_config` rule (Unit A).

This rule returns `CcToolchainConfigInfo` and is assembled exclusively from the
PUBLIC rules_cc surface: the constructors in
`@rules_cc//cc:cc_toolchain_config_lib.bzl`, the `ACTION_NAMES` constants in
`@rules_cc//cc:action_names.bzl`, and the built-in
`cc_common.create_cc_toolchain_config_info()`. It deliberately avoids anything
under `@rules_cc//cc/private/...` so the rule stays stable across rules_cc and
Bazel versions.

Path invariant: every path-typed attribute (`builtin_sysroot`,
`cxx_builtin_include_directories`, `tool_paths` values, `sysroot_path`) is an
exec-relative string of the form `external/<repo_name>/...` that the upstream
macro has already computed. This rule performs NO path computation or label
resolution -- callers pass concrete exec-relative strings, never labels.
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
    "with_feature_set",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

# Compile actions that consume C and C++ compile flags. Assembly preprocessing
# is included so the sysroot/target flags reach assembler runs too.
_ALL_COMPILE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.linkstamp_compile,
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.lto_backend,
    ACTION_NAMES.clif_match,
]

# Compile actions that are C++-only (used for `-std=c++NN` and friends).
_CPP_COMPILE_ACTIONS = [
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.linkstamp_compile,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
]

# Link actions that consume link flags.
_ALL_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
]

def _impl(ctx):
    # Compile flags applied unconditionally to every compile action, plus the
    # compilation-mode-gated opt/dbg flag sets keyed off the `opt`/`dbg`
    # marker features that Bazel enables based on `--compilation_mode`.
    default_compile_flags = feature(
        name = "default_compile_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ctx.attr.compile_flags)],
            ),
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ctx.attr.opt_compile_flags)],
                with_features = [with_feature_set(features = ["opt"])],
            ),
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ctx.attr.dbg_compile_flags)],
                with_features = [with_feature_set(features = ["dbg"])],
            ),
        ] if ctx.attr.compile_flags or ctx.attr.opt_compile_flags or ctx.attr.dbg_compile_flags else [],
    )

    # C++-only flags (e.g. `-std=c++20`).
    default_cxx_flags = feature(
        name = "default_cxx_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _CPP_COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ctx.attr.cxx_flags)],
            ),
        ] if ctx.attr.cxx_flags else [],
    )

    # Link flags applied to every link action. `link_flags` already carries
    # `-lm -lstdc++` (there is no `link_libs` parameter on
    # `create_cc_toolchain_config_info`).
    default_link_flags = feature(
        name = "default_link_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_LINK_ACTIONS,
                flag_groups = [flag_group(flags = ctx.attr.link_flags)],
            ),
        ] if ctx.attr.link_flags else [],
    )

    # `builtin_sysroot` alone does NOT cause Bazel to emit `--sysroot`; an
    # explicit enabled feature is required for both compile and link actions.
    sysroot_feature = feature(
        name = "sysroot",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS + _ALL_LINK_ACTIONS,
                flag_groups = [
                    flag_group(flags = ["--sysroot=" + ctx.attr.sysroot_path]),
                ],
            ),
        ],
    )

    # Marker features. `opt`/`dbg` are toggled by Bazel from
    # `--compilation_mode`; the support markers replace top-level
    # `create_cc_toolchain_config_info` args that do not exist.
    supports_start_end_lib = feature(name = "supports_start_end_lib", enabled = True)
    supports_dynamic_linker = feature(name = "supports_dynamic_linker", enabled = True)
    opt_feature = feature(name = "opt")
    dbg_feature = feature(name = "dbg")

    features = [
        default_compile_flags,
        default_cxx_flags,
        default_link_flags,
        sysroot_feature,
        supports_start_end_lib,
        supports_dynamic_linker,
        opt_feature,
        dbg_feature,
    ]

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = ctx.attr.toolchain_identifier,
        target_cpu = ctx.attr.target_cpu,
        target_system_name = ctx.attr.target_system_name,
        compiler = ctx.attr.compiler,
        host_system_name = "local",
        abi_version = "unknown",
        abi_libc_version = "unknown",
        builtin_sysroot = ctx.attr.builtin_sysroot,
        cxx_builtin_include_directories = ctx.attr.cxx_builtin_include_directories,
        tool_paths = [
            tool_path(name = name, path = path)
            for name, path in ctx.attr.tool_paths.items()
        ],
        features = features,
    )

cc_toolchain_config = rule(
    implementation = _impl,
    provides = [CcToolchainConfigInfo],
    attrs = {
        "builtin_sysroot": attr.string(
            mandatory = True,
            doc = "Exec-relative target-sysroot path (`external/<tt>`). Sets " +
                  "`builtin_sysroot` on the toolchain config.",
        ),
        "compile_flags": attr.string_list(
            default = [],
            doc = "Flags applied to every compile action unconditionally " +
                  "(e.g. `--target=<triple>`, `--gcc-toolchain=external/<tt>/usr`).",
        ),
        "compiler": attr.string(
            default = "clang",
            doc = "Compiler identifier reported to Bazel.",
        ),
        "cxx_builtin_include_directories": attr.string_list(
            mandatory = True,
            doc = "Exec-relative builtin include directories " +
                  "(`external/<repo_name>/...`). Callers emit each path twice " +
                  "(plain and `/proc/self/cwd/...` form) so cache keys match " +
                  "across sandboxed and unsandboxed actions.",
        ),
        "cxx_flags": attr.string_list(
            default = [],
            doc = "C++-only compile flags (e.g. `[\"-std=c++20\"]`).",
        ),
        "dbg_compile_flags": attr.string_list(
            default = [],
            doc = "Compile flags applied when the `dbg` feature is enabled " +
                  "(`--compilation_mode=dbg`), e.g. `[\"-g\"]`.",
        ),
        "link_flags": attr.string_list(
            default = [],
            doc = "Flags applied to every link action. Already includes " +
                  "`-lm -lstdc++` (there is no `link_libs` parameter).",
        ),
        "opt_compile_flags": attr.string_list(
            default = [],
            doc = "Compile flags applied when the `opt` feature is enabled " +
                  "(`--compilation_mode=opt`), e.g. `[\"-O2\", \"-DNDEBUG\"]`.",
        ),
        "sysroot_path": attr.string(
            mandatory = True,
            doc = "Exec-relative target-sysroot path (`external/<tt>`) emitted " +
                  "as `--sysroot=<sysroot_path>` on compile and link actions " +
                  "via the enabled `sysroot` feature.",
        ),
        "target_cpu": attr.string(
            mandatory = True,
            doc = "Bazel target CPU (`k8`, `aarch64`, ...).",
        ),
        "target_system_name": attr.string(
            mandatory = True,
            doc = "The LLVM target triple (e.g. `aarch64-unknown-linux-gnu`).",
        ),
        "tool_paths": attr.string_dict(
            mandatory = True,
            doc = "Map of tool name (`gcc`, `cpp`, `ld`, `ar`, ...) to its " +
                  "exec-relative per-tool wrapper path (`external/<repo_name>/...`).",
        ),
        "toolchain_identifier": attr.string(
            mandatory = True,
            doc = "Unique toolchain identifier.",
        ),
    },
    doc = "Returns `CcToolchainConfigInfo` for an aptprep-generated CC " +
          "toolchain. All path-typed attributes are exec-relative " +
          "`external/<repo_name>/...` strings computed by the caller; this " +
          "rule performs no path computation.",
)
