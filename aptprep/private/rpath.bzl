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
    candidates = _list_files(
        rctx,
        busybox,
        "lib64/",
        "-name",
        "ld-linux-{}.so*".format(arch.replace("_", "-")),
    )
    for path in sorted(candidates, reverse = True):
        return str(rctx.path(path).realpath)
    return None

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

def patch_binaries(rctx, busybox, patchelf, arch):
    """Patches ELF binaries in the sysroot with correct RPATH and interpreter.

    Args:
        rctx: Repository context
        busybox: Path to busybox binary
        patchelf: Path to patchelf binary
        arch: Target architecture
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

    for directory in rctx.attr.patchelf_dirs:
        for path in _list_files(rctx, busybox, directory.format(arch = arch), "-maxdepth", "1"):
            realpath = str(rctx.path(path).realpath).removeprefix(pwd)
            if realpath not in seen and not any([realpath.endswith(e) for e in (".o", ".a")]) and _should_patch_binary(rctx, busybox, realpath):
                _fixup_rpath(rctx, patchelf, realpath, lib_paths)
                if interpreter_path != None:
                    _fixup_interpreter(rctx, patchelf, realpath, interpreter_path)
                seen.add(realpath)
