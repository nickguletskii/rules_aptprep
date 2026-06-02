"""Test-only fixture for the cc-toolchain bootstrap-degradation behavior.

Exercises the "ungenerated sysroot -> stub toolchain" path without any network
fetch: it materializes an `aptprep_fake_repo` (the ungenerated stand-in that the
real extension emits when a sysroot lockfile is absent) and wires a
`cc_toolchain_repo` whose compiler/target sysroots both point at it. Because the
fake repo drops the `APTPREP_FAKE_SYSROOT` sentinel, `cc_toolchain_repo` must
degrade to a STUB toolchain (valid `toolchain()` target, same name/constraints,
but a failing wrapper) instead of running its real fetch-time validation.

A companion repo copies the generated BUILD + wrapper out so the in-workspace
`cc_bootstrap_behavior_test.sh` can assert on them. The contrast with the real
(generated-sysroot) path is covered by the cc e2e workspace, which builds an
actual sysroot; here we only pin down the bootstrap branch.
"""

load("//aptprep/cc/private:cc_toolchain_repo.bzl", "cc_toolchain_repo")  # buildifier: disable=bzl-visibility
load("//aptprep/private:packages_repo.bzl", "aptprep_fake_repo")  # buildifier: disable=bzl-visibility

def _collect_repo_impl(rctx):
    # Copy the artifacts produced by the stub cc_toolchain_repo into this repo so
    # a plain sh_test can read them as data deps.
    stub_build = rctx.read(rctx.path(rctx.attr.stub_build))
    stub_wrapper = rctx.read(rctx.path(rctx.attr.stub_wrapper))

    rctx.file("stub_BUILD.txt", stub_build)
    rctx.file("stub_wrapper.txt", stub_wrapper)
    rctx.file(
        "BUILD.bazel",
        "package(default_visibility = [\"//visibility:public\"])\n" +
        "exports_files([\"stub_BUILD.txt\", \"stub_wrapper.txt\"])\n",
    )

_collect_repo = repository_rule(
    implementation = _collect_repo_impl,
    attrs = {
        "stub_build": attr.label(mandatory = True),
        "stub_wrapper": attr.label(mandatory = True),
    },
)

def _cc_bootstrap_fixture_ext_impl(module_ctx):
    # 1. The ungenerated-sysroot stand-in (emitted by the real extension when a
    #    lockfile is absent). Drops the APTPREP_FAKE_SYSROOT sentinel.
    aptprep_fake_repo(
        name = "aptprep_cc_bootstrap_fake_sysroot",
        repo_name = "aptprep_cc_bootstrap_fake_sysroot",
    )

    # 2. A cc_toolchain_repo whose sysroots are both the fake repo. This must
    #    degrade to a stub toolchain rather than failing fetch-time validation.
    cc_toolchain_repo(
        name = "aptprep_cc_bootstrap_stub",
        target_triple = "aarch64-unknown-linux-gnu",
        target_arch = "aarch64",
        target_os = "linux",
        compiler_sysroot = "@aptprep_cc_bootstrap_fake_sysroot",
        compiler_arch = "amd64",
        target_sysroot = "@aptprep_cc_bootstrap_fake_sysroot",
        target_debian_arch = "arm64",
        clang_version = "18",
        exec_constraints = ["@platforms//os:linux", "@platforms//cpu:x86_64"],
        target_constraints = ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    )

    # 3. Copy out the generated artifacts for assertion.
    _collect_repo(
        name = "aptprep_cc_bootstrap_results",
        stub_build = "@aptprep_cc_bootstrap_stub//:BUILD.bazel",
        stub_wrapper = "@aptprep_cc_bootstrap_stub//:wrappers/ungenerated.sh",
    )

cc_bootstrap_fixture = module_extension(
    implementation = _cc_bootstrap_fixture_ext_impl,
)
