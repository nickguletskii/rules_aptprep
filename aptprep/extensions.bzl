"""Module extension for aptprep lockfile integration and toolchain support."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//aptprep/private:deb_file_repo.bzl", "deb_file_repo")
load("//aptprep/private:packages_repo.bzl", "aptprep_fake_repo", "aptprep_main_repo", "generate_packages_mapping_with_prefix")
load("//aptprep/private:sysroot_repo.bzl", "aptprep_sysroot")
load(":repositories.bzl", "aptprep_register_toolchains")

# Define the tag class for packages lockfiles
_packages_tag = tag_class(attrs = {
    "config": attr.label(doc = "Label of the aptprep config file (optional, used to auto-generate lockfile)"),
    "lockfile": attr.label(mandatory = True, doc = "Label of the aptprep lockfile"),
    "repo_name": attr.string(mandatory = True, doc = "Name for the generated repository"),
    "dependency_blacklist": attr.string_list_dict(default = {}, doc = "Dictionary of per-package dependency blacklists. Keys are package names, values are lists of packages they should not depend on. Example: {'libgcc-s1': ['libc6']}"),
    "package_build_file_template": attr.label(default = "@@rules_aptprep+//aptprep/private:debian_package_build.tpl", doc = "Custom BUILD file content template for packages (optional, uses default if not provided). Template should include {package_name} placeholder."),
})

# Define the tag class for sysroot lockfiles
_sysroot_tag = tag_class(attrs = {
    "config": attr.label(doc = "Label of the aptprep config file (optional, used to auto-generate lockfile)"),
    "lockfile": attr.label(mandatory = True, doc = "Label of the aptprep lockfile"),
    "repo_name": attr.string(mandatory = True, doc = "Name for the generated repository"),
    "packages_list": attr.string_list(default = [], doc = "List of packages to include in sysroot (empty = all)"),
    "architecture": attr.string(default = "amd64", doc = "Target architecture for the sysroot"),
    "build_file": attr.label(doc = "Label of the BUILD file template to use for the sysroot repository"),
    "extra_links": attr.string_dict(default = {}, doc = "Dictionary of extra symlinks to create in the sysroot. Keys are symlink paths (relative to sysroot root), values are symlink targets."),
    "add_files": attr.string_keyed_label_dict(default = {}, doc = "Dictionary of additional files to add to sysroot. Keys are destination paths (relative to sysroot root), values are labels pointing to source files."),
    "patch_binaries": attr.bool(default = True, doc = "Whether to patch binaries in the extracted sysroot (rpath/interpreter fixups)."),
    "patch_binaries_whitelist_regex": attr.string_list(default = [], doc = "Optional list of regex patterns. If non-empty, only files matching at least one pattern are patched."),
    "patch_binaries_blacklist_regex": attr.string_list(default = [], doc = "Optional list of regex patterns. Files matching any pattern are skipped."),
    "package_build_file_template": attr.label(default = "@@rules_aptprep+//aptprep/private:debian_package_build.tpl", doc = "Custom BUILD file content template for packages (optional, uses default if not provided). Template should include {package_name} placeholder."),
})

# Define the tag class for aptprep toolchain
_toolchain_tag = tag_class(attrs = {
    "archive_url": attr.string(mandatory = True, doc = "URL of the aptprep binary archive"),
    "sha256": attr.string(mandatory = True, doc = "SHA256 hash of the archive"),
    "strip_prefix": attr.string(doc = "Directory prefix to strip from the archive"),
    "binary_name": attr.string(default = "aptprep", doc = "Name of the aptprep binary"),
})

def _aptprep_extension_impl(module_ctx):
    """Implementation function for the aptprep module extension.

    This function orchestrates the creation of:
    - Toolchain repositories
    - Package repositories from lockfiles
    - Sysroot repositories
    """

    # Process toolchain tags first
    for module in module_ctx.modules:
        for tag in module.tags.toolchain:
            archive_url = tag.archive_url
            sha256 = tag.sha256
            strip_prefix = getattr(tag, "strip_prefix", None)
            binary_name = getattr(tag, "binary_name", "aptprep")

            # Register the aptprep toolchain with clearer names
            aptprep_register_toolchains(
                name = "aptprep_binary_archive",
                url = archive_url,
                sha256 = sha256,
                strip_prefix = strip_prefix,
                binary_name = binary_name,
                register = False,  # Don't auto-register, let the user do it
                toolchains_repo_name = "aptprep_toolchains",
            )

    # Process all packages tags from all modules
    for module in module_ctx.modules:
        for tag in module.tags.packages:
            lockfile_label = tag.lockfile
            repo_name = tag.repo_name
            dependency_blacklist = tag.dependency_blacklist

            # Read the lockfile
            lockfile_path = module_ctx.path(lockfile_label)
            if not lockfile_path.exists:
                aptprep_fake_repo(
                    name = repo_name,
                    repo_name = repo_name,
                )
                continue
            lockfile_content = module_ctx.read(lockfile_path)

            # Parse lockfile using Bazel's json module
            lockfile_data = json.decode(lockfile_content)

            # Validate lockfile structure
            if "packages" not in lockfile_data:
                fail("Invalid lockfile: missing 'packages' field")

            packages = lockfile_data["packages"]

            # Create individual repositories for each package
            for package_key, package_info in packages.items():
                package_name = package_info["name"]
                package_version = package_info["version"]
                package_arch = package_info["architecture"]
                download_url = package_info["download_url"]
                digest_info = package_info.get("digest", {})

                # Create individual repository for this package
                pkg_repo_name = "{}__{}".format(repo_name, package_key)

                # Download .deb file without extracting using custom repository rule
                # Sanitize version to remove colons (invalid in Bazel target names)
                sanitized_version = package_version.replace(":", "_")
                deb_filename = "{}_{}_{}.deb".format(package_name, sanitized_version, package_arch)

                deb_file_repo(
                    name = pkg_repo_name,
                    url = download_url,
                    sha256 = digest_info.get("value", "") if digest_info.get("algorithm") == "SHA256" else "",
                    filename = deb_filename,
                )

            # Create main repository that provides the structured interface
            config_label = getattr(tag, "config", None)
            aptprep_main_repo(
                name = repo_name,
                repo_name = repo_name,
                packages_data = json.encode(packages),
                dependency_blacklist = dependency_blacklist,
                lockfile = lockfile_label,
                config = config_label,
            )

    # Process all sysroot tags from all modules
    for module in module_ctx.modules:
        for tag in module.tags.sysroot:
            lockfile_label = tag.lockfile
            repo_name = tag.repo_name
            packages_list = tag.packages_list
            architecture = tag.architecture
            build_file = getattr(tag, "build_file", None)
            extra_links = tag.extra_links
            add_files = tag.add_files
            patch_binaries = tag.patch_binaries
            patch_binaries_whitelist_regex = tag.patch_binaries_whitelist_regex
            patch_binaries_blacklist_regex = tag.patch_binaries_blacklist_regex
            package_build_file_template = module_ctx.read(tag.package_build_file_template)

            # Read the lockfile
            lockfile_path = module_ctx.path(lockfile_label)
            if not lockfile_path.exists:
                aptprep_fake_repo(
                    name = repo_name,
                    repo_name = repo_name,
                )
                continue
            lockfile_content = module_ctx.read(lockfile_path)

            # Parse lockfile using Bazel's json module
            lockfile_data = json.decode(lockfile_content)

            # Validate lockfile structure
            if "packages" not in lockfile_data:
                fail("Invalid lockfile: missing 'packages' field")

            packages = lockfile_data["packages"]

            # Create individual repositories for each package (same as packages, but tagged as sysroot)
            for package_key, package_info in packages.items():
                package_name = package_info["name"]
                download_url = package_info["download_url"]
                digest_info = package_info.get("digest", {})

                # Create individual repository for this package with sysroot prefix
                pkg_repo_name = "{}_sysroot_{}".format(repo_name, package_key)

                # Create http_archive for this package
                http_archive(
                    name = pkg_repo_name,
                    url = download_url,
                    sha256 = digest_info.get("value", "") if digest_info.get("algorithm") == "SHA256" else "",
                    build_file_content = package_build_file_template.format(package_name = package_name),
                )

            # Generate the packages mapping with sysroot-prefixed repository names
            sysroot_repo_prefix = repo_name + "_sysroot"
            mapping_data = generate_packages_mapping_with_prefix(packages, sysroot_repo_prefix)

            # If no packages_list specified, use all packages from the lockfile
            if not packages_list:
                seen = {}
                packages_list = []
                for info in packages.values():
                    pkg_name = info["name"]
                    if pkg_name not in seen:
                        seen[pkg_name] = True
                        packages_list.append(pkg_name)

            # Create the sysroot repository
            kwargs = {
                "name": repo_name,
                "packages_list": packages_list,
                "packages_mapping": mapping_data,
                "packages_data": json.encode(packages),
                "architecture": architecture,
                "extra_links": extra_links,
                "add_files": add_files,
                "patch_binaries": patch_binaries,
                "patch_binaries_whitelist_regex": patch_binaries_whitelist_regex,
                "patch_binaries_blacklist_regex": patch_binaries_blacklist_regex,
            }
            if build_file:
                kwargs["build_file"] = build_file
            aptprep_sysroot(**kwargs)

# Define the module extension
aptprep = module_extension(
    implementation = _aptprep_extension_impl,
    tag_classes = {
        "packages": _packages_tag,
        "sysroot": _sysroot_tag,
        "toolchain": _toolchain_tag,
    },
    doc = "Extension for importing aptprep lockfiles and registering aptprep toolchains",
)
