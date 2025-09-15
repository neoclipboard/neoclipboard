//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const sqlite = @import("sqlite");

pub const ClipboardModel = struct { id: ?i64 = null, body: sqlite.Text, timestamp: i64 };

pub const Clipboard = struct { body: []u8, timestamp: i64 };

pub const Storage = struct {
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


// pub fn bufferedPrint() !void {
//     // Stdout is for the actual output of your application, for example if you
//     // are implementing gzip, then only the compressed bytes should be sent to
//     // stdout, not any debugging messages.
//     var stdout_buffer: [1024]u8 = undefined;
//     var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
//     const stdout = &stdout_writer.interface;
//
//     try stdout.print("Run `zig build test` to run the tests.\n", .{});
//
//     try stdout.flush(); // Don't forget to flush!
// }
