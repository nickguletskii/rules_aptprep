"""e2e for the aptprep-generated cc toolchain.

Builds a C++ library + binary natively (linux/x86_64) and cross (linux/aarch64,
via the platform transition), then asserts the aarch64 ELF machine and the
__DATE__/__TIME__/__TIMESTAMP__ redaction. The aptprep cc toolchains are
registered in MODULE.bazel; toolchain resolution picks them per target platform.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_aptprep//aptprep:rules.bzl", "aptprep_lockfile")
load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":transition.bzl", "platform_transition_binary")

# Regenerate lockfile.json from aptprep.yaml: `bazel run //:generate_lockfile`.
aptprep_lockfile(
    name = "generate_lockfile",
    config = "aptprep.yaml",
)

platform(
    name = "linux_x86_64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
)

platform(
    name = "linux_aarch64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
)

cc_library(
    name = "hello_lib",
    srcs = ["hello_lib.cc"],
    hdrs = ["hello_lib.h"],
)

cc_binary(
    name = "hello",
    srcs = ["hello.cc"],
    deps = [":hello_lib"],
)

cc_binary(
    name = "date_stamp",
    srcs = ["date_stamp.cc"],
)

# Rebuild :hello under the aarch64 platform so toolchain resolution selects the
# aptprep aarch64 cross toolchain. This is the input to verify_aarch64.
platform_transition_binary(
    name = "hello_aarch64",
    src = ":hello",
    platform = ":linux_aarch64",
)

build_test(
    name = "build_both",
    targets = [
        ":hello",
        ":date_stamp",
        ":hello_aarch64",
    ],
)

sh_test(
    name = "verify_aarch64",
    srcs = ["verify_aarch64.sh"],
    args = ["$(rootpath :hello_aarch64)"],
    data = [":hello_aarch64"],
)

sh_test(
    name = "verify_reproducibility",
    srcs = ["verify_reproducibility.sh"],
    args = ["$(rootpath :date_stamp)"],
    data = [":date_stamp"],
)
