#!/bin/bash
# Verify the __DATE__/__TIME__/__TIMESTAMP__ redaction landed in the binary.
#
# The tool wrapper injects -D__DATE__="redacted" -D__TIME__="redacted"
# -D__TIMESTAMP__="redacted" for compile actions, so date_stamp (which
# references all three macros) must contain the literal "redacted" and must NOT
# contain a real build timestamp.
#
# Primary (positive) signal: the literal "redacted" appears in the binary.
# Negative check: no __TIMESTAMP__-style string of the form
#   "<Weekday> <Month> <day> HH:MM:SS YYYY"
# remains. We anchor the negative check on the "HH:MM:SS YYYY" tail produced by
# __TIMESTAMP__ rather than any HH:MM:SS run (too broad — unrelated bytes in the
# binary can match a bare time pattern).
set -euo pipefail

REL="${1:?usage: verify_reproducibility.sh <rootpath-to-binary>}"

resolve() {
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

if ! grep -qa 'redacted' "$BIN"; then
  echo "FAIL: literal 'redacted' not found in the binary; redaction did not run"
  exit 1
fi
echo "PASS: redaction literal 'redacted' present"

# __TIMESTAMP__ expands to e.g. "Mon Jun  2 17:04:05 2026". Assert no such tail
# (a "HH:MM:SS YYYY" run, where YYYY is a plausible build year) survives.
if grep -qaE '[0-2][0-9]:[0-5][0-9]:[0-5][0-9] (19|20)[0-9][0-9]' "$BIN"; then
  echo "FAIL: a real '__TIMESTAMP__'-style 'HH:MM:SS YYYY' value remains"
  exit 1
fi
echo "PASS: no real __TIMESTAMP__-style value remains"
exit 0
