"""Sysroot repository rule and tar utilities for aptprep extension."""

load("//aptprep/private:rpath.bzl", "patch_binaries")

_GNU_CPU_ARCH_BY_DEBIAN_ARCH = {
    "amd64": "x86_64",
    "arm64": "aarch64",
    "armhf": "arm",
    "i386": "i386",
    "ppc64el": "powerpc64le",
    "s390x": "s390x",
}

_MULTIARCH_DIR_BY_DEBIAN_ARCH = {
    "amd64": "x86_64-linux-gnu",
    "arm64": "aarch64-linux-gnu",
    "armhf": "arm-linux-gnueabihf",
    "i386": "i386-linux-gnu",
    "ppc64el": "powerpc64le-linux-gnu",
    "s390x": "s390x-linux-gnu",
}

_LIB_DIR_BY_DEBIAN_ARCH = {
    "amd64": "lib64",
    "arm64": "lib",
    "armhf": "lib",
    "i386": "lib",
    "ppc64el": "lib64",
    "s390x": "lib64",
}

DEFAULT_PATCHELF_DIRS = [
    "usr/bin/",
    "bin/",
    "usr/sbin/",
    "sbin/",
    "usr/lib/{x86_64-linux-gnu}/",
    "lib/{x86_64-linux-gnu}/",
    "usr/lib/{x86_64}/",
    "lib/{x86_64}/",
    "usr/lib/{amd64}/",
    "lib/{amd64}/",
    "usr/{lib64}/",
    "{lib64}/",
    "usr/lib/",
    "lib/",
]

def _patchelf_dir_substitutions(arch):
    return {
        # Backward-compatible placeholder.
        "arch": arch,

        # Named placeholder variants based on amd64 conventions.
        "lib64": _LIB_DIR_BY_DEBIAN_ARCH.get(arch, "lib"),
        "amd64": arch,
        "x86_64": _GNU_CPU_ARCH_BY_DEBIAN_ARCH.get(arch, arch),
        "x86_64-linux-gnu": _MULTIARCH_DIR_BY_DEBIAN_ARCH.get(arch, arch),
    }

def _expand_patchelf_dir_template(path_template, substitutions):
    result = path_template
    for key, value in substitutions.items():
        result = result.replace("{" + key + "}", value)
    return result

def patchelf_dir_substitutions(arch):
    return _patchelf_dir_substitutions(arch)

def expand_patchelf_dir_template(path_template, substitutions):
    return _expand_patchelf_dir_template(path_template, substitutions)

def _dirname(path):
    parts = path.rsplit("/", 1)
    if len(parts) == 2:
        return parts[0]
    return "."

def _find_package_key(packages_data, package_name, architecture):
    for package_key, package_info in packages_data.items():
        if package_info["name"] == package_name and package_info["architecture"] == architecture:
            return package_key
    return None

def _list_tar_files(rctx, tar_path, tar_tool):
    """List files in a tar archive."""
    cmd = [tar_tool, "-tf", str(tar_path)]
    result = rctx.execute(cmd)
    if result.return_code:
        fail("Failed to list tar file {}: ({}, {}, {})".format(
            tar_path,
            result.return_code,
            result.stdout,
            result.stderr,
        ))

    files = []
    for line in result.stdout.splitlines():
        if not line.endswith("/"):
            files.append(line)
    return files

