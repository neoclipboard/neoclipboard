const std = @import("std");
const builtin = @import("builtin");

// third-party
const clipboard_lib = @import("clipboard");
const zlua = @import("zlua");
const sqlite = @import("sqlite");
const known_folders = @import("known_folders");

// local
const copy = @import("copy.zig");
const nclip_lib = @import("neoclipboard");

const Lua = zlua.Lua;

pub const known_folders_config: known_folders.KnownFolderConfig = .{
    .xdg_on_mac = true,
};

// copied from zig's src/main.zig:69
// This can be global since stdout is a singleton.
// TODO: We needed writer buffer only for `sendFileAll`, but now we do not use it anymore
// https://ziggit.dev/t/pr-24858-changed-sendfileall-and-now-it-always-requires-a-buffer-can-somebody-please-help-me-understand-why-this-ok/12046
var stdout_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !u8 {
    // // Prints to stderr, ignoring potential errors.
    // try nclip_lib.bufferedPrint();

    // copied from zig's src/main.zig
    const gpa, const is_debug = gpa: {
        switch (builtin.mode) {
            .Debug => {
                break :gpa .{ debug_allocator.allocator(), true };
            },
            else => {
                break :gpa .{ std.heap.page_allocator, false };
            },
        }
    };

    defer if (is_debug) {
        defer std.testing.expect(debug_allocator.deinit() == .ok) catch @panic("leak");
    };

    // var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    // defer arena_allocator.deinit();
    // const arena = arena_allocator.allocator();

    const args = std.process.argsAlloc(gpa) catch {
        std.debug.print("Failed to allocate args\n", .{});
        return 2;
    };
    defer std.process.argsFree(gpa, args);

    // // Get the real path of the current working directory
    // // https://github.com/ziglang/zig/issues/19353
    // const cwd_path = try cwd.realpathAlloc(gpa, ".");
    // defer gpa.free(cwd_path);
    //
    // // Join the cwd path with "db.sqlite"
    // const db_path = try std.fs.path.join(gpa, &[_][]const u8{ cwd_path, "db.sqlite" });
    // defer gpa.free(db_path);
    //
    // std.debug.print("Full path to db.sqlite: {s}\n", .{db_path});

    const data_path_dir = try known_folders.open(gpa, known_folders.KnownFolder.data, .{});

    _ = data_path_dir.?.access("nclip", .{}) catch {
        try data_path_dir.?.makeDir("nclip");
    };
    const data_path = try data_path_dir.?.realpathAlloc(gpa, "nclip");
    defer gpa.free(data_path);

    const config_path_dir = try known_folders.open(gpa, known_folders.KnownFolder.local_configuration, .{});

    _ = config_path_dir.?.access("nclip", .{}) catch {
        try config_path_dir.?.makeDir("nclip");
    };
    const config_path = try config_path_dir.?.realpathAlloc(gpa, "nclip");
    defer gpa.free(config_path);

    const db_path = try std.fs.path.joinZ(gpa, &.{ data_path, "db.sqlite" });
    // const db_path = try std.fs.path.join(gpa, &[_][]const u8{ data_path, "db.sqlite" });
    defer gpa.free(db_path);

    // std.debug.print("Full path to db.sqlite: {s}\n", .{db_path});

    const db = try sqlite.Database.open(.{ .path = db_path });
    defer db.close();

    var storage: nclip_lib.Storage = .init(&db);
    try storage.setup();

    const exe = args[0];
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    // NOTE: I am not sure why in zig they are using buffered stdin, empty buffer works fine as well
    var stdin_reader = std.fs.File.stdin().readerStreaming(&.{});
    const stdin = &stdin_reader.interface;

    const cmd = args[1];
    const cmd_args = args[2..];
    if (std.mem.eql(u8, cmd, "copy")) {
        _ = try copy.cmd(gpa, &cmd_args, stdout, stdin, &storage);
        return 0;
    } else if (std.mem.eql(u8, cmd, "paste")) {
    } else if (std.mem.startsWith(u8, cmd, "-")) {
        return usage(exe);
    } else {
        return usage(exe);
    }
    return 1;
}

fn usage(exe: []const u8) !u8 {
    std.log.warn("Usage: {s} [FILE]...\n", .{exe});
    return error.Invalid;
}

test {
    std.testing.refAllDeclsRecursive(@This());
}


// test "fuzz example" {
//     const Context = struct {
//         fn testOne(context: @This(), input: []const u8) anyerror!void {
//             _ = context;
//             // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
//             try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
//         }
//     };
//     try std.testing.fuzz(Context{}, Context.testOne, .{});
// }

