"""Debian package repository for {package_name}."""
data_zst = glob(["data.tar.zst"])
data_plain = glob(
    ["data.tar.*"],
    exclude = ["data.tar.zst"],
)

# If a .zst file exists, uncompress it
genrule(
    name = "data_unzstd",
    srcs = data_zst,
    outs = ["data.tar"],
    cmd = """
      if [ -n "$(SRCS)" ]; then
        unzstd -f $(SRCS) -o $@
      else
        # Should never happen, but Bazel requires a command
        touch $@
      fi
    """,
)

# Choose output: prefer unzstd output if .zst exists,
# otherwise the plain archive if present.
filegroup(
    name = "data",
    srcs = (["data_unzstd"] if data_zst else data_plain),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "control",
    srcs = glob(["control.tar.*"]),
    visibility = ["//visibility:public"],
)