def _fix_sysroot_symlinks(rctx):
    """Fix symlinks in the sysroot to not reference absolute paths and prevent loops."""

    # Helper function to check if a symlink would create a loop
    def would_create_loop(symlink_path, target):
        """Check if a symlink target would cause it to point to an ancestor directory."""

        # Get the directory containing the symlink
        symlink_parts = symlink_path.split("/")
        symlink_dir_parts = symlink_parts[:-1]  # Remove the symlink filename

        # Parse the target path
        target_parts = target.split("/")

        # Normalize the target relative to the symlink's directory
        resolved_parts = list(symlink_dir_parts)
        for part in target_parts:
            if part == "..":
                if resolved_parts:
                    resolved_parts.pop()
            elif part != "" and part != ".":
                resolved_parts.append(part)

        # Check if resolved path is the symlink's directory or an ancestor
        # This prevents symlinks pointing to . (current dir) or .. (parent dir), etc.
        # A loop occurs if the resolved path is at or above the symlink's directory
        # We check if symlink_dir_parts starts with resolved_parts (i.e., resolved is an ancestor)
        if len(resolved_parts) > len(symlink_dir_parts):
            return False  # Target is deeper in tree, not an ancestor

        # Check if symlink directory path starts with resolved path
        for i in range(len(resolved_parts)):
            if symlink_dir_parts[i] != resolved_parts[i]:
                return False  # Different path, not an ancestor

        return True  # Target is at or above symlink directory

    # Find all symlinks and fix them
    find_result = rctx.execute(["find", ".", "-type", "l"])
    if find_result.return_code == 0:
        for symlink_path in find_result.stdout.splitlines():
            # Get the target of the symlink
            readlink_result = rctx.execute(["readlink", symlink_path])
            if readlink_result.return_code == 0:
                target = readlink_result.stdout.strip()
                if would_create_loop(symlink_path, target):
                    rctx.delete(symlink_path)

                    # print("Removed symlink that would create loop: {}".format(symlink_path))
                    continue
                if target.startswith("/"):
                    # we get something like './some/path/lib.so` for `symlink_path`
                    # so we subtract 2 for the leading `.` and the filename
                    levels = [".." for _ in range(len(symlink_path.split("/")) - 2)]
                    new_target = "/".join(levels) + target
                    rctx.delete(symlink_path)

                    # Only fix the symlink if it doesn't create a loop
                    if not would_create_loop(symlink_path, new_target):
                        # preferably this would be a`rctx.symlink(new_target, symlink_path)`
                        # but that normalizes `new_target`
                        rctx.execute(["ln", "-s", new_target, symlink_path])
                    else:
                        pass
                        # print("Removed symlink that would create loop: {}".format(symlink_path))

def _aptprep_sysroot_impl(repository_ctx):
    """Implementation for aptprep_sysroot repository rule."""
    packages_list = repository_ctx.attr.packages_list
    packages_data_json = repository_ctx.attr.packages_data
    package_data_archive_metadata = repository_ctx.attr.package_data_archives
    architecture = repository_ctx.attr.architecture
    extra_links = repository_ctx.attr.extra_links
    add_files = repository_ctx.attr.add_files
    patch_binaries_enabled = repository_ctx.attr.patch_binaries
    build_file = repository_ctx.attr.build_file

    tar_tool = repository_ctx.which("tar")
    if not tar_tool:
        fail("Could not find `tar` in PATH; it is required to extract package data archives")

    # Watch the build file template for changes
    if build_file:
        repository_ctx.watch(build_file)

    # Watch all additional files for changes
    for dest_path, source_label in add_files.items():
        repository_ctx.watch(source_label)

    # Parse package data from JSON.
    packages_data = json.decode(packages_data_json)

    # Create sysroot directory structure
    repository_ctx.execute(["mkdir", "-p", "etc"])

    # Create extra links first if specified
    for link_from, link_to in extra_links.items():
        dir_path = link_from.rsplit("/", 1)[0] if "/" in link_from else "."
        mkdir_result = repository_ctx.execute(["mkdir", "-p", dir_path])
        if mkdir_result.return_code != 0:
            fail("Failed to create directory for symlink {}: {}".format(link_from, mkdir_result.stderr))

        ln_result = repository_ctx.execute(["ln", "-s", link_to, link_from])
        if ln_result.return_code != 0:
            fail("Failed to create symlink {} -> {}: {}".format(link_from, link_to, ln_result.stderr))

    # Build the complete list of packages to extract, including all transitive dependencies
    # Use iterative approach with multiple passes to handle dependency chains
    packages_to_extract = {}
    packages_to_process = packages_list[:]  # Copy of requested packages

    # Make multiple passes to collect all transitive dependencies
    for _ in range(100):  # Max 100 levels of dependencies
        new_packages = []

        for pkg_name in packages_to_process:
            if pkg_name in packages_to_extract:
                continue  # Already processed

            package_key = _find_package_key(packages_data, pkg_name, architecture)
            if not package_key:
                fail("Could not find package {} for architecture {}".format(pkg_name, architecture))

            packages_to_extract[pkg_name] = package_key

            # Collect dependencies to process in next iteration
            package_info = packages_data[package_key]
            for dep_key in package_info.get("dependencies", []):
                if dep_key in packages_data:
                    dep_name = packages_data[dep_key]["name"]
                    if dep_name not in packages_to_extract and dep_name not in new_packages:
                        new_packages.append(dep_name)

        packages_to_process = new_packages
        if not packages_to_process:
            break  # No more dependencies to process

    # Extract all package data archives from shared deb_file_repo repositories.
    manifest = {}
    for pkg_name, package_key in packages_to_extract.items():
        if package_key not in package_data_archive_metadata:
            fail("No package data archive metadata label defined for package key '{}'".format(package_key))
        metadata_path = repository_ctx.path(package_data_archive_metadata[package_key])
        if not metadata_path.exists:
            fail("Package data archive metadata '{}' is missing for package key '{}'".format(metadata_path, package_key))
        data_archive_filename = repository_ctx.read(metadata_path).strip()
        if not data_archive_filename:
            fail("Package data archive metadata '{}' is empty for package key '{}'".format(metadata_path, package_key))

        data_archive_path = repository_ctx.path("{}/{}".format(
            _dirname(str(metadata_path)),
            data_archive_filename,
        ))
        if not data_archive_path.exists:
            fail("Package data archive '{}' is missing for package key '{}'".format(data_archive_path, package_key))

        extract_result = repository_ctx.execute([str(tar_tool), "-xf", str(data_archive_path), "-C", "."])
        if extract_result.return_code != 0:
            fail("Failed to extract package data archive for {}: {}".format(package_key, extract_result.stderr))

        extracted_files = _list_tar_files(repository_ctx, data_archive_path, str(tar_tool))
        manifest[pkg_name] = extracted_files

    # Fix symlinks in the sysroot
    _fix_sysroot_symlinks(repository_ctx)

    # Add additional files to the sysroot
    for dest_path, source_label in add_files.items():
        source_file = repository_ctx.path(source_label)

        # Create the destination directory if needed
        dest_dir = dest_path.rsplit("/", 1)[0] if "/" in dest_path else "."
        if dest_dir != ".":
            mkdir_result = repository_ctx.execute(["mkdir", "-p", dest_dir])
            if mkdir_result.return_code != 0:
                fail("Failed to create directory for file {}: {}".format(dest_path, mkdir_result.stderr))

        # Copy the file to the sysroot
        cp_result = repository_ctx.execute(["cp", str(source_file), dest_path])
        if cp_result.return_code != 0:
            fail("Failed to copy file {} to {}: {}".format(source_file, dest_path, cp_result.stderr))

        # Add to manifest
        if "added_files" not in manifest:
            manifest["added_files"] = []
        manifest["added_files"].append(dest_path)

    # Create the install manifest
    repository_ctx.file(
        "install_manifest.json",
        json.encode_indent(manifest),
        executable = False,
    )

    # Create the BUILD file - use provided build_file or default template
    if not build_file:
        build_file = Label("//aptprep/private:sysroot.BUILD.tpl")
    repository_ctx.template(
        "BUILD.bazel",
        build_file,
        substitutions = {
        },
    )
    if patch_binaries_enabled:
        patchelf_dirs = []
        substitutions = _patchelf_dir_substitutions(architecture)
        for path_template in repository_ctx.attr.patchelf_dirs:
            patchelf_dirs.append(_expand_patchelf_dir_template(path_template, substitutions))

        patch_binaries(
            repository_ctx,
            repository_ctx.which("busybox"),
            repository_ctx.which("patchelf"),
            architecture,
            patchelf_dirs = patchelf_dirs,
        )

