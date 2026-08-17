"""Host-specific archive extraction helpers for aptprep repositories."""

def archive_extractor_for_os(os_name, override = "auto"):
    """Select the effective archive extractor.

    Args:
        os_name: The host-reported name. Case-insensitive "darwin" and
            "mac os x" select Bazel in auto mode; all others select GNU tar.
        override: One of "auto", "bazel", or "tar". An explicit extractor wins.

    Returns:
        The effective "bazel" or "tar" extractor name.
    """
    if override not in ("auto", "bazel", "tar"):
        fail("Unknown aptprep archive extractor '{}'; expected auto, bazel, or tar".format(override))
    if override != "auto":
        return override

    normalized = os_name.lower()
    if normalized == "darwin" or normalized == "mac os x":
        return "bazel"
    return "tar"

def mode_from_tar_permissions(permissions):
    """Convert a tar verbose-listing permission field to an octal mode.

    Args:
        permissions: The first ten characters from a `tar -tvf` entry, including
            its type and rwx/s/t positions.

    Returns:
        A four-digit octal mode string whose first digit contains special bits.
    """
    if len(permissions) < 10:
        fail("Invalid tar permission field '{}'".format(permissions))

    digits = []
    for offset in (1, 4, 7):
        value = 0
        if permissions[offset] == "r":
            value += 4
        if permissions[offset + 1] == "w":
            value += 2
        if permissions[offset + 2] in ("x", "s", "t"):
            value += 1
        digits.append(str(value))

    special = 0
    if permissions[3] in ("s", "S"):
        special += 4
    if permissions[6] in ("s", "S"):
        special += 2
    if permissions[9] in ("t", "T"):
        special += 1
    return "{}{}".format(special, "".join(digits))

def _archive_directory_path_error(message):
    """Return a rejected archive directory-path result."""
    return struct(
        error = message,
        path = None,
    )

def validate_archive_directory_path(rctx, member_name):
    """Validate an archive directory member within a repository root.

    Args:
        rctx: The repository context whose canonical root bounds resolution.
        member_name: The archive-provided member name, passed verbatim.

    Returns:
        A result with exactly one of `error` or `path` set. A path is canonical,
        absolute, and names an existing non-symlink directory within the root.
    """
    normalized_name = member_name.replace("\\", "/")
    if normalized_name.startswith("/"):
        return _archive_directory_path_error("archive member path is absolute")
    path_segments = normalized_name.split("/")
    first_segment = ""
    for segment in path_segments:
        if segment not in ("", "."):
            first_segment = segment
            break
    if (
        len(first_segment) >= 2 and
        first_segment[1] == ":" and
        first_segment[0].lower() in "abcdefghijklmnopqrstuvwxyz"
    ):
        return _archive_directory_path_error("archive member path uses a drive prefix")
    if ".." in path_segments:
        return _archive_directory_path_error("archive member path uses parent traversal")

    repository_root = rctx.path(".").realpath
    repository_root_string = str(repository_root)
    candidate_path = rctx.path(repository_root_string + "/" + member_name)
    if not candidate_path.exists:
        return _archive_directory_path_error("extracted archive member does not exist")

    canonical_path = candidate_path.realpath
    canonical_path_string = str(canonical_path)
    if (
        canonical_path_string != repository_root_string and
        not canonical_path_string.startswith(repository_root_string + "/")
    ):
        return _archive_directory_path_error("resolved archive member escapes the repository root")
    if canonical_path_string != str(candidate_path):
        return _archive_directory_path_error("archive directory path resolves through a symlink")
    if not canonical_path.is_dir:
        return _archive_directory_path_error("extracted archive member is not a directory")

    return struct(
        error = None,
        path = canonical_path_string,
    )

def _restore_archive_directory_modes(rctx, tar_path, tar_tool):
    names_result = rctx.execute([tar_tool, "-tf", str(tar_path)])
    verbose_result = rctx.execute([tar_tool, "-tvf", str(tar_path)])
    if names_result.return_code or verbose_result.return_code:
        fail("Failed to inspect directory modes in tar file {}: ({}, {})".format(
            tar_path,
            names_result.stderr,
            verbose_result.stderr,
        ))

    names = names_result.stdout.splitlines()
    verbose_lines = verbose_result.stdout.splitlines()
    if len(names) != len(verbose_lines):
        fail("Tar returned different entry counts for normal and verbose listings of {}".format(tar_path))

    directories_by_mode = {}
    for index in range(len(names)):
        permissions = verbose_lines[index][:10]
        if not permissions.startswith("d"):
            continue
        directory = validate_archive_directory_path(rctx, names[index])
        if directory.error != None:
            fail("Refusing to restore directory mode for archive member '{}' from {}: {}".format(
                names[index],
                tar_path,
                directory.error,
            ))
        mode = mode_from_tar_permissions(permissions)
        directories_by_mode.setdefault(mode, []).append(directory.path)

    chmod = rctx.which("chmod")
    if not chmod:
        fail("Could not find `chmod` in PATH; Bazel archive extraction requires it to restore directory modes")
    for mode, directories in directories_by_mode.items():
        for start in range(0, len(directories), 256):
            result = rctx.execute([chmod, mode] + directories[start:start + 256])
            if result.return_code != 0:
                fail("Failed to restore directory mode {} from {}: {}".format(mode, tar_path, result.stderr))
    return [name for name in names if not name.endswith("/")]

def extract_data_archive(rctx, archive_path, package_key, tar_tool, archive_extractor):
    """Extract a package data archive.

    Args:
        rctx: The repository context receiving the extracted files.
        archive_path: The package data archive path.
        package_key: The package identifier used in extraction errors.
        tar_tool: The host tar executable used for extraction and inspection.
        archive_extractor: The selected "bazel" or "tar" implementation.

    Returns:
        Bazel extraction returns archive-ordered non-directory member names.
        GNU tar extraction returns `None` because it collects no reusable list.
    """

    # Bazel's extractor avoids host tar filesystem operations that are unreliable
    # on filesystems exported into Darwin. GNU tar remains faster on Linux.
    if archive_extractor == "bazel":
        rctx.extract(
            archive = archive_path,
            output = ".",
        )
        return _restore_archive_directory_modes(rctx, archive_path, str(tar_tool))

    result = rctx.execute([str(tar_tool), "-xpf", str(archive_path), "-C", "."])
    if result.return_code != 0:
        fail("Failed to extract package data archive for {}: {}".format(package_key, result.stderr))
    return None
