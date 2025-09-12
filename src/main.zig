const std = @import("std");
const builtin = @import("builtin");

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

const ClipboardModel = struct { body: sqlite.Text, timestamp: i64 };

const Clipboard = struct { body: []u8, timestamp: i64 };

const Storage = struct {
    const Self = @This();

    db: sqlite.Database,

    pub fn init() Self {
        return .{
            .db = undefined,
        };
    }

    pub fn setup(self: *Self, gpa: std.mem.Allocator, cwd: std.fs.Dir) !void {
        // Get the real path of the current working directory
        // https://github.com/ziglang/zig/issues/19353
        const cwd_path = try cwd.realpathAlloc(gpa, ".");
        defer gpa.free(cwd_path);

        // Join the cwd path with "db.sqlite"
        const db_path = try std.fs.path.join(gpa, &[_][]const u8{ cwd_path, "db.sqlite" });
        defer gpa.free(db_path);

        std.debug.print("Full path to db.sqlite: {s}\n", .{db_path});

        self.db = try sqlite.Database.open(.{ .path = "db.sqlite" });

        std.debug.print("Setting up database\n", .{});
        try self.db.exec("CREATE TABLE IF NOT EXISTS clipboard (id INTEGER PRIMARY KEY, body TEXT, timestamp INTEGER)", .{});
    }

    pub fn write(self: Self, clipboard: *ClipboardModel) !void {
        std.debug.print("Saving to clipboard: \"{s}\", at {d}\n", .{ clipboard.body.data, clipboard.timestamp });
        const insert = try self.db.prepare(ClipboardModel, void, "INSERT INTO clipboard VALUES (NULL, :body, :timestamp)");
        defer insert.finalize();
        try insert.exec(clipboard.*);
    }

    pub fn read(self: Self, arena: std.mem.Allocator) !*std.ArrayList(Clipboard) {
        std.debug.print("Reading storage\n", .{});
        const select = try self.db.prepare(struct {}, ClipboardModel, "SELECT * FROM clipboard");
        defer select.finalize();
        try select.bind(.{});
        defer select.reset();

        var clipboards: std.ArrayList(Clipboard) = .empty;
        while (try select.step()) |clipboard| {
            const clipboard_copy = Clipboard{ .body = try arena.dupe(u8, clipboard.body.data), .timestamp = clipboard.timestamp };

            try clipboards.append(arena, clipboard_copy);
        }
        return &clipboards;
    }

    pub fn teardown(self: Self) void {
        self.db.close();
    }
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
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

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const args = std.process.argsAlloc(gpa) catch {
        std.debug.print("Failed to allocate args\n", .{});
        return;
    };
    defer std.process.argsFree(gpa, args);

    const cwd = std.fs.cwd();

    var storage: Storage = .init();
    try storage.setup(gpa, cwd);
    defer storage.teardown();

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

            var current_clipboard = ClipboardModel{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
            try storage.write(&current_clipboard);
        } else if (std.mem.eql(u8, arg, "-o")) {
            // copy xclip's option name for now
            try stdout.writeAll(clipboard_lib.read() catch "");
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-l")) {
            const clipboards = try storage.read(arena);

            for (clipboards.items) |clipboard| {
                try stdout.print("body: {s}, timestamp: {d}\n\n", .{ clipboard.body, clipboard.timestamp });
            }
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-t")) {
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
            var current_clipboard = ClipboardModel{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
            try storage.write(&current_clipboard);

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

            var current_clipboard = ClipboardModel{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
            try storage.write(&current_clipboard);
        }
    }
    if (!catted_anything) {
        const stdin = &stdin_reader.interface;
        const input = try stdin.allocRemaining(gpa, .unlimited);
        defer gpa.free(input);

        try clipboard_lib.write(input);

        try stdout.writeAll(input);
        try stdout.flush();

        var current_clipboard = ClipboardModel{ .body = sqlite.text(input), .timestamp = std.time.timestamp() };
        try storage.write(&current_clipboard);
    }
}

fn usage(exe: []const u8) !void {
    std.log.warn("Usage: {s} [FILE]...\n", .{exe});
    return error.Invalid;
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
