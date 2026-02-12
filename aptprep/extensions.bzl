"""Module extension for aptprep lockfile integration and toolchain support."""

load("//aptprep/private:deb_file_repo.bzl", "deb_file_repo")
load("//aptprep/private:packages_repo.bzl", "aptprep_fake_repo", "aptprep_main_repo")
load("//aptprep/private:sysroot_repo.bzl", "aptprep_sysroot")
load(":repositories.bzl", "aptprep_register_toolchains")

_lockfile_tag = tag_class(attrs = {
    "lockfile_name": attr.string(mandatory = True, doc = "Name used to resolve lockfile data in packages/sysroot tags."),
    "lockfile": attr.label(mandatory = True, doc = "Label of the aptprep lockfile."),
    "config": attr.label(doc = "Optional aptprep config label. Used when generating the Packages index file."),
    "deb_package_build_file_template": attr.label(default = "@@rules_aptprep+//aptprep/private:deb_package.BUILD.tpl", doc = "Template used by deb_file_repo to generate per-package BUILD files."),
})

_packages_tag = tag_class(attrs = {
    "repo_name": attr.string(mandatory = True, doc = "Name for the generated repository."),
    "lockfile_name": attr.string(mandatory = True, doc = "Name of aptprep.lockfile to use."),
    "dependency_blacklist": attr.string_list_dict(default = {}, doc = "Dictionary of per-package dependency blacklists. Keys are package names, values are lists of packages they should not depend on. Example: {'libgcc-s1': ['libc6']}."),
})

_sysroot_tag = tag_class(attrs = {
    "repo_name": attr.string(mandatory = True, doc = "Name for the generated repository."),
    "lockfile_name": attr.string(mandatory = True, doc = "Name of aptprep.lockfile to use."),
    "packages_list": attr.string_list(default = [], doc = "List of packages to include in sysroot (empty = all)."),
    "architecture": attr.string(default = "amd64", doc = "Target architecture for the sysroot."),
    "build_file": attr.label(doc = "Label of the BUILD file template to use for the sysroot repository."),
    "extra_links": attr.string_dict(default = {}, doc = "Dictionary of extra symlinks to create in the sysroot. Keys are symlink paths (relative to sysroot root), values are symlink targets."),
    "add_files": attr.string_keyed_label_dict(default = {}, doc = "Dictionary of additional files to add to sysroot. Keys are destination paths (relative to sysroot root), values are labels pointing to source files."),
    "patch_binaries": attr.bool(default = True, doc = "Whether to patch binaries in the extracted sysroot (rpath/interpreter fixups)."),
    "patch_binaries_whitelist_regex": attr.string_list(default = [], doc = "Optional list of regex patterns. If non-empty, only files matching at least one pattern are patched."),
    "patch_binaries_blacklist_regex": attr.string_list(default = [], doc = "Optional list of regex patterns. Files matching any pattern are skipped."),
})

_toolchain_tag = tag_class(attrs = {
    "archive_url": attr.string(mandatory = True, doc = "URL of the aptprep binary archive."),
    "sha256": attr.string(mandatory = True, doc = "SHA256 hash of the archive."),
    "strip_prefix": attr.string(doc = "Directory prefix to strip from the archive."),
    "binary_name": attr.string(default = "aptprep", doc = "Name of the aptprep binary."),
})

def _read_lockfile_packages(module_ctx, lockfile_label):
    """Read and validate lockfile packages; returns None if file is absent."""
    lockfile_path = module_ctx.path(lockfile_label)
    if not lockfile_path.exists:
        return None

    lockfile_content = module_ctx.read(lockfile_path)
    lockfile_data = json.decode(lockfile_content)
    if "packages" not in lockfile_data:
        fail("Invalid lockfile {}: missing 'packages' field".format(lockfile_label))

    return lockfile_data["packages"]

def _create_lockfile_package_repos(lockfile_repo_name, packages, build_template_content):
    """Create one deb_file_repo per package entry in lockfile."""
    package_data_archives = {}
    for package_key, package_info in packages.items():
        package_name = package_info["name"]
        package_version = package_info["version"]
        package_arch = package_info["architecture"]
        download_url = package_info["download_url"]
        digest_info = package_info.get("digest", {})
        digest_algorithm = digest_info.get("algorithm", "")
        if digest_algorithm != "SHA256":
            fail("Package '{}' has unsupported digest algorithm '{}'; only SHA256 is supported".format(package_key, digest_algorithm))
        sha256 = digest_info.get("value", "")
        if not sha256:
            fail("Package '{}' has SHA256 digest algorithm but no value".format(package_key))

        sanitized_version = package_version.replace(":", "_")
        deb_filename = "{}_{}_{}.deb".format(package_name, sanitized_version, package_arch)
        pkg_repo_name = "{}__{}".format(lockfile_repo_name, package_key)

        deb_file_repo(
            name = pkg_repo_name,
            url = download_url,
            sha256 = sha256,
            filename = deb_filename,
            build_file_content_template = build_template_content,
            package_name = package_name,
            package_key = package_key,
            package_version = package_version,
            package_architecture = package_arch,
        )
        package_data_archives[package_key] = Label("@@rules_aptprep++aptprep+{}//:data_archive_filename.txt".format(pkg_repo_name))

    return package_data_archives

