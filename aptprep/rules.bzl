def _aptprep_lockfile_impl(ctx):
    """Generate a lockfile from an aptprep config file using the aptprep binary."""
    config = ctx.file.config
    toolchain = ctx.toolchains["@rules_aptprep//aptprep:toolchain_type"]
    aptprepinfo = toolchain.aptprepinfo
    output_path = ctx.attr.output_path

    # Create a wrapper script that writes to the source root
    runner = ctx.actions.declare_file(ctx.label.name + ".sh")

    # Get the tool path from the toolchain and convert to runfiles path
    # target_tool_path may include "external/" prefix which we need to strip for runfiles
    tool_path = aptprepinfo.target_tool_path
    if tool_path.startswith("external/"):
        tool_path = tool_path[len("external/"):]

    # Expand the template with substitutions
    ctx.actions.expand_template(
        template = ctx.file._generate_lockfile_template,
        output = runner,
        substitutions = {
            "{CONFIG}": config.short_path,
            "{TOOL_PATH}": tool_path,
            "{OUTPUT_PATH}": output_path,
        },
    )

    return [
        DefaultInfo(
            executable = runner,
            runfiles = ctx.runfiles(
                files = [config] + aptprepinfo.tool_files,
            ),
        ),
    ]

_aptprep_lockfile = rule(
    implementation = _aptprep_lockfile_impl,
    attrs = {
        "config": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The aptprep config file to generate a lockfile from",
        ),
        "output_path": attr.string(
            default = "lockfile.json",
            doc = "Path relative to workspace root where the lockfile should be written",
        ),
        "_generate_lockfile_template": attr.label(
            allow_single_file = True,
            default = "//aptprep:generate_lockfile.sh.tpl",
            doc = "Template for the generate_lockfile shell script",
        ),
    },
    toolchains = ["@rules_aptprep//aptprep:toolchain_type"],
    executable = True,
    doc = "Generates an aptprep lockfile from a config file using the aptprep binary. Run with 'bazel run' to write to source root.",
)

def aptprep_lockfile(name, config, output_path = "lockfile.json", **kwargs):
    """Macro to generate an aptprep lockfile from a config file.

    Run with 'bazel run :<name>' to generate the lockfile in the source root.

    Args:
        name: Name of the rule
        config: The aptprep config file
        output_path: Path relative to workspace root where the lockfile should be written
        **kwargs: Additional arguments to pass to the rule
    """
    _aptprep_lockfile(
        name = name,
        config = config,
        output_path = output_path,
        **kwargs
    )
