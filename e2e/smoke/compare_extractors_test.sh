#!/bin/sh
set -eu

result="$RUNFILES_DIR/+extraction_comparison+aptprep_extraction_comparison/result.txt"
if [ ! -f "$result" ]; then
    echo "Extractor comparison result is missing: $result" >&2
    exit 1
fi

grep -qx 'GNU tar and Bazel extraction trees match' "$result"
