"""Public `aptprep_cc_toolchain` macro (Unit C).

Given resolved sysroot exec-paths and config values, this macro instantiates the
full CC toolchain: the `cc_toolchain_config` rule (Unit A), the §6.4 filegroups,
the `cc_toolchain`, and the `toolchain()`. The generated repo BUILD (Unit D)
calls this macro; advanced users may also call it directly.

The macro performs NO path computation: every path string it forwards to
`cc_toolchain_config` (`tool_paths` values, sysroot paths,
`cxx_builtin_include_directories`) is an exec-relative `external/<repo_name>/...`
string the caller has already computed.

`wrappers` and `tool_paths` are two separate parameters keyed by the SAME tool
names (`gcc`, `cpp`, `ld`, `ar`, `nm`, `objcopy`, `objdump`, `strip`, `gcov`,
`dwp`):

- `wrappers` maps each tool name to a wrapper TARGET LABEL; the filegroups
  reference these labels so the wrapper scripts become sandbox inputs.
- `tool_paths` maps each tool name to the wrapper EXEC PATH STRING; the
  `cc_toolchain_config` rule needs concrete strings (it never resolves labels).

The repo rule (Unit D) knows both and supplies them in parallel.
"""

load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load("//aptprep/cc:cc_toolchain_config.bzl", "cc_toolchain_config")

def _dedup(items):
    """Order-preserving de-duplication of a label/string list.

    Bazel rejects duplicate labels in `srcs`/`target_compatible_with`. Several
    tools legitimately map to the SAME wrapper label (notably the bootstrap stub,
    where every tool points at one failing wrapper), and a native toolchain has
    `compiler_sysroot == target_sysroot` (so `:files` repeats). Dedup defensively
    so these valid configurations don't trip Bazel's duplicate-label check.
    """
    seen = {}
    out = []
    for item in items:
        if item not in seen:
            seen[item] = True
            out.append(item)
    return out

