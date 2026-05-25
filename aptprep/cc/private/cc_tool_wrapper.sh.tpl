#!/usr/bin/env bash
#
# cc_tool_wrapper.sh.tpl — per-tool wrapper for the aptprep CC toolchain.
#
# Rendered once per real tool by the Task 4 repo rule via
# repository_ctx.template(...). The repo rule fills in the following
# %{KEY} placeholders. This set of keys is a hard contract: do not add,
# remove, or rename keys without updating the renderer.
#
#   %{REAL_TOOL}          exec-relative path to the real tool in the compiler
#                         sysroot, e.g.
#                         external/<ct>/usr/lib/llvm-18/bin/clang
#   %{IS_COMPILE}         "1" for compile entry points (gcc, cpp), else "0".
#                         Controls date/time macro redaction.
#   %{COMPILER_SYSROOT}   exec-relative compiler-sysroot root, e.g.
#                         external/<ct>
#   %{LLVM_VERSION}       clang/llvm major version, e.g. 18
#   %{COMPILER_MULTIARCH} compiler-HOST Debian multiarch (the clang binary is
#                         host-arch), e.g. x86_64-linux-gnu. This is NOT the
#                         target triple — it names the loader/library dirs of
#                         the host on which clang itself executes.
#
# Responsibilities (spec §6.2):
#   1. Make the compiler's own host-arch shared libraries discoverable via
#      LD_LIBRARY_PATH.
#   2. On compile, redact __DATE__/__TIME__/__TIMESTAMP__ for reproducibility.
#   3. Normalize --sysroot: rewrite an exec-relative "external/..." value to
#      "/proc/self/cwd/external/..." so it matches the absolute form Bazel uses
#      for header cxx_builtin_include_directories and stays cache-correct across
#      sandboxed/unsandboxed actions (the toolchain is linux-only, so
#      /proc/self/cwd is the action cwd / execroot).
#   4. exec the real tool so it replaces this wrapper process (correct exit
#      status, no extra fork).

set -euo pipefail

# All exec-relative prefixes baked into the placeholders are resolved against
# the action cwd, which Bazel sets to the execroot for both sandboxed and
# unsandboxed actions. We therefore never assume an absolute base path.

# --- 1. Shared-library discovery --------------------------------------------
# Prepend the compiler-host loader paths, using the COMPILER-host multiarch
# (the clang binary is host-arch), never the target triple. Preserve any
# inherited LD_LIBRARY_PATH without emitting a leading ':' when it is empty.
COMPILER_LIB_PATHS="%{COMPILER_SYSROOT}/usr/lib/llvm-%{LLVM_VERSION}/lib:%{COMPILER_SYSROOT}/usr/lib/%{COMPILER_MULTIARCH}:%{COMPILER_SYSROOT}/lib/%{COMPILER_MULTIARCH}"
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
  export LD_LIBRARY_PATH="${COMPILER_LIB_PATHS}:${LD_LIBRARY_PATH}"
else
  export LD_LIBRARY_PATH="${COMPILER_LIB_PATHS}"
fi

# --- 2/3. Build the argument vector -----------------------------------------
# Accumulate into a bash array so arguments containing spaces survive intact;
# we never re-split via word-splitting.
ARGS=()

# Normalize a single --sysroot value. The toolchain config emits an
# exec-relative "external/..." path; rewrite it to the absolute
# "/proc/self/cwd/external/..." form so it matches the absolute variant Bazel
# already emits for header cxx_builtin_include_directories, keeping the
# compilation cache-correct across sandboxed and unsandboxed actions. Values
# that do not begin with "external/" (e.g. an explicit absolute path) are left
# untouched. Centralizes handling shared by the joined and split forms.
normalize_sysroot() {
  case "$1" in
    external/*) printf '/proc/self/cwd/%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

while [[ "$#" -gt 0 ]]; do
  arg="$1"
  case "${arg}" in
    --sysroot=*)
      # Joined form: --sysroot=external/...
      ARGS+=("--sysroot=$(normalize_sysroot "${arg#--sysroot=}")")
      ;;
    --sysroot)
      # Split form: --sysroot external/... — consume the following value if
      # present. Do not error if it is absent (defensive; --sysroot is
      # optional and may appear 0 or 1 times).
      ARGS+=("${arg}")
      if [[ "$#" -gt 1 ]]; then
        shift
        ARGS+=("$(normalize_sysroot "$1")")
      fi
      ;;
    *)
      ARGS+=("${arg}")
      ;;
  esac
  shift
done

# On compile entry points, redact date/time macros so emitted binaries are
# reproducible. The literal token "redacted" must land in the preprocessor
# define, hence the quoting.
if [[ "%{IS_COMPILE}" == "1" ]]; then
  ARGS+=(
    -Wno-builtin-macro-redefined
    -D__DATE__="redacted"
    -D__TIME__="redacted"
    -D__TIMESTAMP__="redacted"
  )
fi

# --- 4. Hand off to the real tool -------------------------------------------
exec "%{REAL_TOOL}" "${ARGS[@]}"
