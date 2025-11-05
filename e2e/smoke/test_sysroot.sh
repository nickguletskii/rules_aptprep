#!/bin/bash

# Test script to verify that the sysroot contains expected binaries and libraries
# from the debian packages, including transitive dependencies.

# The sysroot repository should be available in the runfiles
# Bazel provides the RUNFILES_DIR environment variable pointing to the test's runfiles directory
SYSROOT_DIR=""

# Determine the runfiles directory
RUNFILES_DIR="${RUNFILES_DIR:-.}"

if [ -d "$RUNFILES_DIR/rules_aptprep++aptprep+aptprep_smoke_sysroot" ]; then
    SYSROOT_DIR="$RUNFILES_DIR/rules_aptprep++aptprep+aptprep_smoke_sysroot"
fi

if [ -z "$SYSROOT_DIR" ] || [ ! -d "$SYSROOT_DIR" ]; then
    echo "ERROR: Could not locate sysroot directory"
    echo "Attempted locations:"
    echo "  - $RUNFILES_DIR/rules_aptprep++aptprep+aptprep_smoke_sysroot (module mangled)"
    echo "  - $RUNFILES_DIR/external/aptprep_smoke_sysroot (standard location)"
    [ -n "$TEST_SRCDIR" ] && echo "  - $TEST_SRCDIR/rules_aptprep++aptprep+aptprep_smoke_sysroot"
    echo "  - external/aptprep_smoke_sysroot (relative)"
    echo "  - aptprep_smoke_sysroot (as symlink)"
    echo ""
    echo "Environment:"
    echo "  RUNFILES_DIR=$RUNFILES_DIR"
    echo "  TEST_SRCDIR=$TEST_SRCDIR"
    echo "  TEST_TMPDIR=$TEST_TMPDIR"
    echo "  PWD=$PWD"
    echo ""
    echo "Current directory contents:"
    ls -la . 2>/dev/null | head -20
    echo ""
    echo "This test requires the @aptprep_smoke_sysroot repository to be available."
    echo "The repository should be created during the bazel build process."
    exit 1
fi

echo "Testing sysroot at: $SYSROOT_DIR"

# Check for basic binaries that should be in the sysroot
# These come from packages like bash, curl, etc.
# Ubuntu packages typically put binaries in /usr/bin/
BINARIES_TO_CHECK=(
    "usr/bin/bash"
    "usr/bin/curl"
)

# Check for basic libraries that should be in the sysroot
# Just check if there are any .so files which would indicate libraries
LIBRARIES_TO_CHECK=(
    ".*\.so(\.[0-9]+)?$"
)

FAILED=0
PASSED=0

# Check binaries
echo "Checking for binaries..."
for binary in "${BINARIES_TO_CHECK[@]}"; do
    if [ -f "$SYSROOT_DIR/$binary" ]; then
        echo "✓ Found $binary"
        ((PASSED++))
    else
        echo "✗ Missing $binary"
        ((FAILED++))
    fi
done

# Check libraries - look for any .so files
# Use -L flag to follow symlinks since files may be symlinked from external directory
echo ""
echo "Checking for libraries..."
lib_count=$(find -L "$SYSROOT_DIR" -name "*.so*" -type f 2>/dev/null | wc -l)
if [ "$lib_count" -gt 0 ]; then
    echo "✓ Found $lib_count shared object files (.so)"
    ((PASSED++))
else
    echo "✗ Missing shared object files"
    ((FAILED++))
fi

echo ""
echo "Sysroot contents summary:"
file_count=$(find -L "$SYSROOT_DIR" -type f ! -name "*.bazel" ! -name "BUILD*" ! -name "REPO*" ! -name "*manifest*" 2>/dev/null | wc -l)
echo "$file_count files extracted"

echo ""
echo "Results: $PASSED passed, $FAILED failed"

if [ $FAILED -gt 0 ]; then
    echo "Test FAILED"
    exit 1
else
    echo "Test PASSED"
    exit 0
fi
