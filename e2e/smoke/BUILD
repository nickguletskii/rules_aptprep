"""Provides a simple way to test your rules as an external workspace.
Add a basic smoke-test target below.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_aptprep//aptprep:rules.bzl", "aptprep_lockfile")

# Generate lockfile from aptprep config using the aptprep binary
aptprep_lockfile(
    name = "generate_lockfile",
    config = "aptprep.yaml",
)

build_test(
    name = "smoke_test_packages",
    targets = [
        "@aptprep_smoke_packages//:foo",
    ],
)

# Test that sysroot was created with the expected binaries and libraries
# Note: This test validates that the sysroot repository was created with
# the extracted debian packages including all their transitive dependencies
sh_test(
    name = "smoke_test_sysroot",
    srcs = ["test_sysroot.sh"],
    data = [
        # Reference the sysroot filegroup to ensure it's built
        "@aptprep_smoke_sysroot//:sysroot",
    ],
)

