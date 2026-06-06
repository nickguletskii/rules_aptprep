#!/bin/bash
# Verify that the aarch64-transitioned binary is a real AArch64 ELF.
#
# $1 is the $(rootpath ...) of the transitioned binary, i.e. a runfiles-relative
# path. We resolve it against the runfiles tree, tolerating the canonical
# (mangled) external-repo naming and the various roots Bazel may use.
set -euo pipefail

REL="${1:?usage: verify_aarch64.sh <rootpath-to-binary>}"

resolve() {
  # Try the candidate roots in order; print the first that exists.
  local roots=(
    "${RUNFILES_DIR:-}"
    "${TEST_SRCDIR:-}"
    "${RUNFILES_DIR:-}/_main"
    "${TEST_SRCDIR:-}/_main"
    "."
  )
  local root
  for root in "${roots[@]}"; do
    if [ -n "$root" ] && [ -e "$root/$REL" ]; then
      printf '%s\n' "$root/$REL"
      return 0
    fi
  done
  # Last resort: maybe the arg is already a usable path.
  if [ -e "$REL" ]; then
    printf '%s\n' "$REL"
    return 0
  fi
  return 1
}

BIN="$(resolve)" || {
  echo "ERROR: could not locate the binary for rootpath '$REL'"
  echo "  RUNFILES_DIR=${RUNFILES_DIR:-}"
  echo "  TEST_SRCDIR=${TEST_SRCDIR:-}"
  echo "  PWD=$PWD"
  exit 1
}

echo "Inspecting: $BIN"

if command -v readelf >/dev/null 2>&1; then
  MACHINE_LINE="$(readelf -h "$BIN" | grep -i 'Machine:' || true)"
  echo "$MACHINE_LINE"
  if echo "$MACHINE_LINE" | grep -qi 'AArch64'; then
    echo "PASS: ELF machine is AArch64"
    exit 0
  fi
  echo "FAIL: ELF machine is not AArch64"
  exit 1
fi

# Fallback to file(1) if readelf is unavailable.
if command -v file >/dev/null 2>&1; then
  FILE_OUT="$(file "$BIN")"
  echo "$FILE_OUT"
  if echo "$FILE_OUT" | grep -qi 'aarch64'; then
    echo "PASS: file reports ARM aarch64"
    exit 0
  fi
  echo "FAIL: file does not report aarch64"
  exit 1
fi

echo "ERROR: neither readelf nor file is available"
exit 1
