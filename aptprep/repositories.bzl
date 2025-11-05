load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("//aptprep/private:toolchains_repo.bzl", "toolchains_repo")

# Repository rule for user-provided aptprep archives
def _aptprep_archive_repo_impl(repository_ctx):
    """Download and extract user-provided aptprep archive."""
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.url,
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
    )
    # Determine the binary name based on platform
    binary_name = repository_ctx.attr.binary_name
    if not binary_name:
        # Default binary names
        binary_name = "aptprep"

    # Create BUILD file using template
    repository_ctx.template(
        "BUILD.bazel",
        Label("//aptprep:aptprep_toolchain.BUILD.tpl"),
        substitutions = {
            "%{BINARY_NAME}": binary_name,
        },
    )

aptprep_archive_repo = repository_rule(
    implementation = _aptprep_archive_repo_impl,
    doc = "Download and setup user-provided aptprep binary archive",
    attrs = {
        "url": attr.string(mandatory = True, doc = "URL of the aptprep archive"),
        "sha256": attr.string(mandatory = True, doc = "SHA256 of the archive"),
        "strip_prefix": attr.string(doc = "Directory prefix to strip from the archive"),
        "binary_name": attr.string(default = "aptprep", doc = "Name of the aptprep binary"),
    },
)

# Function to register aptprep toolchains from user-provided archive
def aptprep_register_toolchains(name, url, sha256, strip_prefix = None, binary_name = "aptprep", register = True, toolchains_repo_name = None):
    """Register aptprep toolchains from a user-provided archive.

    Args:
        name: base name for the archive repository
        url: URL of the aptprep archive
        sha256: SHA256 hash of the archive
        strip_prefix: Directory prefix to strip from the archive
        binary_name: Name of the aptprep binary (default: "aptprep")
        register: whether to call through to native.register_toolchains.
            Should be True for WORKSPACE users, but false when used under bzlmod extension
        toolchains_repo_name: optional custom name for the toolchains repository.
            If not provided, defaults to "{name}_toolchains"
    """
    # Create the archive repository
    aptprep_archive_repo(
        name = name,
        url = url,
        sha256 = sha256,
        strip_prefix = strip_prefix,
        binary_name = binary_name,
    )

    # Determine the toolchains repository name
    toolchains_name = toolchains_repo_name if toolchains_repo_name else (name + "_toolchains")

    # Create toolchains repository that references the archive
    toolchains_repo(
        name = toolchains_name,
        user_repository_name = name,
    )

    if register:
        native.register_toolchains("@{}/:all".format(toolchains_name))
