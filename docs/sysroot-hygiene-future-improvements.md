# Sysroot Hygiene Future Improvements

`aptprep.sysroot` currently relies on its symlink normalization pass to make
extracted Debian package payloads safe for Bazel to traverse as an external
repository. This pass rewrites absolute symlinks into relative symlinks and
removes symlinks that would create loops.

The implementation must fail loudly if required host tools such as `find` or
`readlink` are unavailable. Silent fallback leaves absolute package symlinks in
place, which can make Bazel recursive globs fail when the symlink points at
root-owned or unreadable paths such as `/etc/ssl/private`.

Future improvements worth considering:

- Add an explicit sysroot hygiene report to `install_manifest.json`, recording
  symlinks rewritten and entries removed during materialization.
- Normalize unreadable regular files and directories by applying readable and
  searchable permissions for the repository user when that preserves useful
  sysroot contents.
- Add a strict mode that fails on any unreadable or non-traversable extracted
  entry instead of changing permissions.
- Add a dedicated fixture repository that creates absolute symlinks, loop
  symlinks, and root-only directories, then verifies that `@repo//:files`
  remains loadable.
- Consider generating `:files` from a sanitized manifest instead of relying on
  broad recursive globs in generated sysroot BUILD files.
