"""Sysroot repository rule and tar utilities for aptprep extension."""

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

def _extract_sysroot_package(rctx, data_tar_path, tar_tool):
    """Extract a single package's data into the sysroot."""

    # Extract using tar
    cmd = [tar_tool, "-xf", str(data_tar_path)]
    result = rctx.execute(cmd)
    if result.return_code:
        fail("Failed to extract package {}: ({}, {}, {})".format(
            data_tar_path,
            result.return_code,
            result.stdout,
            result.stderr,
        ))

def _fix_sysroot_symlinks(rctx):
    """Fix symlinks in the sysroot to not reference absolute paths."""

    # Find all symlinks and fix them
    find_result = rctx.execute(["find", ".", "-type", "l"])
    if find_result.return_code == 0:
        for symlink_path in find_result.stdout.splitlines():
            # Get the target of the symlink
            readlink_result = rctx.execute(["readlink", symlink_path])
            if readlink_result.return_code == 0:
                target = readlink_result.stdout.strip()
                if target.startswith("/"):
                    # Absolute path, make it relative
                    rctx.execute(["rm", symlink_path])

                    # Calculate relative path from the symlink location
                    depth = symlink_path.count("/") - 1
                    relative_prefix = "/".join([".."] * depth)
                    new_target = relative_prefix + target
                    rctx.execute(["ln", "-s", new_target, symlink_path])

def _aptprep_sysroot_impl(repository_ctx):
    """Implementation for aptprep_sysroot repository rule."""
    packages_list = repository_ctx.attr.packages_list
    packages_mapping_json = repository_ctx.attr.packages_mapping
    packages_data_json = repository_ctx.attr.packages_data
    architecture = repository_ctx.attr.architecture
    extra_links = repository_ctx.attr.extra_links

    # Get tar tool
    tar_tool = "tar"
    result = repository_ctx.execute(["which", "tar"])
    if result.return_code != 0:
        tar_tool = "tar"  # Assume tar is available on the system

    # Parse the packages mapping and package data from JSON
    packages_mapping = json.decode(packages_mapping_json)
    packages_data = json.decode(packages_data_json)

    # Create sysroot directory structure
    repository_ctx.execute(["mkdir", "-p", "etc"])

    # Create extra links first if specified
    for link_from, link_to in extra_links.items():
        dir_path = link_from.rsplit("/", 1)[0] if "/" in link_from else "."
        repository_ctx.execute(["mkdir", "-p", dir_path])
        repository_ctx.execute(["ln", "-s", link_to, link_from])

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

            if pkg_name not in packages_mapping:
                fail("Package {} not found in packages_mapping".format(pkg_name))

            # Find the package key for this package name
            package_key = None
            for key, info in packages_data.items():
                if info["name"] == pkg_name and info["architecture"] == architecture:
                    package_key = key
                    break

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

    # Extract all packages
    manifest = {}
    for pkg_name, package_key in packages_to_extract.items():
        package_info = packages_data[package_key]
        download_url = package_info["download_url"]
        digest_info = package_info.get("digest", {})

        # Download the package
        sha256 = digest_info.get("value", "") if digest_info.get("algorithm") == "SHA256" else ""
        deb_filename = "package_{}.deb".format(pkg_name.replace("/", "_"))

        repository_ctx.download(
            url = download_url,
            output = deb_filename,
            sha256 = sha256 if sha256 else None,
        )

        # Create a temporary directory for extraction
        pkg_extract_dir = "pkg_{}".format(pkg_name.replace("/", "_"))
        repository_ctx.execute(["mkdir", "-p", pkg_extract_dir])

        # Extract the downloaded package - it's a .deb file
        # First, extract the deb file to get the data.tar.*
        deb_extract_result = repository_ctx.execute(
            ["ar", "x", "../{}".format(deb_filename)],
            working_directory = pkg_extract_dir,
        )
        if deb_extract_result.return_code != 0:
            fail("Failed to extract deb file {}: {}".format(deb_filename, deb_extract_result.stderr))

        # Find the data.tar.* file
        find_result = repository_ctx.execute(["find", pkg_extract_dir, "-name", "data.tar*", "-type", "f"])
        if find_result.return_code != 0:
            fail("Could not find data.tar* file in extracted deb")

        data_tar_files = find_result.stdout.strip().split("\n")
        if not data_tar_files or not data_tar_files[0]:
            fail("No data.tar* file found in extracted deb")

        data_tar_file = data_tar_files[0]

        # Extract the data archive (this extracts to the sysroot root)
        _extract_sysroot_package(repository_ctx, data_tar_file, tar_tool)

        # List the files extracted
        extracted_files = _list_tar_files(repository_ctx, data_tar_file, tar_tool)
        manifest[pkg_name] = extracted_files

        # Clean up the extracted files
        repository_ctx.execute(["rm", "-f", deb_filename])
        repository_ctx.execute(["rm", "-rf", pkg_extract_dir])

    # Fix symlinks in the sysroot
    _fix_sysroot_symlinks(repository_ctx)

    # Create the install manifest
    repository_ctx.file(
        "install_manifest.json",
        json.encode_indent(manifest),
        executable = False,
    )

    # Create a basic BUILD file using template
    repository_ctx.template(
        "BUILD.bazel",
        Label("//aptprep/private:sysroot.BUILD.tpl"),
    )

aptprep_sysroot = repository_rule(
    implementation = _aptprep_sysroot_impl,
    attrs = {
        "packages_list": attr.string_list(mandatory = True, doc = "List of package names to include in sysroot"),
        "packages_mapping": attr.string(mandatory = True, doc = "JSON mapping of package names to repository names"),
        "packages_data": attr.string(mandatory = True, doc = "JSON data of all packages from lockfile"),
        "architecture": attr.string(mandatory = True, doc = "Target architecture"),
        "fix_rpath_with_patchelf": attr.bool(default = False, doc = "Whether to fix RPATH with patchelf (TODO)"),
        "add_files": attr.string_keyed_label_dict(default = {}, doc = "Additional files to add to sysroot (TODO)"),
        "extra_links": attr.string_dict(default = {}, doc = "Extra symlinks to create"),
    },
)
