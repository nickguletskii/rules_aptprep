"""Test-only comparison of sysroots produced by both archive extractors."""

def _comparison_repo_impl(rctx):
    tar_root = rctx.path(rctx.attr.tar_manifest).dirname
    bazel_root = rctx.path(rctx.attr.bazel_manifest).dirname
    script = rctx.path(rctx.attr.compare_script)
    bash = rctx.which("bash")
    if not bash:
        fail("The extractor comparison requires bash")

    result = rctx.execute([
        bash,
        script,
        tar_root,
        bazel_root,
        rctx.path("tar.tree"),
        rctx.path("bazel.tree"),
    ])
    if result.return_code != 0:
        fail("GNU tar and Bazel extraction produced different sysroots:\n{}{}".format(
            result.stdout,
            result.stderr,
        ))

    rctx.file("result.txt", "GNU tar and Bazel extraction trees match\n")
    rctx.file("BUILD.bazel", "exports_files([\"result.txt\"])\n")

_comparison_repo = repository_rule(
    implementation = _comparison_repo_impl,
    attrs = {
        "bazel_manifest": attr.label(mandatory = True),
        "compare_script": attr.label(mandatory = True),
        "tar_manifest": attr.label(mandatory = True),
    },
)

_comparison_tag = tag_class(attrs = {
    "bazel_manifest": attr.label(mandatory = True),
    "name": attr.string(mandatory = True),
    "tar_manifest": attr.label(mandatory = True),
})

def _extraction_comparison_impl(module_ctx):
    root = module_ctx.modules[0]
    for tag in root.tags.compare:
        _comparison_repo(
            name = tag.name,
            bazel_manifest = tag.bazel_manifest,
            compare_script = "//:compare_extracted_trees.sh",
            tar_manifest = tag.tar_manifest,
        )

extraction_comparison = module_extension(
    implementation = _extraction_comparison_impl,
    tag_classes = {"compare": _comparison_tag},
)