aptprep_sysroot = repository_rule(
    implementation = _aptprep_sysroot_impl,
    attrs = {
        "packages_list": attr.string_list(mandatory = True, doc = "List of package names to include in sysroot"),
        "packages_data": attr.string(mandatory = True, doc = "JSON data of all packages from lockfile"),
        "package_data_archives": attr.string_keyed_label_dict(mandatory = True, doc = "Mapping from lockfile package keys to @repo//:data_archive_filename.txt labels."),
        "architecture": attr.string(mandatory = True, doc = "Target architecture"),
        "build_file": attr.label(doc = "Label of the BUILD file to use for this repository (optional)"),
        "patchelf_dirs": attr.string_list(
            default = DEFAULT_PATCHELF_DIRS,
            doc = "List of directories to patch. Supports placeholders: {arch}, {lib64}, {amd64}, {x86_64}, {x86_64-linux-gnu}.",
        ),
        "patch_binaries": attr.bool(default = True, doc = "Whether to run binary patching (rpath/interpreter fixups) on extracted files."),
        "patch_binaries_whitelist_regex": attr.string_list(default = [], doc = "Optional list of regex patterns. If non-empty, only files whose paths match at least one pattern are patched."),
        "patch_binaries_blacklist_regex": attr.string_list(default = [], doc = "Optional list of regex patterns. Files whose paths match any pattern are skipped, even if whitelisted."),
        "add_files": attr.string_keyed_label_dict(default = {}, doc = "Dictionary of additional files to add to sysroot. Keys are destination paths (relative to sysroot root), values are labels pointing to source files."),
        "extra_links": attr.string_dict(default = {}, doc = "Dictionary of extra symlinks to create in the sysroot. Keys are symlink paths (relative to sysroot root), values are symlink targets."),
    },
)
