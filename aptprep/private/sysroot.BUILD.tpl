"""Generated sysroot repository."""
load("@bazel_skylib//rules/directory:directory.bzl", "directory")

package(default_visibility = ["//visibility:public"])

alias(
    name = "manifest",
    actual = "install_manifest.json",
)

directory(
    name = "root",
    srcs = [":files"],
)

filegroup(
    name = "files",
    srcs = glob(["**/*"], exclude = ["usr/share/man/**"], allow_empty = True),
)

exports_files(
    srcs = glob(["**/*"], exclude = ["usr/share/man/**"], allow_empty = True),
)
