"""Rule for generating APT Packages index file using aptprep toolchain."""

def _generate_packages_file_impl(ctx):
    """Implementation for generate_packages_file rule."""
    toolchain = ctx.toolchains["@rules_aptprep//aptprep:toolchain_type"]
    aptprep_info = toolchain.aptprepinfo

    lockfile = ctx.file.lockfile
    config = ctx.file.config if ctx.file.config else None
    output = ctx.outputs.out

    # Build command arguments
    args = ctx.actions.args()
    args.add("generate_packages_file_from_lockfile")
    args.add("--lockfile", lockfile)
    args.add("--output", output)
    if config:
        args.add("--config", config)

    # Get inputs
    inputs = [lockfile]
    if config:
        inputs.append(config)

    # Run aptprep to generate Packages file
    ctx.actions.run(
        executable = aptprep_info.target_tool_path,
        arguments = [args],
        inputs = depset(inputs),
        outputs = [output],
        tools = depset(aptprep_info.tool_files),
        mnemonic = "GeneratePackagesFile",
        progress_message = "Generating APT Packages index file",
    )

    return [DefaultInfo(files = depset([output]))]

generate_packages_file = rule(
    implementation = _generate_packages_file_impl,
    attrs = {
        "lockfile": attr.label(
            mandatory = True,
            allow_single_file = [".json"],
            doc = "The aptprep lockfile",
        ),
        "config": attr.label(
            mandatory = False,
            allow_single_file = [".yaml", ".yml"],
            doc = "The aptprep config file (optional)",
        ),
        "out": attr.output(
            mandatory = True,
            doc = "Output Packages file",
        ),
    },
    toolchains = ["@rules_aptprep//aptprep:toolchain_type"],
    doc = "Generates an APT Packages index file from an aptprep lockfile using the aptprep toolchain",
)
