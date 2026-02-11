"""Test-only fixture repository for exercising sysroot binary patching.

The fixture intentionally invokes `patch_binaries` from a repository rule,
mirroring how aptprep patches sysroots during repository fetch.
"""

load("//aptprep/private:rpath.bzl", "patch_binaries")
load("//aptprep/private:sysroot_repo.bzl", "expand_patchelf_dir_template", "patchelf_dir_substitutions")

_FIXTURE_PATCHELF_DIR_TEMPLATES = [
    # Include all placeholder variants we support, so this fixture verifies each expansion path.
    "usr/bin/",
    "{lib64}/",
    "lib/{amd64}/",
    "lib/{x86_64}/",
    "lib/{x86_64-linux-gnu}/",
]

def _assert_command_succeeds(rctx, assertion, cmd):
    result = rctx.execute(cmd)
    if result.return_code != 0:
        fail("Assertion failed: {}. Command failed: {} ({}, {}, {})".format(
            assertion,
            " ".join(cmd),
            result.return_code,
            result.stdout,
            result.stderr,
        ))
    return result

def _require_tool(rctx, tool_name):
    tool = rctx.which(tool_name)
    if not tool:
        fail("Missing required tool '{}'".format(tool_name))
    return tool

def _prepare_fixture_layout(rctx):
    _assert_command_succeeds(rctx, "fixture sysroot directory layout can be created", [
        "mkdir",
        "-p",
        "etc/ld.so.conf.d",
        "usr/bin",
        "lib64",
        "lib/amd64",
        "lib/x86_64",
        "lib/x86_64-linux-gnu",
    ])

def _compile_fixture_shared_library(rctx, cc):
    _assert_command_succeeds(rctx, "fixture shared library can be compiled", [
        str(cc),
        "-fPIC",
        "-shared",
        "-Wl,-soname,libaptprep_fixture.so.0",
        "-o",
        "libaptprep_fixture.so.0",
        "fixture_lib.c",
    ])
    _assert_command_succeeds(rctx, "fixture soname symlink can be created", ["ln", "-s", "libaptprep_fixture.so.0", "libaptprep_fixture.so"])

def _compile_fixture_executable(rctx, cc):
    _assert_command_succeeds(rctx, "fixture executable can be compiled", [
        str(cc),
        "-o",
        "rpath_exec",
        "fixture_main.c",
        "-L.",
        "-laptprep_fixture",
    ])

def _place_fixture_artifacts_for_patching(rctx):
    # Copy the executable into each path variant we want `patch_binaries` to patch.
    _assert_command_succeeds(rctx, "fixture shared library can be placed in multiarch lib directory", ["cp", "libaptprep_fixture.so.0", "lib/x86_64-linux-gnu/libaptprep_fixture.so.0"])
    _assert_command_succeeds(rctx, "fixture executable can be copied into usr/bin", ["cp", "rpath_exec", "usr/bin/rpath_exec_usrbin"])
    _assert_command_succeeds(rctx, "fixture executable can be copied into lib64", ["cp", "rpath_exec", "lib64/rpath_exec_lib64"])
    _assert_command_succeeds(rctx, "fixture executable can be copied into lib/amd64", ["cp", "rpath_exec", "lib/amd64/rpath_exec_amd64"])
    _assert_command_succeeds(rctx, "fixture executable can be copied into lib/x86_64", ["cp", "rpath_exec", "lib/x86_64/rpath_exec_x86_64"])
    _assert_command_succeeds(rctx, "fixture executable can be copied into lib/x86_64-linux-gnu", ["cp", "rpath_exec", "lib/x86_64-linux-gnu/rpath_exec_multiarch"])

def _get_interpreter(rctx, patchelf, path):
    return _assert_command_succeeds(rctx, "ELF interpreter can be read from {}".format(path), [str(patchelf), "--print-interpreter", path]).stdout.strip()

def _get_rpath(rctx, patchelf, path):
    return _assert_command_succeeds(rctx, "ELF rpath can be read from {}".format(path), [str(patchelf), "--print-rpath", path]).stdout.strip()

def _capture_runtime_probe_result(rctx, path):
    # Runtime success/failure is asserted in patching_behavior_test.sh.
    return _assert_command_succeeds(rctx, "patched binary {} can be executed".format(path), [str(rctx.path(path).realpath)])

def _single_line(value):
    return value.strip().replace("\n", "\\n").replace("\r", "")

