#!/usr/bin/env bash
#
# Asserts the cc-toolchain bootstrap-degradation behavior: when a referenced
# sysroot is an ungenerated aptprep stand-in (the APTPREP_FAKE_SYSROOT sentinel
# is present), `cc_toolchain_repo` emits a STUB toolchain that resolves
# identically but whose tools fail with an actionable message.
#
# Inputs (from the cc_bootstrap_fixture extension):
#   $1  generated stub BUILD.bazel contents
#   $2  generated stub wrapper script (wrappers/ungenerated.sh)
set -euo pipefail

stub_build="$1"
stub_wrapper="$2"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" needle="$2"
  grep -qF -- "$needle" "$file" || fail "expected '$needle' in $(basename "$file")"
}

# --- Stub BUILD: same toolchain target name + constraints as the real path ---
assert_contains "$stub_build" 'aptprep_cc_toolchain('
assert_contains "$stub_build" 'name = "toolchain"'
assert_contains "$stub_build" '@platforms//cpu:aarch64'
assert_contains "$stub_build" '@platforms//os:linux'
assert_contains "$stub_build" '@platforms//cpu:x86_64'

# Every tool must be wired to the single failing wrapper (no real llvm bins).
assert_contains "$stub_build" 'wrappers/ungenerated.sh'
assert_contains "$stub_build" ':ungenerated_wrapper'
# A fake sysroot exposes no real builtin include directories.
assert_contains "$stub_build" 'cxx_builtin_include_directories = []'

# The stub must NOT reference any real per-tool wrapper (those only exist on the
# generated-sysroot path).
if grep -qF 'wrappers/gcc.sh' "$stub_build"; then
  fail "stub BUILD unexpectedly references a real per-tool wrapper (wrappers/gcc.sh)"
fi

# --- Stub wrapper: fails with an actionable message --------------------------
assert_contains "$stub_wrapper" 'not generated'
assert_contains "$stub_wrapper" 'aarch64'
assert_contains "$stub_wrapper" 'exit 1'

# Executing the wrapper must fail (non-zero) and print the guidance to stderr.
set +e
out="$("$stub_wrapper" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "stub wrapper exited 0; expected non-zero"
case "$out" in
  *"not generated"*) : ;;
  *) fail "stub wrapper output missing 'not generated': $out" ;;
esac

echo "PASS: cc bootstrap stub toolchain behaves as expected"
