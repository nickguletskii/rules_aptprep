#
#    Copyright [yyyy] [name of copyright owner]
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
#  Source: https://github.com/lukasoyen/bazel_linux_packages/blob/a15e63f975ec94be83594c68c5df15981bc6931e/apt/private/deb_install.bzl
#

"""Utilities for patching ELF binaries in sysroots with correct RPATH and interpreter."""

_DYNAMIC_LINKER_ARCH_BY_DEBIAN_ARCH = {
    "amd64": "x86-64",
}

# Multiarch dir per Debian arch. Mirrors the map in sysroot_repo.bzl; kept local
# here to avoid an import cycle (sysroot_repo.bzl imports this module). Used to
# locate the dynamic loader in usr-merged sysroots that have no top-level
# `lib64/` (the loader instead lives under `usr/lib/<multiarch>/`).
_MULTIARCH_DIR_BY_DEBIAN_ARCH = {
    "amd64": "x86_64-linux-gnu",
    "arm64": "aarch64-linux-gnu",
    "armhf": "arm-linux-gnueabihf",
    "i386": "i386-linux-gnu",
    "ppc64el": "powerpc64le-linux-gnu",
    "s390x": "s390x-linux-gnu",
}

def _list_files(rctx, busybox, directory = ".", *args):
    if not rctx.path(directory).exists:
        return []
    cmd = [busybox, "find", "-L", directory, "-type", "f"] + list(args)
    result = rctx.execute(cmd)
    if result.return_code:
        fail("Failed to list files {} ({}, {}, {})".format(
            " ".join(cmd),
            result.return_code,
            result.stdout,
            result.stderr,
        ))
    return result.stdout.splitlines()

def _read_ld_so_conf(rctx, path):
    result = []
    for line in rctx.read(path).splitlines():
        if not line.startswith("#"):
            result.append(line.strip())
    return result

def _fixup_rpath(rctx, patchelf, path, lib_paths):
    # The levels we need to travers up from $ORIGIN.
    levels = "/".join([".." for _ in range(len(path.split("/")) - 1)])
    rpath = ":".join(["$ORIGIN/{}{}".format(levels, lib) for lib in lib_paths])

    cmd = [patchelf, "--add-rpath", rpath, path]
    result = rctx.execute(cmd)
    if result.return_code:
        if "patchelf: not an ELF executable" in result.stderr:
            return
        if "patchelf: wrong ELF type" in result.stderr:
            return
        fail("Failed to add RPATH: {} ({}, {}, {})".format(
            " ".join(cmd),
            result.return_code,
            result.stdout,
            result.stderr,
        ))

def _fixup_interpreter(rctx, patchelf, path, interpreter):
    cmd = [patchelf, "--set-interpreter", interpreter, path]
    result = rctx.execute(cmd)
    if result.return_code:
        if "patchelf: not an ELF executable" in result.stderr:
            return
        if "patchelf: cannot find section '.interp'" in result.stderr:
            return
        if "patchelf: wrong ELF type" in result.stderr:
            return
        fail("Failed to set interpreter: {} ({}, {}, {})".format(
            " ".join(cmd),
            result.return_code,
            result.stdout,
            result.stderr,
        ))

def _find_interpreter(rctx, busybox, arch):
    linker_arch = _DYNAMIC_LINKER_ARCH_BY_DEBIAN_ARCH.get(arch, arch).replace("_", "-")
    name_glob = "ld-linux-{}.so*".format(linker_arch)

    # Search the canonical loader locations in priority order. Classic layouts
    # ship the loader in top-level `lib64/`/`lib/`; usr-merged sysroots (no
    # top-level lib dirs — everything under `usr/`) ship it under the multiarch
    # dir, so include `usr/lib/<multiarch>/` and `lib/<multiarch>/` too.
    multiarch = _MULTIARCH_DIR_BY_DEBIAN_ARCH.get(arch)
    search_dirs = ["lib64/", "lib/"]
    if multiarch:
        search_dirs.extend([
            "usr/lib/{}/".format(multiarch),
            "lib/{}/".format(multiarch),
        ])

    for directory in search_dirs:
        candidates = _list_files(
            rctx,
            busybox,
            directory,
            "-maxdepth",
            "1",
            "-name",
            name_glob,
        )
        for path in sorted(candidates, reverse = True):
            return str(rctx.path(path).realpath)
    return None

