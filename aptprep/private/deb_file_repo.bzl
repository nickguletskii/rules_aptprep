"""Repository rule for downloading .deb files without extraction."""

def _deb_file_repo_impl(repository_ctx):
    """Downloads a .deb file and creates a BUILD file to expose it."""
    url = repository_ctx.attr.url
    sha256 = repository_ctx.attr.sha256
    filename = repository_ctx.attr.filename

    # Download the .deb file
    repository_ctx.download(
        url = url,
        output = filename,
        sha256 = sha256,
    )

    # Create BUILD file that exports the .deb
    build_content = """exports_files(["{filename}"])

filegroup(
    name = "file",
    srcs = ["{filename}"],
    visibility = ["//visibility:public"],
)
""".format(filename = filename)

    repository_ctx.file("BUILD.bazel", build_content)

deb_file_repo = repository_rule(
    implementation = _deb_file_repo_impl,
    attrs = {
        "url": attr.string(mandatory = True, doc = "URL of the .deb file"),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the file"),
        "filename": attr.string(mandatory = True, doc = "Name for the downloaded file"),
    },
    doc = "Downloads a .deb file without extracting it",
)
