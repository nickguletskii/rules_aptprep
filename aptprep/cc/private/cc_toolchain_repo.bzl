"""`cc_toolchain_repo` repository rule (Unit D).

Generates ONE lightweight repo per `aptprep.cc_toolchain(...)` toolchain. The
repo contains only:

  * per-tool bash wrappers rendered from `cc_tool_wrapper.sh.tpl`, and
  * a tiny `BUILD.bazel` (from `cc_toolchain.BUILD.tpl`) that loads the public
    `aptprep_cc_toolchain(...)` macro and calls it with fully-resolved values.

The heavy artifacts (clang/lld/llvm tools, headers, libs) live in the separate
sysroot repos produced by `aptprep.sysroot(...)`; this repo only references them
through exec-relative `external/<repo_name>/...` path strings.

## tool_paths resolution strategy (DECISION)

`cc_toolchain_config` consumes `tool_paths` values as CONCRETE exec-relative
strings and performs NO label/location expansion. The wrapper scripts live in
THIS generated repo, so their exec path is
`external/<this_repo_canonical_name>/wrappers/<tool>.sh`. We obtain this repo's
own canonical name from `repository_ctx.name` and build each `tool_paths` value
as:

    tool_paths[tool] = "external/" + repository_ctx.name + "/wrappers/" + tool + ".sh"

We therefore produce, for every tool, BOTH:

  * a wrapper LABEL (`":<tool>_wrapper"`, a per-tool filegroup declared in the
    generated BUILD) for the macro's `wrappers` arg (drives sandbox inputs), and
  * the exec-path STRING above for the macro's `tool_paths` arg (consumed by the
    config rule).

`wrappers` and `tool_paths` are keyed by the SAME tool names. We deliberately do
NOT use package-relative `wrappers/<tool>.sh`: the config rule wants the
exec-relative `external/...` form so the path resolves against the execroot from
any action cwd.
"""

load(
    "//aptprep/private:sysroot_repo.bzl",
    "gnu_cpu_arch_by_debian_arch",
    "multiarch_dir_by_debian_arch",
)

# Tool name -> real binary (basename) in the compiler sysroot's llvm bin dir.
# `gcc`/`cpp` are the compile entry points (IS_COMPILE=1). The mapping is the
# §6.2 contract and must stay keyed identically to `wrappers`/`tool_paths`.
_TOOL_REAL_BINARY = {
    "gcc": "clang",
    "cpp": "clang",
    "ld": "ld.lld",
    "ar": "llvm-ar",
    "nm": "llvm-nm",
    "objcopy": "llvm-objcopy",
    "objdump": "llvm-objdump",
    "strip": "llvm-strip",
    "gcov": "llvm-cov",
    "dwp": "llvm-dwp",
}

# Real binaries that MUST exist for a functional compile+link+ar+strip flow.
# These back the essential tool entries (gcc/cpp->clang, ld, ar, nm, objcopy,
# strip). Their absence is a hard fetch-time error.
_ESSENTIAL_REAL_BINARIES = (
    "clang",
    "ld.lld",
    "llvm-ar",
    "llvm-nm",
    "llvm-objcopy",
    "llvm-strip",
)

# Real binaries that are OPTIONAL on common Debian/Ubuntu clang/llvm layouts
# (frequently shipped in separate packages or absent). We still generate
# wrappers + `tool_paths` entries for the tools they back (objdump/gcov/dwp) so
# the toolchain advertises them and they become sandbox inputs when present,
# but we do NOT hard-fail at fetch time if the real binary is missing.
_OPTIONAL_REAL_BINARIES = (
    "llvm-objdump",
    "llvm-cov",
    "llvm-dwp",
)

_COMPILE_TOOLS = ("gcc", "cpp")

# @platforms//cpu value -> Bazel CC `target_cpu`. Unknown arch fails loudly.
_TARGET_CPU_BY_ARCH = {
    "x86_64": "k8",
    "aarch64": "aarch64",
}

def _repo_prefix(label):
    """Exec-relative prefix `external/<repo_name>` for a sysroot label.

    Uses `Label.repo_name` (NOT the deprecated `workspace_name`); never
    string-mangles `++`/`+`.
    """
    return "external/" + label.repo_name

