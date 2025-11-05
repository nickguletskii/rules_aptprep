"""Debian package repository."""

filegroup(
    name = "data",
    srcs = glob(["data.tar.*"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "control",
    srcs = glob(["control.tar.*"]),
    visibility = ["//visibility:public"],
)