def _discover_llvm_bin_dirs(rctx):
    """Find `usr/lib/llvm-<NN>/bin` dirs holding clang/lld/llvm executables.

    These executables ship with the stock distro interpreter (the host loader
    path) and are not covered by the static `patchelf_dirs` because their
    `llvm-<NN>` version component is dynamic. We return them with a trailing `/`
    so the caller scans them (`-maxdepth 1`) like any other patch dir.
    """
    base = rctx.path("usr/lib")
    if not base.exists:
        return []
    dirs = []
    for entry in base.readdir():
        if entry.basename.startswith("llvm-"):
            bin_dir = entry.get_child("bin")
            if bin_dir.exists:
                dirs.append("usr/lib/" + entry.basename + "/bin/")
    return dirs

def _matches_regex(rctx, busybox, path, pattern):
    cmd = [
        busybox,
        "sh",
        "-c",
        "printf '%s\\n' \"$1\" | grep -E -q -- \"$2\"",
        "sh",
        path,
        pattern,
    ]
    result = rctx.execute(cmd)
    if result.return_code == 0:
        return True
    if result.return_code == 1:
        return False
    fail("Failed to evaluate regex ({}, {}, {}, {})".format(
        " ".join(cmd),
        result.return_code,
        result.stdout,
        result.stderr,
    ))

def _matches_any_regex(rctx, busybox, path, patterns):
    for pattern in patterns:
        if _matches_regex(rctx, busybox, path, pattern):
            return True
    return False

def _should_patch_binary(rctx, busybox, path):
    whitelist = rctx.attr.patch_binaries_whitelist_regex
    blacklist = rctx.attr.patch_binaries_blacklist_regex

    if whitelist and not _matches_any_regex(rctx, busybox, path, whitelist):
        return False
    if blacklist and _matches_any_regex(rctx, busybox, path, blacklist):
        return False
    return True

def patch_binaries(rctx, busybox, patchelf, arch, patchelf_dirs = None):
    """Patches ELF binaries in the sysroot with correct RPATH and interpreter.

    Args:
        rctx: Repository context
        busybox: Path to busybox binary
        patchelf: Path to patchelf binary
        arch: Target architecture
        patchelf_dirs: List of directories to scan for binaries/libraries to patch.
    """
    if not busybox:
        fail("busybox is required when patch_binaries is enabled")
    if not patchelf:
        fail("patchelf is required when patch_binaries is enabled")

    rctx.report_progress("Fixing executable and libraries")
    pwd = str(rctx.path(".").realpath) + "/"

    lib_paths = []
    for path in sorted(_list_files(rctx, busybox, "etc/ld.so.conf.d/")):
        lib_paths.extend(_read_ld_so_conf(rctx, path))

    seen = set()

    interpreter_path = None
    interpreter = _find_interpreter(rctx, busybox, arch)
    if interpreter != None:
        # We don't want to rpath patch the ld*.so
        seen.add(interpreter.removeprefix(pwd))
        interpreter_path = interpreter

    if patchelf_dirs == None:
        patchelf_dirs = rctx.attr.patchelf_dirs

    # Auto-discover compiler-toolchain tool dirs that carry executables needing
    # an interpreter rewrite but are NOT covered by the static patchelf_dirs
    # (their version component is dynamic), notably the clang/llvm bin dir
    # `usr/lib/llvm-<NN>/bin/`. Without rewriting clang's interpreter to the
    # sysroot loader, a host loader would load the sysroot libc and fail with a
    # GLIBC_PRIVATE symbol mismatch.
    patchelf_dirs = list(patchelf_dirs) + _discover_llvm_bin_dirs(rctx)

    for directory in patchelf_dirs:
        for path in _list_files(rctx, busybox, directory, "-maxdepth", "1"):
            realpath = str(rctx.path(path).realpath).removeprefix(pwd)
            if realpath not in seen and not any([realpath.endswith(e) for e in (".o", ".a")]) and _should_patch_binary(rctx, busybox, realpath):
                _fixup_rpath(rctx, patchelf, realpath, lib_paths)
                if interpreter_path != None:
                    _fixup_interpreter(rctx, patchelf, realpath, interpreter_path)
                seen.add(realpath)
