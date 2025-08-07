const std = @import("std");

const app = @import("app");
const utils = @import("utils");
const zpack = @import("zpack");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // -- Read output directory from args -- //
    const args = std.process.argsAlloc(allocator) catch @panic("OOM");
    defer std.process.argsFree(allocator, args);

    if (args.len < 2)
        @panic("Too few arguments, expected path to place bundles.");

    const outputPath = args[1];
    var outputDir = try std.fs.cwd().openDir(outputPath, .{});
    defer outputDir.close();

    var bundlesOutputDir = try outputDir.makeOpenPath("bundles", .{});
    defer bundlesOutputDir.close();

    // -- Setup packer context -- //

    // Create packer context
    var packerContext = utils.PackerContext.init(allocator);
    defer packerContext.deinit();

    // -- Run app.pack -- //

    // Verify app.pack() is correct format
    {
        if (!std.meta.hasFn(app, "pack")) {
            std.debug.print("function 'pack' not found within pack.zig.\n", .{});
            return error.PackNotFunction;
        }
        try verifyAgainstTemplate(@TypeOf(app.pack));
    }

    // Try to run the app's packer function using context.
    try app.pack(&packerContext);

    // -- Create bundle files -- //

    for (packerContext.bundles.items) |bundle| {
        // -- Setup bundle -- //
        const bundleTrueName = try std.fmt.allocPrint(allocator, "{s}.zpack", .{bundle.name});
        defer allocator.free(bundleTrueName);

        const bundleFile = try bundlesOutputDir.createFile(bundleTrueName, .{});
        defer bundleFile.close();

        // -- Setup working directory for bundle -- //
        const bundleWorkspaceName = try std.fmt.allocPrint(allocator, "{s}_workspace", .{bundle.name});
        defer allocator.free(bundleWorkspaceName);
        const workspaceDir = try outputDir.makeOpenPath(bundleWorkspaceName, .{});

        // -- Write the bundle -- //
        try writeBundle(bundle, bundleFile.writer().any(), std.fs.cwd(), workspaceDir);
    }
}

/// Verifies that a function matches the `packTemplate` function signature.
fn verifyAgainstTemplate(t: type) !void {
    switch (@typeInfo(t)) {
        .@"fn" => |func| {
            const template = @typeInfo(@TypeOf(packTemplate)).@"fn";

            // Check arguments
            if (func.params.len != template.params.len) {
                std.debug.print("Argument count mismatch on pack() function, expected {d} args.\n", .{template.params.len});
                return error.PackFunctionMismatchArguments;
            }

            inline for (0..func.params.len) |i| {
                const p1 = func.params[i];
                const p2 = template.params[i];

                if (p1.type != p2.type) {
                    std.debug.print("Argument {d} mismatched on pack() function, found {s}, expected {s}.\n", .{ i, @typeName(p1.type.?), @typeName(p2.type.?) });
                    return error.PackFunctionMismatchArguments;
                }
            }

            if (func.return_type) |rType| {
                const rTypeInfo = @typeInfo(rType);
                switch (rTypeInfo) {
                    .error_union => |errorUnion| {
                        if (errorUnion.payload == void)
                            return;
                    },
                    else => {},
                }
            }

            std.debug.print("Pack function must have return type '!void' \n", .{});
            return error.PackFunctionMismatchArguments;
        },
        else => unreachable,
    }
}

fn packTemplate(_: *utils.PackerContext) !void {}

/// Writes `bundle` to the `bundle_writer` stream, using `root` as the place to search for files, and `workspace` to operate on the files.
/// This will process all the files in the bundle as well.
fn writeBundle(bundle: *utils.PackerContext.Bundle, bundle_writer: std.io.AnyWriter, root: std.fs.Dir, workspace: std.fs.Dir) !void {
    _ = workspace;

    const allocator = std.heap.smp_allocator;
    const filePathBuffer = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(filePathBuffer);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arenaAllocator = arena.allocator();

    // -- Find all files -- //

    var finalFileList = std.ArrayList(BundleFile).init(allocator);
    defer finalFileList.deinit();

    // Add all folders
    for (bundle.dirs.items) |dirEntry| {
        var dirHandle = try root.openDir(dirEntry.source_dir, .{ .iterate = true });
        defer dirHandle.close();

        // Walk directory.
        var walker = try dirHandle.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    // Add every file we find.
                    try finalFileList.append(.{
                        .source_path = try std.fs.path.join(arenaAllocator, &.{ dirEntry.source_dir, entry.path }),
                        .dest_path = try std.fs.path.join(arenaAllocator, &.{ dirEntry.dest_dir, entry.path }),
                    });
                },
                else => {},
            }
        }
    }

    // Add all files
    for (bundle.files.items) |fileEntry| {
        try finalFileList.append(.{
            .source_path = fileEntry.source_file,
            .dest_path = fileEntry.dest_file,
        });
    }

    // -- Process files -- //

    // Remove files that don't match predicates
    for (0..finalFileList.items.len) |index| {
        const i = finalFileList.items.len - 1 - index;
        const entry = finalFileList.items[i];

        var sourceHandle = try root.openFile(entry.source_path, .{});
        defer sourceHandle.close();
        const stats = try sourceHandle.stat();

        const keep = blk: {
            // If size is 0, omit file.
            if (stats.size == 0)
                break :blk false;

            // If file fails a predicate, omit file.
            for (bundle.filePredicates.items) |predicate| {
                if (!predicate(entry.source_path, sourceHandle))
                    break :blk false;
            }

            // Default to include.
            break :blk true;
        };

        if (!keep)
            _ = finalFileList.orderedRemove(i);
    }

    // Run file processors
    {
        //TODO - This!
    }

    // -- Write the bundle -- //

    // Always start with the magic
    try bundle_writer.writeAll(zpack.ZpackMagic);

    // Write header
    {
        // Write number of files.
        try bundle_writer.writeInt(u64, @intCast(finalFileList.items.len), .little);
        var fileDataLocation: u64 = 0;

        for (finalFileList.items) |entry| {
            const sourceStats = try root.statFile(entry.source_path);

            // Write path
            try bundle_writer.writeInt(u64, entry.dest_path.len, .little);
            try bundle_writer.writeAll(entry.dest_path);

            // Write offset and length
            try bundle_writer.writeInt(u64, fileDataLocation, .little);
            try bundle_writer.writeInt(u64, sourceStats.size, .little);
            fileDataLocation += sourceStats.size;
        }
    }

    // Write file data
    {
        for (finalFileList.items) |entry| {
            var handle = try root.openFile(entry.source_path, .{});
            defer handle.close();

            var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
            try fifo.pump(handle.reader(), bundle_writer);
        }
    }

    // TODO - Check portability on paths...
}

const BundleFile = struct {
    source_path: []const u8,
    dest_path: []const u8,
};
