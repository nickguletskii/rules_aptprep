#!/bin/sh
set -eu

results_file=$1
absolute_rejected=missing
parent_rejected=missing
option_safe=missing
symlink_rejected=missing
extracted_files=missing

while IFS='=' read -r key value; do
    case "$key" in
        absolute_rejected) absolute_rejected=$value ;;
        parent_rejected) parent_rejected=$value ;;
        option_safe) option_safe=$value ;;
        symlink_rejected) symlink_rejected=$value ;;
        extracted_files) extracted_files=$value ;;
    esac
done < "$results_file"

failures=0

assert_true() {
    actual=$1
    message=$2
    if [ "$actual" != "true" ]; then
        echo "Assertion failed: $message (got $actual)" >&2
        failures=$((failures + 1))
    fi
}

assert_equals() {
    actual=$1
    expected=$2
    message=$3
    if [ "$actual" != "$expected" ]; then
        echo "Assertion failed: $message (expected $expected, got $actual)" >&2
        failures=$((failures + 1))
    fi
}

assert_true "$absolute_rejected" "absolute archive member path must be rejected"
assert_true "$parent_rejected" "parent-traversing archive member path must be rejected"
assert_true "$option_safe" "option-like archive member must be rejected or returned as an absolute operand"
assert_true "$symlink_rejected" "archive directory replaced by an escaping symlink must be rejected"
assert_equals "$extracted_files" "tiny-dir/tiny-file.txt" "Bazel extraction must return its reusable file member list without directory entries"

[ "$failures" -eq 0 ]