def _patching_fixture_repo_impl(rctx):
    patchelf = _require_tool(rctx, "patchelf")
    cc = _require_tool(rctx, "cc")

    _prepare_fixture_layout(rctx)

    # Build a tiny executable that depends on a shared library we place in the sysroot.
    rctx.file(
        "fixture_lib.c",
        "\n".join([
            "int aptprep_fixture_answer(void) {",
            "    return 42;",
            "}",
            "",
        ]),
        executable = False,
    )
    rctx.file(
        "fixture_main.c",
        "\n".join([
            "#include <stdio.h>",
            "",
            "int aptprep_fixture_answer(void);",
            "",
            "int main(void) {",
            "    if (aptprep_fixture_answer() != 42) {",
            "        return 1;",
            "    }",
            "    puts(\"aptprep-rpath-ok\");",
            "    return 0;",
            "}",
            "",
        ]),
        executable = False,
    )

    _compile_fixture_shared_library(rctx, cc)
    _compile_fixture_executable(rctx, cc)
    _place_fixture_artifacts_for_patching(rctx)

    rctx.file("etc/ld.so.conf.d/zz-test.conf", "/lib/x86_64-linux-gnu\n", executable = False)
    source_interpreter = _get_interpreter(rctx, patchelf, "rpath_exec")
    _assert_command_succeeds(rctx, "source dynamic loader can be copied into sysroot", ["cp", source_interpreter, "lib64/ld-linux-x86-64.so.2"])

    # `patch_binaries` expects a busybox entrypoint with `find` and `sh` dispatch.
    rctx.file(
        "busybox",
        "\n".join([
            "#!/bin/sh",
            "cmd=\"$1\"",
            "shift",
            "exec \"$cmd\" \"$@\"",
            "",
        ]),
        executable = True,
    )

    substitutions = patchelf_dir_substitutions("amd64")
    patchelf_dirs = [expand_patchelf_dir_template(path_template, substitutions) for path_template in rctx.attr.patchelf_dirs]

    # Execute the code under test.
    patch_binaries(
        rctx,
        str(rctx.path("busybox")),
        str(patchelf),
        "amd64",
        patchelf_dirs = patchelf_dirs,
    )

    # Capture patched metadata to be asserted by the shell test.
    interpreter = _get_interpreter(rctx, patchelf, "usr/bin/rpath_exec_usrbin")
    rpath_multiarch = _get_rpath(rctx, patchelf, "lib/x86_64-linux-gnu/rpath_exec_multiarch")
    rpath_x86_64 = _get_rpath(rctx, patchelf, "lib/x86_64/rpath_exec_x86_64")
    rpath_amd64 = _get_rpath(rctx, patchelf, "lib/amd64/rpath_exec_amd64")
    rpath_lib64 = _get_rpath(rctx, patchelf, "lib64/rpath_exec_lib64")

    # Execute each patched binary to verify runtime resolution through rewritten RPATH/interpreter.
    run_usrbin = _capture_runtime_probe_result(rctx, "usr/bin/rpath_exec_usrbin")
    run_multiarch = _capture_runtime_probe_result(rctx, "lib/x86_64-linux-gnu/rpath_exec_multiarch")
    run_x86_64 = _capture_runtime_probe_result(rctx, "lib/x86_64/rpath_exec_x86_64")
    run_amd64 = _capture_runtime_probe_result(rctx, "lib/amd64/rpath_exec_amd64")
    run_lib64 = _capture_runtime_probe_result(rctx, "lib64/rpath_exec_lib64")

    expected_interpreter = str(rctx.path("lib64/ld-linux-x86-64.so.2").realpath)
    expected_runtime_stdout = "aptprep-rpath-ok"
    expected_rpath_two_up = "$ORIGIN/../../lib/x86_64-linux-gnu"
    expected_rpath_one_up = "$ORIGIN/../lib/x86_64-linux-gnu"

    # Persist all observed values for explicit assertions in `patching_behavior_test.sh`.
    rctx.file(
        "patch_results.txt",
        "\n".join([
            "interpreter={}".format(interpreter),
            "interpreter_expected={}".format(expected_interpreter),
            "rpath_multiarch={}".format(rpath_multiarch),
            "rpath_x86_64={}".format(rpath_x86_64),
            "rpath_amd64={}".format(rpath_amd64),
            "rpath_lib64={}".format(rpath_lib64),
            "expected_rpath_two_up={}".format(expected_rpath_two_up),
            "expected_rpath_one_up={}".format(expected_rpath_one_up),
            "expected_runtime_stdout={}".format(expected_runtime_stdout),
            "run_usrbin_rc={}".format(run_usrbin.return_code),
            "run_usrbin_stdout={}".format(_single_line(run_usrbin.stdout)),
            "run_usrbin_stderr={}".format(_single_line(run_usrbin.stderr)),
            "run_multiarch_rc={}".format(run_multiarch.return_code),
            "run_multiarch_stdout={}".format(_single_line(run_multiarch.stdout)),
            "run_multiarch_stderr={}".format(_single_line(run_multiarch.stderr)),
            "run_x86_64_rc={}".format(run_x86_64.return_code),
            "run_x86_64_stdout={}".format(_single_line(run_x86_64.stdout)),
            "run_x86_64_stderr={}".format(_single_line(run_x86_64.stderr)),
            "run_amd64_rc={}".format(run_amd64.return_code),
            "run_amd64_stdout={}".format(_single_line(run_amd64.stdout)),
            "run_amd64_stderr={}".format(_single_line(run_amd64.stderr)),
            "run_lib64_rc={}".format(run_lib64.return_code),
            "run_lib64_stdout={}".format(_single_line(run_lib64.stdout)),
            "run_lib64_stderr={}".format(_single_line(run_lib64.stderr)),
            "",
        ]),
        executable = False,
    )

    rctx.file(
        "BUILD.bazel",
        "\n".join([
            "package(default_visibility = [\"//visibility:public\"])",
            "exports_files([\"patch_results.txt\"])",
            "",
        ]),
        executable = False,
    )

_patching_fixture_repo = repository_rule(
    implementation = _patching_fixture_repo_impl,
    attrs = {
        "patchelf_dirs": attr.string_list(
            default = _FIXTURE_PATCHELF_DIR_TEMPLATES,
        ),
        "patch_binaries_whitelist_regex": attr.string_list(default = []),
        "patch_binaries_blacklist_regex": attr.string_list(default = []),
    },
)

_fixture_tag = tag_class(attrs = {
    "name": attr.string(mandatory = True),
})

def _patching_fixture_ext_impl(module_ctx):
    for module in module_ctx.modules:
        for tag in module.tags.fixture:
            _patching_fixture_repo(
                name = tag.name,
            )

patching_fixture = module_extension(
    implementation = _patching_fixture_ext_impl,
    tag_classes = {
        "fixture": _fixture_tag,
    },
)
