"""Module extension for aptprep lockfile integration and toolchain support."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//aptprep/private:packages_repo.bzl", "aptprep_fake_repo", "aptprep_main_repo", "generate_packages_mapping_with_prefix")
load("//aptprep/private:sysroot_repo.bzl", "aptprep_sysroot")
load(":repositories.bzl", "aptprep_register_toolchains")

# Template for Debian package repository in extension
_DEBIAN_PACKAGE_BUILD_TEMPLATE = """\"\"\"Debian package repository for {package_name}.\"\"\"

filegroup(
    name = "data",
    srcs = glob(["data.tar.*"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "control",
    srcs = glob(["control.tar.*"]),
    visibility = ["//visibility:public"],
)
"""

# Template for Debian package repository in sysroot extension
_DEBIAN_PACKAGE_SYSROOT_BUILD_TEMPLATE = """\"\"\"Debian package repository for sysroot {package_name}.\"\"\"

filegroup(
    name = "data",
    srcs = glob(["data.tar.*"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "control",
    srcs = glob(["control.tar.*"]),
    visibility = ["//visibility:public"],
)
"""

# Define the tag class for packages lockfiles
_packages_tag = tag_class(attrs = {
    "config": attr.label(doc = "Label of the aptprep config file (optional, used to auto-generate lockfile)"),
    "lockfile": attr.label(mandatory = True, doc = "Label of the aptprep lockfile"),
    "repo_name": attr.string(mandatory = True, doc = "Name for the generated repository"),
})

# Define the tag class for sysroot lockfiles
_sysroot_tag = tag_class(attrs = {
    "config": attr.label(doc = "Label of the aptprep config file (optional, used to auto-generate lockfile)"),
    "lockfile": attr.label(mandatory = True, doc = "Label of the aptprep lockfile"),
    "repo_name": attr.string(mandatory = True, doc = "Name for the generated repository"),
    "packages_list": attr.string_list(default = [], doc = "List of packages to include in sysroot (empty = all)"),
    "architecture": attr.string(default = "amd64", doc = "Target architecture for the sysroot"),
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
                download_url = package_info["download_url"]
                digest_info = package_info.get("digest", {})

                # Create individual repository for this package
                pkg_repo_name = "{}__{}".format(repo_name, package_key)

                # Create http_archive for this package
                http_archive(
                    name = pkg_repo_name,
                    url = download_url,
                    sha256 = digest_info.get("value", "") if digest_info.get("algorithm") == "SHA256" else "",
                    build_file_content = _DEBIAN_PACKAGE_BUILD_TEMPLATE.format(package_name = package_name),
                )

            # Create main repository that provides the structured interface
            aptprep_main_repo(
                name = repo_name,
                repo_name = repo_name,
                packages_data = json.encode(packages),
            )

    # Process all sysroot tags from all modules
    for module in module_ctx.modules:
        for tag in module.tags.sysroot:
            lockfile_label = tag.lockfile
            repo_name = tag.repo_name
            packages_list = tag.packages_list
            architecture = tag.architecture

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
                    build_file_content = _DEBIAN_PACKAGE_SYSROOT_BUILD_TEMPLATE.format(package_name = package_name),
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
            aptprep_sysroot(
                name = repo_name,
                packages_list = packages_list,
                packages_mapping = mapping_data,
                packages_data = json.encode(packages),
                architecture = architecture,
            )

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
