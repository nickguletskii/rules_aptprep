"""Provides a simple way to test your rules as an external workspace.
Add a basic smoke-test target below.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_aptprep//aptprep:rules.bzl", "aptprep_lockfile")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":extraction_comparison_test.bzl", "extraction_comparison_test_suite")

extraction_comparison_test_suite(name = "extraction_comparison_override_test")

# Generate lockfile from aptprep config using the aptprep binary
aptprep_lockfile(
    name = "generate_lockfile",
    config = "aptprep.yaml",
)

build_test(
    name = "smoke_test_packages",
    targets = [
        "@aptprep_smoke_packages//:all_debs",
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
        "@aptprep_smoke_sysroot//:files",
    ],
)

sh_test(
    name = "compare_extractors_test",
    srcs = ["compare_extractors_test.sh"],
    data = ["@aptprep_extraction_comparison//:result.txt"],
)
