# cc toolchain e2e

This e2e exercises the `aptprep.cc_toolchain(...)` extension tag from an
end-user's perspective. It builds a C++ library and binary:

- natively for `linux/x86_64` (compiler sysroot == target sysroot), and
- cross-compiled for `linux/aarch64` (host clang from the amd64 compiler
  sysroot targeting the arm64 sysroot), via an explicit platform transition.

It then asserts statically (no execution, no qemu) that:

1. both arches build and link (`build_both`),
2. the aarch64 binary is a real `AArch64` ELF (`verify_aarch64`), and
3. the `__DATE__`/`__TIME__`/`__TIMESTAMP__` redaction landed in the binary
   (`verify_reproducibility`).

The toolchain packages (clang/lld/llvm + libc/libstdc++/gcc + binutils) are
pinned in `lockfile.json` from a dated Ubuntu 24.04 (noble) snapshot. Real debs
are downloaded at test time, as in `e2e/smoke`.

It is also used by the presubmit check for the Bazel Central Registry.

## Regenerating the lockfile

```sh
bazel run //:generate_lockfile
```
