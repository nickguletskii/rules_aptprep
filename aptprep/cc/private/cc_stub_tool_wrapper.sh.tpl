#!/usr/bin/env bash
#
# cc_stub_tool_wrapper.sh.tpl — failing stand-in for EVERY tool of an aptprep CC
# toolchain whose sysroot has not been generated yet (bootstrap degradation).
#
# The `cc_toolchain_repo` rule renders this once when it detects that a
# referenced sysroot is an ungenerated aptprep stand-in (the
# `APTPREP_FAKE_SYSROOT` sentinel is present). It is wired as the `tool_paths`
# entry for every tool, so toolchain resolution succeeds (letting unrelated
# analysis such as lockfile generation proceed) while any ACTUAL C/C++
# compile/link/archive action against this toolchain fails immediately with an
# actionable message.
#
# Placeholders (filled by the repo rule; this key set is a hard contract):
#   %{TARGET_ARCH}      @platforms//cpu value of the target, e.g. x86_64
#   %{TOOLCHAIN_NAME}   the generated toolchain repo's logical name

cat >&2 <<EOF
aptprep cc_toolchain error: the sysroot for target arch '%{TARGET_ARCH}'
(toolchain '%{TOOLCHAIN_NAME}') is not generated.

This is a placeholder toolchain registered during bootstrap so that toolchain
resolution and non-C/C++ analysis (e.g. aptprep lockfile generation) can
proceed. Actual C/C++ compilation is unavailable until the sysroot is built.

To fix: generate the aptprep lockfiles the sysroot depends on (e.g. run
'./projx sysroot lock'), then rebuild.
EOF
exit 1
