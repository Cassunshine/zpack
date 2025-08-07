const std = @import("std");
const fs = std.fs;

/// The main context for the Packer.
/// To use it, first create a bundle using `createBundle`, then call `addFile` and `addDir` on that bundle.
pub const PackerContext = struct {
    allocator: std.mem.Allocator,

    bundles: std.ArrayList(*Bundle),

    pub fn init(allocator: std.mem.Allocator) PackerContext {
        const val = PackerContext{
            .allocator = allocator,
            .bundles = std.ArrayList(*Bundle).init(allocator),
        };

        return val;
    }

    pub fn deinit(self: *PackerContext) void {
        for (self.bundles.items) |b| {
            b.deinit();
            self.allocator.destroy(b);
        }

        self.bundles.deinit();
    }

    pub fn createBundle(self: *PackerContext, name: []const u8) *Bundle {
        const val = self.allocator.create(Bundle) catch @panic("OOM");
        val.* = Bundle.init(self.allocator, name);

        self.bundles.append(val) catch @panic("OOM");
        return val;
    }

    pub const Bundle = struct {
        name: []const u8,

        files: std.ArrayList(FileEntry),
        dirs: std.ArrayList(DirEntry),

        filePredicates: std.ArrayList(FilePredicate),

        pub fn init(allocator: std.mem.Allocator, name: []const u8) Bundle {
            const bundle = Bundle{
                .name = name,
                .files = std.ArrayList(FileEntry).init(allocator),
                .dirs = std.ArrayList(DirEntry).init(allocator),
                .filePredicates = std.ArrayList(FilePredicate).init(allocator),
            };

            return bundle;
        }

        pub fn deinit(self: *Bundle) void {
            self.files.deinit();
            self.dirs.deinit();
            self.filePredicates.deinit();
        }

        /// Adds a file to the packer, packing it at a later point.
        pub fn addFile(self: *Bundle, source: []const u8, dest: []const u8) void {
            self.files.append(.{
                .source_file = source,
                .dest_file = dest,
            }) catch @panic("OOM");
        }

        /// Adds a directory to the packer, packing it at a later point.
        /// This will effectively add each file within a directory as packing targets.
        pub fn addDir(self: *Bundle, source: []const u8, dest: []const u8) void {
            self.dirs.append(.{
                .source_dir = source,
                .dest_dir = dest,
            }) catch @panic("OOM");
        }

        /// Adds a file to the packer, packing it at a later point.
        pub fn addFilePredicate(self: *Bundle, predicate: FilePredicate) void {
            self.filePredicates.append(predicate) catch @panic("OOM");
        }

        pub const DirEntry = struct {
            source_dir: []const u8,
            dest_dir: []const u8,
        };
        pub const FileEntry = struct {
            source_file: []const u8,
            dest_file: []const u8,
        };
    };
};

pub const FilePredicate = *const fn (path: []const u8, handle: fs.File) bool;
