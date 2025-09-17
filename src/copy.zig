// TODO:
// - Edit clipboard via $EDITOR
// - $EDITOR update multiple items (maybe rebase like behavior with commands)
// - Use arena for lua
// - Use Lua for configuration
// - Default transforms
//    - Add Title Before Text
//    - Make plain text
//    - Make upper case
//    - Make lower case
//    - Capitalize words
//    - Make single line
//    - Remove empty lines
//    - Strip all whitespaces
//    - Trim surrounding whitespaces
//    - Prepend text
//    - Append text
//    - Paste Text as Files
//    - Paste Images as Files
//    - Separate Multiple Items
// - Split to copy, paste, list, search, edit, delete, replace

const std = @import("std");
const builtin = @import("builtin");

// third-party
const clipboard_lib = @import("clipboard");
const zlua = @import("zlua");
const sqlite = @import("sqlite");
const known_folders = @import("known_folders");

// local
const nclip_lib = @import("neoclipboard");

const Lua = zlua.Lua;

pub fn cmd(gpa: std.mem.Allocator, cmd_args: *const [][:0]u8, stdout: *std.Io.Writer, stdin: *std.Io.Reader, storage: *nclip_lib.Storage) !u8 {
    // // Prints to stderr, ignoring potential errors.
    // try nclip_lib.bufferedPrint();

    // var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    // defer arena_allocator.deinit();
    // const arena = arena_allocator.allocator();

    const cwd = std.fs.cwd();

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

    const args = cmd_args.*;
    const exe = args[0];
    var copied_anything = false;

    var args_num: usize = 1;

    while (args_num < args.len) {
        const arg = args[args_num];

        if (std.mem.eql(u8, arg, "-")) {
            copied_anything = true;
            try processStdIn(gpa, storage, stdin, stdout);
            return 0;
        } else if (std.mem.eql(u8, arg, "-t")) {
            // TODO: fix imports for lua files
            args_num += 1;
            const transform = args[args_num];

            const input = try stdin.allocRemaining(gpa, .unlimited);
            defer gpa.free(input);

            // Initialize the Lua vm
            var lua = try Lua.init(gpa);
            defer lua.deinit();

            // https://luascripts.com/lua-embed
            // https://piembsystech.com/integrating-lua-as-a-scripting-language-in-c-c-applications/
            // https://piembsystech.com/working-with-modules-and-packages-in-lua-programming/
            lua.openLibs();

            const lua_path = try std.fs.path.joinZ(gpa, &.{ config_path, "lua", "init.lua" });
            defer gpa.free(lua_path);
            try lua.doFile(lua_path);
            _ = try lua.getGlobal(transform);
            try lua.pushAny(input);
            try lua.protectedCall(.{ .args = 1, .results = 1 });

            const result = try lua.toString(1);

            try clipboard_lib.write(result);

            try stdout.writeAll(result);
            try stdout.flush();

            var current_clipboard = nclip_lib.ClipboardModel{ .body = sqlite.text(result), .timestamp = std.time.timestamp() };
            try storage.write(&current_clipboard);

            return 0;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage(exe);
        } else {
            const file = cwd.openFile(arg, .{}) catch |err| std.process.fatal("unable to open file: {t}\n", .{err});
            defer file.close();

            copied_anything = true;
            var file_reader = file.reader(&.{});
            const input = try file_reader.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(input);

            try clipboard_lib.write(input);

            try stdout.writeAll(input);
            try stdout.flush();

            var current_clipboard = nclip_lib.ClipboardModel{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
            try storage.write(&current_clipboard);
        }

        args_num += 1;
    }

    if (!copied_anything) {
        try processStdIn(gpa, storage, stdin, stdout);
        return 0;
    }
    return 1;
}

fn usage(exe: []const u8) !u8 {
    std.log.warn("Usage: {s} [FILE]...\n", .{exe});
    return error.Invalid;
}

fn processStdIn(gpa: std.mem.Allocator, storage: *nclip_lib.Storage, stdin: *std.Io.Reader, stdout: *std.Io.Writer) !void {
    const input = try stdin.allocRemaining(gpa, .unlimited);
    defer gpa.free(input);

    try clipboard_lib.write(input);

    try stdout.writeAll(input);
    try stdout.flush();

    var current_clipboard = nclip_lib.ClipboardModel{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
    try storage.write(&current_clipboard);
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
