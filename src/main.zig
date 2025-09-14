const std = @import("std");
const builtin = @import("builtin");

// third-party
const clipboard_lib = @import("clipboard");
const zlua = @import("zlua");
const sqlite = @import("sqlite");
const known_folders = @import("known-folders");

// local
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

const ClipboardModel = struct { id: ?i64 = null, body: sqlite.Text, timestamp: i64 };

const Clipboard = struct { body: []u8, timestamp: i64 };

const Storage = struct {
    const Self = @This();

    db: *const sqlite.Database,

    pub fn init(db: *const sqlite.Database) Self {
        return .{
            .db = db,
        };
    }

    pub fn setup(self: Self) !void {
        // std.debug.print("Setting up database\n", .{});
        try self.db.exec("CREATE TABLE IF NOT EXISTS clipboard (id INTEGER PRIMARY KEY, body TEXT, timestamp INTEGER)", .{});
    }

    pub fn write(self: Self, clipboard: *ClipboardModel) !void {
        // std.debug.print("Saving to clipboard: \"{s}\", at {d}\n", .{ clipboard.body.data, clipboard.timestamp });
        const insert = try self.db.prepare(ClipboardModel, void, "INSERT INTO clipboard VALUES (:id, :body, :timestamp)");
        defer insert.finalize();
        try insert.exec(clipboard.*);
    }

    pub fn last(self: Self, arena: std.mem.Allocator) !*Clipboard {
        // std.debug.print("Reading storage\n", .{});
        const select = try self.db.prepare(struct {}, ClipboardModel, "SELECT id, body, timestamp FROM clipboard ORDER BY id DESC LIMIT 1");
        defer select.finalize();
        try select.bind(.{});
        defer select.reset();

        var clipboard_copy: Clipboard = undefined;
        while (try select.step()) |clipboard| {
            // Text and blob values must not be retained across steps. You are responsible for copying them.
            clipboard_copy = Clipboard{ .body = try arena.dupe(u8, clipboard.body.data), .timestamp = clipboard.timestamp };

        }
        // TODO: handle empty storage
        return &clipboard_copy;
    }

    pub fn list(self: Self, arena: std.mem.Allocator) !*std.ArrayList(Clipboard) {
        // std.debug.print("Reading storage\n", .{});
        const select = try self.db.prepare(struct {}, ClipboardModel, "SELECT id, body, timestamp FROM clipboard ORDER BY id DESC");
        defer select.finalize();
        try select.bind(.{});
        defer select.reset();

        var clipboards: std.ArrayList(Clipboard) = .empty;
        while (try select.step()) |clipboard| {
            // Text and blob values must not be retained across steps. You are responsible for copying them.
            const clipboard_copy = Clipboard{ .body = try arena.dupe(u8, clipboard.body.data), .timestamp = clipboard.timestamp };

            try clipboards.append(arena, clipboard_copy);
        }
        return &clipboards;
    }
};

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

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const args = std.process.argsAlloc(gpa) catch {
        std.debug.print("Failed to allocate args\n", .{});
        return 2;
    };
    defer std.process.argsFree(gpa, args);

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

    const db_path = try std.fs.path.joinZ(gpa, &.{ data_path, "db.sqlite" });
    // const db_path = try std.fs.path.join(gpa, &[_][]const u8{ data_path, "db.sqlite" });
    defer gpa.free(db_path);

    // std.debug.print("Full path to db.sqlite: {s}\n", .{db_path});

    const db = try sqlite.Database.open(.{ .path = db_path });
    defer db.close();

    var storage: Storage = .init(&db);
    try storage.setup();

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
            return 0;
        } else if (std.mem.eql(u8, arg, "-o")) {
            // copy xclip's option name for now
            try stdout.writeAll(clipboard_lib.read() catch @panic("can't read clipboard"));
            try stdout.flush();
            return 0;
        } else if (std.mem.eql(u8, arg, "-h")) {
            const clipboard = try storage.last(arena);
            try stdout.writeAll(clipboard.body);
            try stdout.flush();
            return 0;
        } else if (std.mem.eql(u8, arg, "-l")) {
            const clipboards = try storage.list(arena);

            for (clipboards.items) |clipboard| {
                // print ending with NUL ascii to handle multi-line clipboards
                try stdout.print("{s}\x00", .{ clipboard.body });
            }
            try stdout.flush();
            return 0;
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

            return 0;
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
        return 0;
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

test "storage write" {
    const db = try sqlite.Database.open(.{});
    defer db.close();

    const storage: Storage = .init(&db);
    try storage.setup();
    var input_clipboard = ClipboardModel{ .body = sqlite.text("test"), .timestamp = std.time.timestamp() };
    try storage.write(&input_clipboard);

    const select = try db.prepare(struct {}, ClipboardModel, "SELECT id, body, timestamp FROM clipboard");
    defer select.finalize();
    try select.bind(.{});
    defer select.reset();

    while (try select.step()) |clipboard| {
        // Text and blob values must not be retained across steps. You are responsible for copying them.

        try std.testing.expectEqualStrings(clipboard.body.data, "test");
    }
}

test "storage list" {
    const gpa = std.testing.allocator;
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const db = try sqlite.Database.open(.{});
    defer db.close();

    const storage: Storage = .init(&db);
    try storage.setup();

    const input_clipboard = ClipboardModel{ .body = sqlite.text("test"), .timestamp = std.time.timestamp() };
    const insert = try db.prepare(ClipboardModel, void, "INSERT INTO clipboard VALUES (:id, :body, :timestamp)");
    defer insert.finalize();
    try insert.exec(input_clipboard);

    const clipboards = try storage.list(arena);
    for (clipboards.items) |clipboard| {
        try std.testing.expectEqualStrings(clipboard.body, "test");
    }
}

test "storage list after write" {
    const gpa = std.testing.allocator;
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const db = try sqlite.Database.open(.{});
    defer db.close();

    const storage: Storage = .init(&db);
    try storage.setup();
    var input_clipboard = ClipboardModel{ .body = sqlite.text("test"), .timestamp = std.time.timestamp() };
    try storage.write(&input_clipboard);
    const clipboards = try storage.list(arena);
    for (clipboards.items) |clipboard| {
        try std.testing.expectEqualStrings(clipboard.body, "test");
    }
}

// test "simple test" {
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(i32) = .empty;
//     defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(gpa, 42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }

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
