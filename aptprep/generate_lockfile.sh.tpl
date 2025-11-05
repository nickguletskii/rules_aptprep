#!/bin/bash
set -e

# Resolve the runfiles directory
if [ -z "${RUNFILES_DIR}" ]; then
    # Compute runfiles directory from script location
    SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" 2>/dev/null && pwd )/$(basename "${BASH_SOURCE[0]}")"
    RUNFILES_DIR="${SCRIPT_PATH}.runfiles"

    # Verify the runfiles directory exists
    if [ ! -d "$RUNFILES_DIR" ]; then
        echo "Error: Runfiles directory not found at $RUNFILES_DIR" >&2
        exit 1
    fi
fi

# Use BUILD_WORKSPACE_DIRECTORY when available (bazel run)
if [ -n "$BUILD_WORKSPACE_DIRECTORY" ]; then
    WORKSPACE_ROOT="$BUILD_WORKSPACE_DIRECTORY"
else
    WORKSPACE_ROOT="$(pwd)"
fi

# Paths relative to runfiles
CONFIG_PATH="${RUNFILES_DIR}/_main/{CONFIG}"
APTPREP_TOOL="${RUNFILES_DIR}/{TOOL_PATH}"
LOCKFILE="$WORKSPACE_ROOT/{OUTPUT_PATH}"

mkdir -p "$(dirname "$LOCKFILE")"

"$APTPREP_TOOL" lock --config "$CONFIG_PATH" --lockfile "$LOCKFILE"