def _lockfile_reuse_key(tag):
    return "{}::{}".format(tag.lockfile, tag.deb_package_build_file_template)

def _collect_lockfiles_for_module(module_ctx, module):
    """Collect lockfiles for one module and create per-package repos once."""
    lockfiles_by_name = {}
    shared_lockfiles = {}

    for tag in module.tags.lockfile:
        lockfile_name = tag.lockfile_name
        if lockfile_name in lockfiles_by_name:
            fail("Duplicate aptprep.lockfile(lockfile_name = '{}') in module '{}'".format(lockfile_name, module.name))

        packages = _read_lockfile_packages(module_ctx, tag.lockfile)
        if packages == None:
            lockfiles_by_name[lockfile_name] = struct(
                lockfile = tag.lockfile,
                config = getattr(tag, "config", None),
                packages = None,
                package_repo_prefix = lockfile_name,
                package_data_archives = {},
            )
            continue

        reuse_key = _lockfile_reuse_key(tag)
        if reuse_key in shared_lockfiles:
            shared = shared_lockfiles[reuse_key]
            package_repo_prefix = shared.package_repo_prefix
            package_data_archives = shared.package_data_archives
        else:
            build_template_content = module_ctx.read(tag.deb_package_build_file_template)
            package_data_archives = _create_lockfile_package_repos(
                lockfile_name,
                packages,
                build_template_content,
            )
            package_repo_prefix = lockfile_name
            shared_lockfiles[reuse_key] = struct(
                package_repo_prefix = package_repo_prefix,
                package_data_archives = package_data_archives,
            )

        lockfiles_by_name[lockfile_name] = struct(
            lockfile = tag.lockfile,
            config = getattr(tag, "config", None),
            packages = packages,
            package_repo_prefix = package_repo_prefix,
            package_data_archives = package_data_archives,
        )

    return lockfiles_by_name

def _get_lockfile_info(lockfiles_by_name, lockfile_name, tag_kind, repo_name):
    if lockfile_name not in lockfiles_by_name:
        available = sorted(lockfiles_by_name.keys())
        fail("aptprep.{}(repo_name = '{}', lockfile_name = '{}') has no matching aptprep.lockfile(lockfile_name = ...). Available lockfile_name values: {}".format(
            tag_kind,
            repo_name,
            lockfile_name,
            available,
        ))
    return lockfiles_by_name[lockfile_name]

def _aptprep_extension_impl(module_ctx):
    """Implementation function for the aptprep module extension."""

    for module in module_ctx.modules:
        for tag in module.tags.toolchain:
            aptprep_register_toolchains(
                name = "aptprep_binary_archive",
                url = tag.archive_url,
                sha256 = tag.sha256,
                strip_prefix = getattr(tag, "strip_prefix", None),
                binary_name = getattr(tag, "binary_name", "aptprep"),
                register = False,
                toolchains_repo_name = "aptprep_toolchains",
            )

    for module in module_ctx.modules:
        lockfiles_by_name = _collect_lockfiles_for_module(module_ctx, module)

        for tag in module.tags.packages:
            repo_name = tag.repo_name
            lockfile_info = _get_lockfile_info(lockfiles_by_name, tag.lockfile_name, "packages", repo_name)
            if lockfile_info.packages == None:
                aptprep_fake_repo(
                    name = repo_name,
                    repo_name = repo_name,
                )
                continue

            aptprep_main_repo(
                name = repo_name,
                repo_name = repo_name,
                package_repo_prefix = lockfile_info.package_repo_prefix,
                packages_data = json.encode(lockfile_info.packages),
                dependency_blacklist = tag.dependency_blacklist,
                lockfile = lockfile_info.lockfile,
                config = lockfile_info.config,
            )

        for tag in module.tags.sysroot:
            repo_name = tag.repo_name
            lockfile_info = _get_lockfile_info(lockfiles_by_name, tag.lockfile_name, "sysroot", repo_name)
            if lockfile_info.packages == None:
                aptprep_fake_repo(
                    name = repo_name,
                    repo_name = repo_name,
                )
                continue

            packages_list = tag.packages_list
            if not packages_list:
                seen = {}
                packages_list = []
                for info in lockfile_info.packages.values():
                    pkg_name = info["name"]
                    if pkg_name not in seen:
                        seen[pkg_name] = True
                        packages_list.append(pkg_name)

            kwargs = {
                "name": repo_name,
                "packages_list": packages_list,
                "packages_data": json.encode(lockfile_info.packages),
                "package_data_archives": lockfile_info.package_data_archives,
                "architecture": tag.architecture,
                "extra_links": tag.extra_links,
                "add_files": tag.add_files,
                "patch_binaries": tag.patch_binaries,
                "patch_binaries_whitelist_regex": tag.patch_binaries_whitelist_regex,
                "patch_binaries_blacklist_regex": tag.patch_binaries_blacklist_regex,
            }
            if getattr(tag, "build_file", None):
                kwargs["build_file"] = tag.build_file

            aptprep_sysroot(**kwargs)

aptprep = module_extension(
    implementation = _aptprep_extension_impl,
    tag_classes = {
        "lockfile": _lockfile_tag,
        "packages": _packages_tag,
        "sysroot": _sysroot_tag,
        "toolchain": _toolchain_tag,
    },
    doc = "Extension for importing aptprep lockfiles and registering aptprep toolchains.",
)
