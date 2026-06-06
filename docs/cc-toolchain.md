# C/C++ toolchain from aptprep sysroots

`rules_aptprep` can turn aptprep sysroot repositories into a fully wired
`rules_cc` C/C++ toolchain. Consuming projects carry no `cc_toolchain_config` or
tool-wrapper boilerplate: one `aptprep.cc_toolchain(...)` per target toolchain
plus one `register_toolchains` is the entire integration surface.
Cross-compilation (e.g. building `linux/aarch64` from a `linux/x86_64` host) is
supported by reusing a single multi-target clang from the *compiler sysroot*
against a target-arch *target sysroot*.

The complete, runnable wiring this page describes lives in
[`e2e/cc/`](../e2e/cc/).

## Model: two sysroots, one clang

A cc toolchain is assembled from two aptprep sysroots:

- **compiler sysroot** — runs on the BUILD host. Supplies the single
  multi-target `clang`/`clang++`/`ld.lld`/`llvm-*` binaries and their host-arch
  shared libraries.
- **target sysroot** — supplies the TARGET arch headers, libraries, and a real
  GCC install layout (`usr/lib/gcc/<multiarch>/<gccver>`) used by clang's
  `--gcc-toolchain`.

Each cross-compile is then: host clang + `--target=<triple>` +
`--sysroot=<target>` + `--gcc-toolchain=<target>/usr`. For a **native** build the
two sysroots are identical (`compiler_sysroot == target_sysroot`).

Three identifiers are kept distinct and must not be conflated:

| Concept | Example | Used for |
|---|---|---|
| `target_triple` (LLVM) | `aarch64-unknown-linux-gnu` | clang `--target=` only |
| target Debian multiarch | `aarch64-linux-gnu` | `usr/include/<m>`, `usr/lib/<m>`, `usr/lib/gcc/<m>/<gccver>` |
| compiler-host multiarch | `x86_64-linux-gnu` | wrapper `LD_LIBRARY_PATH` loader paths |

The Debian multiarch strings are derived from a Debian arch (`amd64`/`arm64`/…):
the target multiarch from `target_arch`, the compiler-host multiarch from
`compiler_arch`.

## Sysroot package expectations

Each sysroot is produced by `aptprep.sysroot(...)`. For a working
`--gcc-toolchain`, the packages installed into each sysroot must provide:

- **clang/lld/llvm tools** (in the COMPILER sysroot): `clang-<NN>`, `lld-<NN>`,
  `llvm-<NN>`. These ship `clang`/`clang++`/`ld.lld`/`llvm-*` plus the clang
  resource dir at `usr/lib/llvm-<NN>/lib/clang/<NN>/include`.
- **C library + kernel headers** (in each TARGET sysroot): `libc6-dev`,
  `linux-libc-dev`.
- **GCC install layout** (in each TARGET sysroot): `gcc-<gccver>`,
  `g++-<gccver>`, `libstdc++-<gccver>-dev`, `libgcc-<gccver>-dev`. These provide
  `usr/lib/gcc/<multiarch>/<gccver>` (crtbegin/crtend, libgcc) and the libstdc++
  headers under `usr/include/c++/<gccver>` and
  `usr/include/<multiarch>/c++/<gccver>`. `--gcc-toolchain` requires a *real* GCC
  installation, not merely clang + libc.
- **binutils** for completeness of the GNU layout.

The repo rule validates all of these paths at FETCH time and fails with an
actionable message before any C++ action runs (missing clang resource dir,
ambiguous/missing `usr/include/c++/`, missing `usr/include/<tmultiarch>`, missing
`usr/lib/gcc/<tmultiarch>/<gccver>`, or a missing real tool).

## The `aptprep.cc_toolchain(...)` extension tag

