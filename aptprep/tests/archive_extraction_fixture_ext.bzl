"""Repository fixture for archive directory-path validation."""

load("//aptprep/private:archive_extraction.bzl", "extract_data_archive", "validate_archive_directory_path")

def _bool_string(value):
    return "true" if value else "false"

def _is_rejected(result):
    return result.error != None

def _has_absolute_path(rctx, result):
    if result.path == None:
        return False
    path = str(result.path)
    return str(rctx.path(path)) == path

def _archive_extraction_fixture_repo_impl(rctx):
    external_target = rctx.path(".").dirname
    external_member = ".."
    tar = rctx.which("tar")
    if not tar:
        fail("Missing required tool 'tar'")

    option_member = "--reference=outside"
    rctx.file(option_member + "/.keep", "", executable = False)
    rctx.file("replaced-directory/.keep", "", executable = False)
    if not rctx.delete("replaced-directory"):
        fail("Failed to replace archive directory with an escaping symlink")
    rctx.symlink(external_target, "replaced-directory")

    absolute = validate_archive_directory_path(rctx, str(external_target))
    parent = validate_archive_directory_path(rctx, external_member)
    option = validate_archive_directory_path(rctx, option_member)
    symlink = validate_archive_directory_path(rctx, "replaced-directory")

    rctx.file("tar-source/tiny-dir/tiny-file.txt", "tiny fixture\n", executable = False)
    archive_path = rctx.path("tiny.tar")
    tar_result = rctx.execute([
        tar,
        "-cf",
        archive_path,
        "-C",
        rctx.path("tar-source"),
        "tiny-dir",
    ])
    if tar_result.return_code != 0:
        fail("Failed to create tiny archive extraction fixture: {}".format(tar_result.stderr))
    extracted_files = extract_data_archive(
        rctx,
        archive_path,
        "archive-extraction-fixture",
        tar,
        "bazel",
    )
    extracted_files_result = "<missing>" if extracted_files == None else ",".join(extracted_files)

    rctx.file(
        "validation_results.txt",
        "\n".join([
            "absolute_rejected={}".format(_bool_string(_is_rejected(absolute))),
            "parent_rejected={}".format(_bool_string(_is_rejected(parent))),
            "option_safe={}".format(_bool_string(_is_rejected(option) or _has_absolute_path(rctx, option))),
            "symlink_rejected={}".format(_bool_string(_is_rejected(symlink))),
            "extracted_files={}".format(extracted_files_result),
            "",
        ]),
        executable = False,
    )
    rctx.file(
        "BUILD.bazel",
        "\n".join([
            "package(default_visibility = [\"//visibility:public\"])",
            "exports_files([\"validation_results.txt\"])",
            "",
        ]),
        executable = False,
    )

_archive_extraction_fixture_repo = repository_rule(
    implementation = _archive_extraction_fixture_repo_impl,
)

def _archive_extraction_fixture_ext_impl(_module_ctx):
    _archive_extraction_fixture_repo(name = "aptprep_archive_extraction_fixture")

archive_extraction_fixture = module_extension(
    implementation = _archive_extraction_fixture_ext_impl,
)
