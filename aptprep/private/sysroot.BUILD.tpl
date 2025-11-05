"""Generated sysroot repository."""

filegroup(
    name = "sysroot",
    srcs = glob(["**/*"], exclude=["install_manifest.json"]),
    visibility = ["//visibility:public"],
)