def _escape_str(s):
    """Escape a value for embedding inside a double-quoted Starlark string.

    Caller-supplied values (e.g. `extra_compile_flags`/`extra_link_flags`) flow
    verbatim into the generated BUILD; a `"` or `\\` would otherwise produce a
    broken/ambiguous literal. Escape backslash first, then double-quote.
    """
    return s.replace("\\", "\\\\").replace("\"", "\\\"")

def _starlark_str_list(values):
    """Render a Starlark string-list literal for the generated BUILD."""
    return "[" + ", ".join(['"' + _escape_str(v) + '"' for v in values]) + "]"

def _starlark_str_dict(d, keys):
    """Render a Starlark `{str: str}` literal with deterministic key order."""
    items = ['"' + _escape_str(k) + '": "' + _escape_str(d[k]) + '"' for k in keys]
    return "{" + ", ".join(items) + "}"

def _starlark_label_dict(d, keys):
    """Render a `{str: label}` literal; labels are emitted as plain strings."""
    items = ['"' + _escape_str(k) + '": "' + _escape_str(d[k]) + '"' for k in keys]
    return "{" + ", ".join(items) + "}"

def _both_path_variants(path):
    """Emit a builtin-include entry twice: plain and `/proc/self/cwd/` form."""
    return [path, "/proc/self/cwd/" + path]

def _discover_libstdcxx_version(target_sysroot_root):
    """Auto-discover the single numeric `usr/include/c++/<ver>` entry (§6.5)."""
    cxx_dir = target_sysroot_root.get_child("usr").get_child("include").get_child("c++")
    if not cxx_dir.exists:
        fail((
            "Cannot auto-discover the libstdc++ version: '{}' does not exist " +
            "in the target sysroot. Add a `libstdc++-<N>-dev` (and matching " +
            "`g++-<N>`/`libgcc-<N>-dev`) package, or set `libstdcxx_version` " +
            "explicitly on the `cc_toolchain` tag."
        ).format(cxx_dir))

    numeric_entries = [e.basename for e in cxx_dir.readdir() if e.basename.isdigit()]
    if len(numeric_entries) == 1:
        return numeric_entries[0]

    fail((
        "Cannot auto-discover a unique libstdc++ version under '{}': found {}. " +
        "Set `libstdcxx_version` explicitly on the `cc_toolchain` tag to " +
        "disambiguate."
    ).format(cxx_dir, sorted(numeric_entries)))

def _require_path(root, rel, what):
    """Fail with an actionable message if `root/rel` is absent at fetch time."""
    p = root
    for component in rel.split("/"):
        p = p.get_child(component)
    if not p.exists:
        fail((
            "aptprep cc_toolchain validation failed: {} not found at '{}'. " +
            "Check the package set in the relevant sysroot."
        ).format(what, p))