```python
aptprep = use_extension("@rules_aptprep//aptprep:extensions.bzl", "aptprep")

aptprep.cc_toolchain(
    name              = "cc_aarch64",                 # generated repo name
    target_triple     = "aarch64-unknown-linux-gnu",  # clang --target value ONLY
    target_arch       = "aarch64",                     # @platforms//cpu constraint; also -> Debian multiarch
    target_os         = "linux",                       # default "linux"
    compiler_sysroot  = "@cc_sysroot_amd64",           # clang/lld; runs on the BUILD host
    compiler_arch     = "amd64",                        # Debian arch of the compiler sysroot; default "amd64"
    target_sysroot    = "@cc_sysroot_arm64",           # headers + libs for the TARGET arch
    clang_version     = "18",                          # distro clang major (resource-dir path)
    libstdcxx_version = "13",                          # optional override; auto-discovered if empty
    cxx_std           = "c++20",                        # default "c++20"
    extra_compile_flags = [],                           # appended to the fixed compile flags
    extra_link_flags    = [],                           # appended to the fixed link flags
    exec_constraints    = [],                           # extra exec constraints (host os/cpu added automatically)
    target_constraints  = [],                           # extra target constraints (target os/cpu added automatically)
)
```

Attributes:

| Attribute | Required | Default | Meaning |
|---|---|---|---|
| `name` | yes | — | Name of the generated repo; its toolchain target is `@<name>//:toolchain`. |
| `target_triple` | yes | — | LLVM triple passed to `clang --target=` and used as `target_system_name`. |
| `target_arch` | yes | — | `@platforms//cpu` value (e.g. `aarch64`, `x86_64`); also drives the target Debian multiarch. |
| `target_os` | no | `linux` | `@platforms//os` value for `target_compatible_with`. |
| `compiler_sysroot` | yes | — | Label of the sysroot that ships clang/lld; runs on the build host. |
| `compiler_arch` | no | `amd64` | Debian arch of the compiler sysroot; drives the exec platform cpu and the loader-path multiarch. |
| `target_sysroot` | yes | — | Label of the sysroot with target headers/libs/GCC layout. |
| `clang_version` | yes | — | Distro clang major (the `<NN>` in `usr/lib/llvm-<NN>`). |
| `libstdcxx_version` | no | `""` | libstdc++/GCC version. Auto-discovered from `usr/include/c++/` if empty; set it if discovery is ambiguous. |
| `cxx_std` | no | `c++20` | Value for `-std=`. |
| `extra_compile_flags` | no | `[]` | Appended to the fixed compile flags. |
| `extra_link_flags` | no | `[]` | Appended to the fixed link flags. |
| `exec_constraints` | no | `[]` | Extra exec constraints; `[@platforms//os:linux, @platforms//cpu:<gnu_cpu(compiler_arch)>]` is added automatically. |
| `target_constraints` | no | `[]` | Extra target constraints; `[@platforms//os:<target_os>, @platforms//cpu:<target_arch>]` is added automatically. |

The exec platform comes from `compiler_arch`, **not** the fetch machine, so the
toolchain stays correct under remote execution.

Each `aptprep.cc_toolchain(name = "X", ...)` produces one lightweight repo `@X`
containing only the per-tool bash wrappers and a tiny `BUILD.bazel` that calls
the `aptprep_cc_toolchain(...)` macro. The heavy artifacts (tools, headers,
libs) stay in the separate sysroot repos.

After declaring the toolchains, register them (order matters — list the cc
toolchains so toolchain resolution can select them per target platform):

```python
register_toolchains(
    "@aptprep_toolchains//:all",
    "@cc_x86_64//:toolchain",
    "@cc_aarch64//:toolchain",
)
```

## The `aptprep_cc_toolchain(...)` BUILD macro (advanced)

`aptprep/cc/defs.bzl` exposes the same configuration as a public BUILD macro for
advanced users who want to instantiate a toolchain in their own package with
custom constraints. The extension tag is the common path; the generated repo's
`BUILD.bazel` simply calls this macro with fully-resolved, exec-relative path
strings:

```python
load("@rules_aptprep//aptprep/cc:defs.bzl", "aptprep_cc_toolchain")
```

It instantiates `cc_toolchain_config` + the role filegroups + `cc_toolchain` +
`toolchain()`, exposing a `:toolchain` target. The macro performs no path
computation; every path it forwards is an exec-relative `external/<repo_name>/…`
string the caller has already computed (the repo rule does this for you). Prefer
the extension tag unless you need bespoke constraints.

