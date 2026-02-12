"""Repository rule for downloading and extracting Debian packages."""

_CONTROL_ARCHIVE_CANDIDATES = [
    "control.tar.zstd",
    "control.tar.zst",
    "control.tar.xz",
    "control.tar.gz",
    "control.tar.bz2",
    "control.tar",
]

_DATA_ARCHIVE_CANDIDATES = [
    "data.tar.zstd",
    "data.tar.zst",
    "data.tar.xz",
    "data.tar.gz",
    "data.tar.bz2",
    "data.tar",
]

_DATA_ARCHIVE_METADATA_FILENAME = "data_archive_filename.txt"

def _execute_or_fail(repository_ctx, args, error_prefix, working_directory = None):
    """Execute a command and fail with diagnostic output if it fails."""
    if working_directory != None:
        result = repository_ctx.execute(args, working_directory = working_directory)
    else:
        result = repository_ctx.execute(args)
    if result.return_code != 0:
        fail("{}: {}\nstdout:\n{}\nstderr:\n{}".format(
            error_prefix,
            " ".join(args),
            result.stdout,
            result.stderr,
        ))
    return result

def _replace_tokens(template, substitutions):
    """Apply string token substitutions."""
    output = template
    for token, value in substitutions.items():
        output = output.replace(token, value)
    return output

def _find_archive(repository_ctx, directory, candidates):
    """Find first matching archive file in directory from candidates list."""
    for candidate in candidates:
        path = "{}/{}".format(directory, candidate)
        if repository_ctx.path(path).exists:
            return path
    return None

def _basename(path):
    parts = path.rsplit("/", 1)
    if len(parts) == 2:
        return parts[1]
    return path

def _normalize_archive(repository_ctx, source_path, archive_stem):
    """Preserve archive extension except for zstd, which becomes .tar."""
    source_filename = _basename(source_path)
    if source_filename.endswith(".zst") or source_filename.endswith(".zstd"):
        output_path = archive_stem + ".tar"
        unzstd = repository_ctx.which("unzstd")
        if unzstd:
            _execute_or_fail(
                repository_ctx,
                [str(unzstd), "-f", source_path, "-o", output_path],
                "Failed to uncompress zstd archive with unzstd",
            )
            return output_path

        zstd = repository_ctx.which("zstd")
        if not zstd:
            fail("Found zstd archive {}, but neither `unzstd` nor `zstd` is available in PATH".format(source_path))

        _execute_or_fail(
            repository_ctx,
            [str(zstd), "-d", "-f", source_path, "-o", output_path],
            "Failed to uncompress zstd archive with zstd",
        )
        return output_path

    output_path = source_filename
    _execute_or_fail(
        repository_ctx,
        ["cp", source_path, output_path],
        "Failed to copy archive",
    )
    return output_path

def _deb_file_repo_impl(repository_ctx):
    """Download a .deb and expose the original file plus control/data artifacts."""
    url = repository_ctx.attr.url
    sha256 = repository_ctx.attr.sha256
    filename = repository_ctx.attr.filename

    # Download the .deb file.
    kwargs = {
        "url": url,
        "output": filename,
    }
    if sha256:
        kwargs["sha256"] = sha256
    repository_ctx.download(**kwargs)

    # .deb is an ar archive. Extract it with `ar` into a temp directory.
    deb_contents_dir = "deb_contents"
    _execute_or_fail(
        repository_ctx,
        ["mkdir", "-p", deb_contents_dir],
        "Failed to create temporary extraction directory",
    )
    ar_tool = repository_ctx.which("ar")
    if not ar_tool:
        fail("Could not find `ar` in PATH; it is required to unpack .deb files")
    _execute_or_fail(
        repository_ctx,
        [str(ar_tool), "x", "../{}".format(filename)],
        "Failed to extract .deb ar archive",
        working_directory = deb_contents_dir,
    )

    # Normalize control and data archives to stable filenames for downstream use.
    control_archive = _find_archive(repository_ctx, deb_contents_dir, _CONTROL_ARCHIVE_CANDIDATES)
    if not control_archive:
        fail("Could not find control archive in .deb; checked: {}".format(", ".join(_CONTROL_ARCHIVE_CANDIDATES)))
    control_archive_filename = _normalize_archive(
        repository_ctx,
        control_archive,
        "control",
    )

    data_archive = _find_archive(repository_ctx, deb_contents_dir, _DATA_ARCHIVE_CANDIDATES)
    if not data_archive:
        fail("Could not find data archive in .deb; checked: {}".format(", ".join(_DATA_ARCHIVE_CANDIDATES)))
    data_archive_filename = _normalize_archive(
        repository_ctx,
        data_archive,
        "data",
    )

    _execute_or_fail(
        repository_ctx,
        ["rm", "-rf", deb_contents_dir],
        "Failed to clean temporary extraction files",
    )

    repository_ctx.file(
        _DATA_ARCHIVE_METADATA_FILENAME,
        data_archive_filename + "\n",
    )

    substitutions = {
        "{DEB_FILENAME}": filename,
        "{DATA_ARCHIVE_FILENAME}": data_archive_filename,
        "{DATA_ARCHIVE_METADATA_FILENAME}": _DATA_ARCHIVE_METADATA_FILENAME,
        "{CONTROL_ARCHIVE_FILENAME}": control_archive_filename,
        "{PACKAGE_NAME}": repository_ctx.attr.package_name,
        "{PACKAGE_KEY}": repository_ctx.attr.package_key,
        "{PACKAGE_VERSION}": repository_ctx.attr.package_version,
        "{PACKAGE_ARCHITECTURE}": repository_ctx.attr.package_architecture,
    }
    repository_ctx.file(
        "BUILD.bazel",
        _replace_tokens(repository_ctx.attr.build_file_content_template, substitutions),
    )

deb_file_repo = repository_rule(
    implementation = _deb_file_repo_impl,
    attrs = {
        "url": attr.string(mandatory = True, doc = "URL of the .deb file"),
        "sha256": attr.string(doc = "SHA256 checksum of the file"),
        "filename": attr.string(mandatory = True, doc = "Name for the downloaded file"),
        "build_file_content_template": attr.string(mandatory = True, doc = "BUILD file content template."),
        "package_name": attr.string(mandatory = True, doc = "Debian package name."),
        "package_key": attr.string(mandatory = True, doc = "Unique package key from lockfile."),
        "package_version": attr.string(mandatory = True, doc = "Debian package version."),
        "package_architecture": attr.string(mandatory = True, doc = "Debian package architecture."),
    },
    doc = "Download a .deb and expose file/control/data artifacts",
)