def _cc_toolchain_repo_impl(repository_ctx):
    attr = repository_ctx.attr

    # --- 1. Resolve sysroot exec prefixes from Label.repo_name ---------------
    compiler_path = _repo_prefix(attr.compiler_sysroot)
    target_path = _repo_prefix(attr.target_sysroot)

    # --- 2. Derive multiarch dirs + target_cpu (fail loudly on unknowns) -----
    tmultiarch = multiarch_dir_by_debian_arch(attr.target_debian_arch)
    cmultiarch = multiarch_dir_by_debian_arch(attr.compiler_arch)

    # Also validates compiler_arch is a known Debian arch (drives exec cpu in
    # the extension); resolve it here so misconfiguration fails at fetch time.
    gnu_cpu_arch_by_debian_arch(attr.compiler_arch)

    target_cpu = _TARGET_CPU_BY_ARCH.get(attr.target_arch)
    if not target_cpu:
        fail("Unknown target_arch '{}'; known @platforms//cpu values: {}".format(
            attr.target_arch,
            sorted(_TARGET_CPU_BY_ARCH.keys()),
        ))

    clang_version = attr.clang_version

    # --- 3. libstdc++ discovery, anchored on install_manifest.json -----------
    # `repository_ctx.path(Label(...))` must resolve a real exported file; the
    # sysroot repo exports `install_manifest.json` whose parent dir is the
    # sysroot root.
    target_manifest = repository_ctx.path(
        attr.target_sysroot.relative(":install_manifest.json"),
    )
    target_sysroot_root = target_manifest.dirname

    compiler_manifest = repository_ctx.path(
        attr.compiler_sysroot.relative(":install_manifest.json"),
    )
    compiler_sysroot_root = compiler_manifest.dirname

    gccver = attr.libstdcxx_version
    if not gccver:
        gccver = _discover_libstdcxx_version(target_sysroot_root)

    # --- 4. Fetch-time validation (§7) ---------------------------------------
    # Compiler sysroot: clang resource dir + every required real tool. clang
    # debs lay the tools out under `usr/lib/llvm-<NN>/bin/<tool>` (with
    # `usr/bin/clang-NN` symlinks); we anchor on the canonical llvm bin dir.
    llvm_lib = "usr/lib/llvm-" + clang_version
    llvm_bin = llvm_lib + "/bin"
    resource_dir = llvm_lib + "/lib/clang/" + clang_version + "/include"

    _require_path(
        compiler_sysroot_root,
        resource_dir,
        "clang resource dir for clang_version '{}'".format(clang_version),
    )

    # Validate ONLY the ESSENTIAL real binaries (compile/link/ar/nm/objcopy/
    # strip). The OPTIONAL tools (objdump/gcov/dwp) are not required for a
    # functional cc_binary/cc_library flow and are frequently absent on
    # standard Debian/Ubuntu clang layouts, so we never hard-fail on them — we
    # still wrap them below so they're advertised + sandboxed when present.
    #
    # Guard against drift: the essential/optional split must exactly partition
    # the real binaries referenced by `_TOOL_REAL_BINARY`.
    classified = list(_ESSENTIAL_REAL_BINARIES) + list(_OPTIONAL_REAL_BINARIES)
    for real in _TOOL_REAL_BINARY.values():
        if real not in classified:
            fail((
                "aptprep cc_toolchain internal error: real binary '{}' is not " +
                "classified as essential or optional; update the split in " +
                "cc_toolchain_repo.bzl."
            ).format(real))

    for real in sorted(_ESSENTIAL_REAL_BINARIES):
        _require_path(
            compiler_sysroot_root,
            llvm_bin + "/" + real,
            "essential compiler tool '{}'".format(real),
        )

    # Target sysroot: libstdc++ headers, multiarch includes, GCC install layout.
    _require_path(
        target_sysroot_root,
        "usr/include/c++/" + gccver,
        "libstdc++ headers for version '{}'".format(gccver),
    )
    _require_path(
        target_sysroot_root,
        "usr/include/" + tmultiarch,
        "target multiarch include dir",
    )
    _require_path(
        target_sysroot_root,
        "usr/lib/gcc/" + tmultiarch + "/" + gccver,
        "GCC install layout (crtbegin/crtend, libgcc) — needs g++-N/" +
        "libstdc++-N-dev/libgcc-N-dev in the target sysroot",
    )

    # --- 5. cxx_builtin_include_directories (§6.1), each emitted twice --------
    raw_includes = [
        compiler_path + "/" + resource_dir,
        target_path + "/usr/include/c++/" + gccver,
        target_path + "/usr/include/" + tmultiarch + "/c++/" + gccver,
        target_path + "/usr/include/" + tmultiarch,
        target_path + "/usr/include",
    ]
    cxx_builtin_include_directories = []
    for entry in raw_includes:
        cxx_builtin_include_directories.extend(_both_path_variants(entry))

    # --- 6. Render wrappers + build wrappers/tool_paths maps ------------------
    # self_repo is this generated repo's own canonical name; its files are
    # addressed as external/<self_repo>/wrappers/<tool>.sh (see module docstring).
    self_repo = repository_ctx.name
    wrappers = {}
    tool_paths = {}
    for tool, real in _TOOL_REAL_BINARY.items():
        repository_ctx.template(
            "wrappers/" + tool + ".sh",
            attr.wrapper_template,
            substitutions = {
                "%{REAL_TOOL}": compiler_path + "/" + llvm_bin + "/" + real,
                "%{IS_COMPILE}": "1" if tool in _COMPILE_TOOLS else "0",
                "%{COMPILER_SYSROOT}": compiler_path,
                "%{LLVM_VERSION}": clang_version,
                "%{COMPILER_MULTIARCH}": cmultiarch,
            },
            executable = True,
        )
        wrappers[tool] = ":" + tool + "_wrapper"
        tool_paths[tool] = "external/" + self_repo + "/wrappers/" + tool + ".sh"

    tool_keys = sorted(_TOOL_REAL_BINARY.keys())

    # Per-tool filegroups in the generated BUILD so each wrapper becomes a
    # sandbox input via the §6.4 filegroups the macro builds.
    wrapper_filegroups = "\n".join([
        'filegroup(\n    name = "{tool}_wrapper",\n    srcs = ["wrappers/{tool}.sh"],\n)'.format(tool = tool)
        for tool in tool_keys
    ])

    # --- 7. Render the generated BUILD ---------------------------------------
    repository_ctx.template(
        "BUILD.bazel",
        attr.build_tpl,
        substitutions = {
            "%{WRAPPER_FILEGROUPS}": wrapper_filegroups,
            "%{NAME}": attr.toolchain_name,
            "%{TARGET_TRIPLE}": attr.target_triple,
            "%{TARGET_ARCH}": attr.target_arch,
            "%{TARGET_CPU}": target_cpu,
            "%{TARGET_OS}": attr.target_os,
            "%{COMPILER_SYSROOT_REPO}": attr.compiler_sysroot.repo_name,
            "%{TARGET_SYSROOT_REPO}": attr.target_sysroot.repo_name,
            "%{COMPILER_SYSROOT_PATH}": compiler_path,
            "%{TARGET_SYSROOT_PATH}": target_path,
            "%{CLANG_VERSION}": clang_version,
            "%{CXX_STD}": attr.cxx_std,
            "%{CXX_BUILTIN_INCLUDE_DIRECTORIES}": _starlark_str_list(cxx_builtin_include_directories),
            "%{EXTRA_COMPILE_FLAGS}": _starlark_str_list(attr.extra_compile_flags),
            "%{EXTRA_LINK_FLAGS}": _starlark_str_list(attr.extra_link_flags),
            "%{EXEC_CONSTRAINTS}": _starlark_str_list(attr.exec_constraints),
            "%{TARGET_CONSTRAINTS}": _starlark_str_list(attr.target_constraints),
            "%{WRAPPERS}": _starlark_label_dict(wrappers, tool_keys),
            "%{TOOL_PATHS}": _starlark_str_dict(tool_paths, tool_keys),
        },
    )

