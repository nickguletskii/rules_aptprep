# Bazel rules for aptprep

Bazel rules for downloading Debian/APT package dependency trees and creating sysroots using aptprep.

## Features

- **Toolchain Extension**: Fetch and register aptprep binary from user-specified archives
- **Packages Extension**: Import Debian package lists from aptprep lockfiles
- **Sysroot Extension**: Create complete sysroot environments with all package dependencies
- BZLMOD-only design (no WORKSPACE support)

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_aptprep", version = "0.0.0")

aptprep = use_extension("@rules_aptprep//aptprep:extensions.bzl", "aptprep")

# Register aptprep binary toolchain
aptprep.toolchain(
    archive_url = "https://github.com/nickguletskii/aptprep/releases/download/v0.1.2/aptprep_linux_x86_64.tar",
    sha256 = "4d1b992540fb9856561f101d8ef4a54b7e74529a65171468f7940933ad0a0e52",
)

# Import Debian packages from lockfile
aptprep.packages(
    lockfile = "//:lockfile.json",
    repo_name = "my_packages",
)

# Create sysroot with specific packages and all dependencies
aptprep.sysroot(
    lockfile = "//:lockfile.json",
    repo_name = "my_sysroot",
    packages_list = ["bash", "curl"],
    architecture = "amd64",
)

use_repo(aptprep, "aptprep_binary_archive", "aptprep_toolchains", "my_packages", "my_sysroot")
register_toolchains("@aptprep_toolchains//:all")
```

## Usage

For a complete working example, see [e2e/smoke/](./e2e/smoke/).

### Toolchain Extension

Register the aptprep binary toolchain:

```starlark
aptprep.toolchain(
    archive_url = "https://github.com/nickguletskii/aptprep/releases/download/v0.1.2/aptprep_linux_x86_64.tar",
    sha256 = "...",  # Provide SHA256 hash of the archive
    strip_prefix = "aptprep",  # Optional: directory prefix to strip
    binary_name = "aptprep",  # Optional: binary name (default: "aptprep")
)
```

This creates two repositories:

- `aptprep_binary_archive`: Contains the downloaded aptprep binary
- `aptprep_toolchains`: Contains toolchain registration targets for Bazel

### Packages Extension

Import Debian packages from an aptprep lockfile:

```starlark
aptprep.packages(
    lockfile = "//:lockfile.json",
    repo_name = "my_packages",
    config = "//:aptprep.yaml",
)
```

This creates a repository `@my_packages` containing the Debian packages specified in the lockfile, with structured access to each package's data and control archives.

### Sysroot Extension

Create a complete sysroot environment with all package dependencies:

```starlark
aptprep.sysroot(
    lockfile = "//:lockfile.json",
    repo_name = "my_sysroot",
    packages_list = ["bash", "curl"],  # Root packages to include
    architecture = "amd64",  # Target architecture
    config = "//:aptprep.yaml",
```

This creates a repository `@my_sysroot` containing:

- All requested packages and their transitive dependencies
- Complete directory structure as if installed by dpkg
- Fixed symlinks (no absolute paths)
- Install manifest documenting what was extracted

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup.