# buildifier: disable=unused-variable
def aptprep_cc_toolchain(
        name,
        target_triple,
        target_arch,
        target_cpu,
        compiler_sysroot_repo,
        target_sysroot_repo,
        compiler_sysroot_path,
        target_sysroot_path,
        clang_version,
        cxx_builtin_include_directories,
        target_os = "linux",
        cxx_std = "c++20",
        extra_compile_flags = [],
        extra_link_flags = [],
        exec_constraints = [],
        target_constraints = [],
        wrappers = {},
        tool_paths = {}):
    """Instantiate a complete aptprep CC toolchain.

    Args:
        name: Base name. The public toolchain target is `:toolchain`; the
            `cc_toolchain` is `name + "_cc_toolchain"`; the config rule is
            `name + "_config"`; filegroups are `name + "_<role>_files"`.
        target_triple: LLVM target triple, e.g. `aarch64-unknown-linux-gnu`.
            Used as `target_system_name` and in `--target=`/`--gcc-toolchain=`.
        target_arch: `@platforms//cpu` value, e.g. `aarch64`. Used to build the
            default `target_compatible_with`.
        target_cpu: Bazel CC cpu, e.g. `k8`/`aarch64` (computed upstream). Set
            as `target_cpu` on the config rule.
        compiler_sysroot_repo: Canonical repo name of the compiler sysroot;
            `@<repo>//:files` is referenced by the filegroups.
        target_sysroot_repo: Canonical repo name of the target sysroot;
            `@<repo>//:files` is referenced by the filegroups.
        compiler_sysroot_path: Exec-relative compiler-sysroot path
            (`external/<ct>`). Currently informational; reserved for callers.
        target_sysroot_path: Exec-relative target-sysroot path (`external/<tt>`).
            Used as `builtin_sysroot`, `sysroot_path`, and in
            `--gcc-toolchain=<target_sysroot_path>/usr`.
        clang_version: Clang version string (informational; reserved for
            callers that thread it into include-dir computation upstream).
        cxx_builtin_include_directories: Fully-formed list of exec-relative
            builtin include directories (caller already emits both path
            variants). Passed through unchanged.
        target_os: `@platforms//os` value (default `linux`). Used to build the
            default `target_compatible_with`.
        cxx_std: C++ standard for `-std=` (default `c++20`).
        extra_compile_flags: Appended to the fixed `compile_flags` list.
        extra_link_flags: Appended to the fixed `link_flags` list.
        exec_constraints: Full label list (incl. host os/cpu) for
            `exec_compatible_with` on the `toolchain()`.
        target_constraints: Extra label list appended to the computed
            `[@platforms//os:<target_os>, @platforms//cpu:<target_arch>]` for
            `target_compatible_with` on the `toolchain()`.
        wrappers: `{tool_name: ":wrapper_label"}` used by the filegroups.
        tool_paths: `{tool_name: "exec/path/string"}` used by the config rule.
            Keyed by the same tool names as `wrappers`.
    """

    # Fixed flag lists (spec §6.1). `--target=` and `--gcc-toolchain=` are
    # threaded into both compile and link so clang drives the correct triple and
    # the GNU tool/runtime layout inside the target sysroot.
    compile_flags = [
        "--target=" + target_triple,
        "-no-canonical-prefixes",
        "-U_FORTIFY_SOURCE",
        "-fstack-protector",
        "-fno-omit-frame-pointer",
        "-fcolor-diagnostics",
        "-Wall",
        "--gcc-toolchain=" + target_sysroot_path + "/usr",
    ] + extra_compile_flags

    cxx_flags = ["-std=" + cxx_std]

    link_flags = [
        "--target=" + target_triple,
        "-no-canonical-prefixes",
        "-fuse-ld=lld",
        "-Wl,--build-id=md5",
        "-Wl,--hash-style=gnu",
        "-Wl,-z,relro,-z,now",
        "-Wl,--gc-sections",
        "--gcc-toolchain=" + target_sysroot_path + "/usr",
        "-lm",
        "-lstdc++",
    ] + extra_link_flags

    opt_compile_flags = [
        "-O2",
        "-DNDEBUG",
        "-ffunction-sections",
        "-fdata-sections",
    ]
    dbg_compile_flags = ["-g"]

    cc_toolchain_config(
        name = name + "_config",
        toolchain_identifier = name,
        target_cpu = target_cpu,
        target_system_name = target_triple,
        compiler = "clang",
        builtin_sysroot = target_sysroot_path,
        sysroot_path = target_sysroot_path,
        cxx_builtin_include_directories = cxx_builtin_include_directories,
        tool_paths = tool_paths,
        compile_flags = compile_flags,
        cxx_flags = cxx_flags,
        link_flags = link_flags,
        opt_compile_flags = opt_compile_flags,
        dbg_compile_flags = dbg_compile_flags,
    )

    # `compiler_sysroot_repo`/`target_sysroot_repo` are CANONICAL repo names
    # (from `Label.repo_name`, which contains `+`/`++` separators). A canonical
    # name must be referenced with the `@@` prefix; a single `@` is parsed as an
    # apparent name and fails (`syntax error at '+'`).
    compiler_sysroot_files = "@@" + compiler_sysroot_repo + "//:files"
    target_sysroot_files = "@@" + target_sysroot_repo + "//:files"

    # §6.4 filegroup assignments determine sandbox inputs per action role.
    compile_wrappers = [wrappers[tool] for tool in ("gcc", "cpp") if tool in wrappers]

    # nm/objdump are sometimes consulted during link/strip-adjacent actions, so
    # fold their wrappers into the linker filegroup alongside gcc/ld/ar.
    link_wrappers = [
        wrappers[tool]
        for tool in ("gcc", "ld", "ar", "nm", "objdump")
        if tool in wrappers
    ]
    ar_wrapper = [wrappers["ar"]] if "ar" in wrappers else []
    strip_wrapper = [wrappers["strip"]] if "strip" in wrappers else []
    objcopy_wrapper = [wrappers["objcopy"]] if "objcopy" in wrappers else []
    dwp_wrapper = [wrappers["dwp"]] if "dwp" in wrappers else []

    native.filegroup(
        name = name + "_compiler_files",
        srcs = _dedup(compile_wrappers + [compiler_sysroot_files, target_sysroot_files]),
    )
    native.filegroup(
        name = name + "_linker_files",
        srcs = _dedup(link_wrappers + [compiler_sysroot_files, target_sysroot_files]),
    )
    native.filegroup(
        name = name + "_ar_files",
        srcs = _dedup(ar_wrapper + [compiler_sysroot_files]),
    )
    native.filegroup(
        name = name + "_strip_files",
        srcs = _dedup(strip_wrapper + [compiler_sysroot_files]),
    )
    native.filegroup(
        name = name + "_objcopy_files",
        srcs = _dedup(objcopy_wrapper + [compiler_sysroot_files]),
    )
    native.filegroup(
        name = name + "_dwp_files",
        srcs = _dedup(dwp_wrapper + [compiler_sysroot_files]),
    )

    # `all_files` must be the complete sandbox-input closure: EVERY tool wrapper
    # that has a `tool_paths` entry (and thus may be invoked by some action) must
    # be present, plus both sysroots. The per-action filegroups above only fold
    # in subsets (nm/objdump/gcov are not in any of them), so we union all
    # per-tool wrappers directly here rather than the per-action groups. The
    # invariant: no tool advertised via `tool_paths` is absent from `all_files`.
    all_wrappers = [
        wrappers[tool]
        for tool in (
            "gcc",
            "cpp",
            "ld",
            "ar",
            "nm",
            "objcopy",
            "objdump",
            "strip",
            "gcov",
            "dwp",
        )
        if tool in wrappers
    ]
    native.filegroup(
        name = name + "_all_files",
        srcs = _dedup(all_wrappers + [compiler_sysroot_files, target_sysroot_files]),
    )

    # `supports_header_parsing` is a first-class `cc_toolchain` attribute in
    # rules_cc 0.2.19 (stable since well before this version), so we set it here
    # rather than modelling it via a config feature.
    cc_toolchain(
        name = name + "_cc_toolchain",
        toolchain_config = name + "_config",
        all_files = name + "_all_files",
        compiler_files = name + "_compiler_files",
        linker_files = name + "_linker_files",
        ar_files = name + "_ar_files",
        strip_files = name + "_strip_files",
        objcopy_files = name + "_objcopy_files",
        dwp_files = name + "_dwp_files",
        supports_param_files = 1,
        supports_header_parsing = True,
        dynamic_runtime_lib = None,
        static_runtime_lib = None,
    )

    native.toolchain(
        name = "toolchain",
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        exec_compatible_with = _dedup(exec_constraints),
        target_compatible_with = _dedup([
            "@platforms//os:" + target_os,
            "@platforms//cpu:" + target_arch,
        ] + target_constraints),
        toolchain = ":" + name + "_cc_toolchain",
    )
