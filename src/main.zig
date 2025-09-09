const std = @import("std");

// third-party
const clipboard_lib = @import("clipboard");
const zlua = @import("zlua");
const sqlite = @import("sqlite");

// local
const nclip_lib = @import("neoclipboard");

const Lua = zlua.Lua;

// copied from zig's src/main.zig:69
// This can be global since stdout is a singleton.
var stdout_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

const Clipboard = struct { body: sqlite.Text, timestamp: i64 };

pub fn main() !void {
    // // Prints to stderr, ignoring potential errors.
    // try nclip_lib.bufferedPrint();

    // TODO: Replace with GPA because we do not want to keep holding memory after clipboard redices
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const gpa = arena_instance.allocator();

    const args = std.process.argsAlloc(gpa) catch {
        std.debug.print("Failed to allocate args\n", .{});
        return;
    };
    defer std.process.argsFree(gpa, args);

    const cwd = std.fs.cwd();

    // Get the real path of the current working directory
    // https://github.com/ziglang/zig/issues/19353
    const cwd_path = try cwd.realpathAlloc(gpa, ".");
    defer gpa.free(cwd_path);

    // Join the cwd path with "db.sqlite"
    const db_path = try std.fs.path.join(gpa, &[_][]const u8{ cwd_path, "db.sqlite" });
    defer gpa.free(db_path);

    std.debug.print("Full path to db.sqlite: {s}\n", .{db_path});

    const db = try sqlite.Database.open(.{ .path = "db.sqlite" });
    defer db.close();

    try setupDb(&db);

    const exe = args[0];
    var catted_anything = false;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    // NOTE: I am not sure why in zig they are using buffered stdin, empty buffer works fine as well
    var stdin_reader = std.fs.File.stdin().readerStreaming(&.{});

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-")) {
            catted_anything = true;
            const stdin = &stdin_reader.interface;
            const input = try stdin.allocRemaining(gpa, .unlimited);
            defer gpa.free(input);

            try clipboard_lib.write(input);

            try stdout.writeAll(input);
            try stdout.flush();

            var current_clipboard = Clipboard{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
            try saveClipboard(&db, &current_clipboard);

        } else if (std.mem.eql(u8, arg, "-o")) {
            // copy xclip's option name for now
            try stdout.writeAll(clipboard_lib.read() catch "");
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-l")) {
            const stdin = &stdin_reader.interface;
            const input = try stdin.allocRemaining(gpa, .unlimited);
            defer gpa.free(input);

            // Initialize the Lua vm
            var lua = try Lua.init(gpa);
            defer lua.deinit();

            // https://luascripts.com/lua-embed
            // https://piembsystech.com/integrating-lua-as-a-scripting-language-in-c-c-applications/
            // https://piembsystech.com/working-with-modules-and-packages-in-lua-programming/
            lua.openLibs();

            try lua.doFile("lua/init.lua");
            _ = try lua.getGlobal("trim_upper");
            try lua.pushAny(input);
            try lua.protectedCall(.{ .args = 1, .results = 1 });

            const result = try lua.toString(1);

            try clipboard_lib.write(result);

            try stdout.writeAll(result);
            try stdout.flush();

            // TODO: save before transform, after transform, replace with transform
            var current_clipboard = Clipboard{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
            try saveClipboard(&db, &current_clipboard);

            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage(exe);
        } else {
            const file = cwd.openFile(arg, .{}) catch |err| std.process.fatal("unable to open file: {t}\n", .{err});
            defer file.close();

            catted_anything = true;
            var file_reader = file.reader(&.{});
            const input = try file_reader.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(input);

            try clipboard_lib.write(input);

            try stdout.writeAll(input);
            try stdout.flush();

            var current_clipboard = Clipboard{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
            try saveClipboard(&db, &current_clipboard);

        }
    }
    if (!catted_anything) {
        const stdin = &stdin_reader.interface;
        const input = try stdin.allocRemaining(gpa, .unlimited);
        defer gpa.free(input);

        try clipboard_lib.write(input);

        try stdout.writeAll(input);
        try stdout.flush();

        var current_clipboard = Clipboard{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
        try saveClipboard(&db, &current_clipboard);

    }

}

fn usage(exe: []const u8) !void {
    std.log.warn("Usage: {s} [FILE]...\n", .{exe});
    return error.Invalid;
}

fn setupDb(db: *const sqlite.Database) !void {
    std.debug.print("Setting up database\n", .{});
    try db.exec("CREATE TABLE IF NOT EXISTS clipboard (id INTEGER PRIMARY KEY, body TEXT, timestamp INTEGER)", .{});
}

fn saveClipboard(db: *const sqlite.Database, clipboard: *const Clipboard) !void {
    std.debug.print("Saving to clipboard: \"{s}\", at {d}\n", .{ clipboard.body.data, clipboard.timestamp });
    const insert = try db.prepare(Clipboard, void, "INSERT INTO clipboard VALUES (NULL, :body, :timestamp)");
    defer insert.finalize();
    try insert.exec(clipboard.*);
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
