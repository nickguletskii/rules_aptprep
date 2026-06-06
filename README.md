# Bazel rules for aptprep

Bazel rules for downloading Debian/APT package dependency trees and creating sysroots using aptprep.

## Features

- **Toolchain Extension**: Fetch and register aptprep binary from user-specified archives
- **Lockfile Extension**: Define named lockfiles and shared package repository templates
- **Packages Extension**: Import Debian package lists from named aptprep lockfiles
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

# Define a named lockfile
aptprep.lockfile(
    lockfile_name = "ubuntu_jammy",
    lockfile = "//:lockfile.json",
    config = "//:aptprep.yaml",
)

# Import Debian packages
aptprep.packages(
    repo_name = "my_packages",
    lockfile_name = "ubuntu_jammy",
)

# Create sysroot with specific packages and all dependencies
aptprep.sysroot(
    repo_name = "my_sysroot",
    lockfile_name = "ubuntu_jammy",
    packages_list = ["bash", "curl"],
    architecture = "amd64",
)

use_repo(aptprep, "aptprep_binary_archive", "aptprep_toolchains", "my_packages", "my_sysroot")
register_toolchains("@aptprep_toolchains//:all")
```

## Usage

For a complete working example, see [e2e/smoke/](./e2e/smoke/). For generating a
`rules_cc` C/C++ toolchain (native `linux/x86_64` + cross `linux/aarch64`) from
aptprep sysroots, see [docs/cc-toolchain.md](./docs/cc-toolchain.md) and the
runnable [e2e/cc/](./e2e/cc/) module.

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

### Lockfile Extension

Define a named lockfile and the default per-package BUILD template used by `deb_file_repo`:

```starlark
aptprep.lockfile(
    lockfile_name = "ubuntu_jammy",
    lockfile = "//:lockfile.json",
    config = "//:aptprep.yaml",  # Optional; used for @<packages_repo>//:Packages
    deb_package_build_file_template = "@rules_aptprep//aptprep/private:deb_package.BUILD.tpl",  # Optional
)
```

`aptprep.packages(lockfile_name = "...")` and `aptprep.sysroot(lockfile_name = "...")` resolve lockfile settings from `aptprep.lockfile(lockfile_name = "...")`.

Each package from the resolved lockfile is downloaded once into a shared per-package repository named:

- `@<package_repo_prefix>__<package_key>`

### Packages Extension

Import Debian packages:

```starlark
aptprep.packages(
    repo_name = "my_packages",
    lockfile_name = "ubuntu_jammy",
)
```

This creates a repository `@my_packages` containing the Debian packages specified in the lockfile, with structured access to each package's data and control archives.

### Sysroot Extension

Create a complete sysroot environment with all package dependencies:

```starlark
aptprep.sysroot(
    repo_name = "my_sysroot",
    lockfile_name = "ubuntu_jammy",
    packages_list = ["bash", "curl"],  # Root packages to include
    architecture = "amd64",  # Target architecture
    patch_binaries = True,  # Optional, default True
    patch_binaries_whitelist_regex = [  # Optional, default []
        "^usr/bin/.*$",
        "^lib/x86_64-linux-gnu/.*\\.so(\\..*)?$",
    ],
    patch_binaries_blacklist_regex = [  # Optional, default []
        "^usr/bin/python3(\\..*)?$",
    ],
)
```

This creates a repository `@my_sysroot` containing:

- All requested packages and their transitive dependencies
- Complete directory structure as if installed by dpkg
- Fixed symlinks (no absolute paths)
- Optional binary rpath patching controls (`patch_binaries`, whitelist/blacklist regex filters)
- Install manifest documenting what was extracted

### Repository and Target Specification

For each `aptprep.lockfile(lockfile_name = "<lockfile_name>", lockfile = <label>)`:

- Repositories:
  - `@<package_repo_prefix>__<package_key>` for every package in the lockfile.
- Targets in each `@<package_repo_prefix>__<package_key>` repository:
  - `:file`: alias to the raw downloaded `.deb`.
  - `:data`: alias to the package data archive extracted from the `.deb`.
  - `:control`: alias to the package control archive extracted from the `.deb`.
  - `.tar.xz`, `.tar.gz`, `.tar.bz2`, and `.tar` are preserved as-is.
  - `.tar.zst`/`.tar.zstd` is uncompressed to `.tar`, and aliases point at the uncompressed archive.

For each `aptprep.packages(repo_name = "<repo_name>", lockfile_name = "<lockfile_name>")`:

- Repository:
  - `@<repo_name>` (main package view).
- Top-level targets in `@<repo_name>`:
  - `:all_debs`: filegroup of all `//<package_name>/<architecture>:deb`.
  - `:Packages`: generated package index (only when `config` is set on the referenced lockfile).
- Per package+architecture package targets in `@<repo_name>//<package_name>/<architecture>`:
  - `:deb`: alias to `@<package_repo_prefix>__<package_key>//:file`.
  - `:data`: alias to `@<package_repo_prefix>__<package_key>//:data`.
  - `:control`: alias to `@<package_repo_prefix>__<package_key>//:control`.
  - `:<architecture>`: filegroup containing `:data` plus dependency `:<dep_architecture>` targets.

For each `aptprep.sysroot(repo_name = "<repo_name>", lockfile_name = "<lockfile_name>", ...)`:

- Repository:
  - `@<repo_name>` (materialized sysroot).
- Targets in `@<repo_name>`:
  - Targets from the selected sysroot BUILD template (default: `@rules_aptprep//aptprep/private:sysroot.BUILD.tpl`).
  - `install_manifest.json` file in the repository root listing extracted files per package.
- Behavior:
  - Sysroot extraction uses shared per-package archive files produced by the package repos, so each package download is shared across `packages` and `sysroot` for lockfiles with the same `lockfile` label and deb package template.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup.
