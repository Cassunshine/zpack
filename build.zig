const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("zpack", .{
        .root_source_file = b.path("src/api/zpack.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// Behaves
pub fn pack(b: *std.Build, options: PackOptions) *std.Build.Step {
    _ = options;

    const zpackDependency = b.dependency("zpack", .{});

    // -- Set up the packer executable -- //

    const packUtils = b.createModule(.{
        .root_source_file = zpackDependency.path("src/packer/utils.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    // A module created using the source application's 'pack.zig' file.
    const appModule = b.createModule(.{
        .root_source_file = b.path("pack.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const appCheck = b.addCheckFile(b.path("pack.zig"), .{});

    appModule.addImport("zpacker", packUtils);
    appModule.addImport("zpack", zpackDependency.module("zpack"));

    // The exectuable that will pack the game assets.
    const packerExecutable = b.addExecutable(.{
        .name = "zpack-app",
        .root_source_file = zpackDependency.path("src/packer/zpacker.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    // Pass the source application's pack module as a dependency.
    packerExecutable.root_module.addImport("app", appModule);
    packerExecutable.root_module.addImport("utils", packUtils);
    packerExecutable.root_module.addImport("zpack", zpackDependency.module("zpack"));

    // Check that app module can build first.
    packerExecutable.step.dependOn(&appCheck.step);

    // -- Run the packer executable -- //

    var runPacker = b.addRunArtifact(packerExecutable);

    const packerOutput = runPacker.addOutputDirectoryArg("workspace");

    // -- Install output bundles to output folder -- //
    const installPackerOutput = b.addInstallDirectory(.{
        .source_dir = packerOutput.path(b, "bundles"),
        .install_dir = .{ .bin = {} },
        .install_subdir = "",
    });
    installPackerOutput.step.dependOn(&runPacker.step);

    // -- Finalize step dependencies -- //
    const step = b.step("Pack Assets", "Packs an asset folder");

    step.dependOn(&installPackerOutput.step);

    return step;
}

pub const PackOptions = struct {};