cc_toolchain_repo = repository_rule(
    implementation = _cc_toolchain_repo_impl,
    attrs = {
        "target_triple": attr.string(
            mandatory = True,
            doc = "LLVM target triple, e.g. `aarch64-unknown-linux-gnu` (clang --target only).",
        ),
        "target_arch": attr.string(
            mandatory = True,
            doc = "`@platforms//cpu` value, e.g. `aarch64`.",
        ),
        "target_os": attr.string(
            default = "linux",
            doc = "`@platforms//os` value (default `linux`).",
        ),
        "compiler_sysroot": attr.label(
            mandatory = True,
            doc = "Compiler sysroot repo (supplies clang/lld/llvm + host-arch libs).",
        ),
        "compiler_arch": attr.string(
            default = "amd64",
            doc = "Debian arch of the compiler sysroot (drives compiler-host multiarch).",
        ),
        "target_sysroot": attr.label(
            mandatory = True,
            doc = "Target sysroot repo (supplies target headers/libs + GCC install layout).",
        ),
        "target_debian_arch": attr.string(
            mandatory = True,
            doc = "Debian arch of the target sysroot, e.g. `arm64` (drives target multiarch).",
        ),
        "clang_version": attr.string(
            mandatory = True,
            doc = "Distro clang major version, e.g. `18` (resource-dir path component).",
        ),
        "libstdcxx_version": attr.string(
            default = "",
            doc = "Optional libstdc++ version override; auto-discovered from the target sysroot if empty.",
        ),
        "cxx_std": attr.string(default = "c++20", doc = "C++ standard for `-std=`."),
        "extra_compile_flags": attr.string_list(default = []),
        "extra_link_flags": attr.string_list(default = []),
        "exec_constraints": attr.string_list(default = []),
        "target_constraints": attr.string_list(default = []),
        "toolchain_name": attr.string(
            default = "toolchain",
            doc = "Base `name` forwarded to `aptprep_cc_toolchain(...)` in the generated BUILD.",
        ),
        "wrapper_template": attr.label(
            default = "//aptprep/cc/private:cc_tool_wrapper.sh.tpl",
            allow_single_file = True,
        ),
        "build_tpl": attr.label(
            default = "//aptprep/cc/private:cc_toolchain.BUILD.tpl",
            allow_single_file = True,
        ),
    },
)