## Native vs cross

- **Native** (`linux/x86_64` host building `linux/x86_64`): pass the *same*
  sysroot as both `compiler_sysroot` and `target_sysroot`, with
  `target_arch = "x86_64"`, `target_triple = "x86_64-unknown-linux-gnu"`.
- **Cross** (`linux/x86_64` host building `linux/aarch64`):
  `compiler_sysroot` = the amd64 sysroot (host clang), `compiler_arch = "amd64"`,
  `target_sysroot` = the arm64 sysroot, `target_arch = "aarch64"`,
  `target_triple = "aarch64-unknown-linux-gnu"`.

Toolchain resolution selects the right toolchain from the configured target
platform's `@platforms//cpu` (+ `os`) constraints, so building a target under
`--platforms=//:linux_aarch64` (or via a platform transition) picks the aarch64
toolchain with no extra flags.

## Copy-paste example (matches `e2e/cc`)

```python
# MODULE.bazel
aptprep = use_extension("@rules_aptprep//aptprep:extensions.bzl", "aptprep")
aptprep.toolchain(
    archive_url = "https://github.com/nickguletskii/aptprep/releases/download/v0.1.2/aptprep_linux_x86_64.tar",
    sha256 = "4d1b992540fb9856561f101d8ef4a54b7e74529a65171468f7940933ad0a0e52",
)
aptprep.lockfile(
    config = "//:aptprep.yaml",
    lockfile = "//:lockfile.json",
    lockfile_name = "cc",
)

_CC_PACKAGES = [
    "clang-18", "lld-18", "llvm-18", "binutils",
    "libc6-dev", "linux-libc-dev",
    "libstdc++-13-dev", "libgcc-13-dev", "gcc-13", "g++-13",
]

aptprep.sysroot(
    architecture = "amd64",
    lockfile_name = "cc",
    packages_list = _CC_PACKAGES,
    repo_name = "cc_sysroot_amd64",
)
aptprep.sysroot(
    architecture = "arm64",
    lockfile_name = "cc",
    packages_list = _CC_PACKAGES,
    repo_name = "cc_sysroot_arm64",
)

# Native amd64: compiler sysroot == target sysroot.
aptprep.cc_toolchain(
    name = "cc_x86_64",
    clang_version = "18",
    compiler_arch = "amd64",
    compiler_sysroot = "@cc_sysroot_amd64",
    libstdcxx_version = "13",
    target_arch = "x86_64",
    target_sysroot = "@cc_sysroot_amd64",
    target_triple = "x86_64-unknown-linux-gnu",
)

# Cross aarch64: host clang (amd64) targeting the arm64 sysroot.
aptprep.cc_toolchain(
    name = "cc_aarch64",
    clang_version = "18",
    compiler_arch = "amd64",
    compiler_sysroot = "@cc_sysroot_amd64",
    libstdcxx_version = "13",
    target_arch = "aarch64",
    target_sysroot = "@cc_sysroot_arm64",
    target_triple = "aarch64-unknown-linux-gnu",
)

use_repo(
    aptprep,
    "aptprep_binary_archive",
    "aptprep_toolchains",
    "cc_aarch64",
    "cc_sysroot_amd64",
    "cc_sysroot_arm64",
    "cc_x86_64",
)

register_toolchains(
    "@aptprep_toolchains//:all",
    "@cc_x86_64//:toolchain",
    "@cc_aarch64//:toolchain",
)
```

```python
# BUILD
load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")

cc_library(name = "hello_lib", srcs = ["hello_lib.cc"], hdrs = ["hello_lib.h"])
cc_binary(name = "hello", srcs = ["hello.cc"], deps = [":hello_lib"])
```

`bazel build //:hello` builds natively for the host. To cross-compile for
aarch64, build under the aarch64 platform — either with
`bazel build --platforms=//:linux_aarch64 //:hello` or via a Starlark platform
transition rule (see `e2e/cc/transition.bzl`). aarch64 verification in `e2e/cc`
is static (`readelf -h` reports `AArch64`); no execution/qemu is required.
