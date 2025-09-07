const std = @import("std");
const nclip_lib = @import("neoclipboard");
const fs = std.fs;
const mem = std.mem;
const warn = std.log.warn;
const fatal = std.process.fatal;

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try nclip_lib.bufferedPrint();
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    const exe = args[0];
    var catted_anything = false;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
    const stdout = &stdout_writer.interface;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&.{});

    const cwd = fs.cwd();

    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "-")) {
            catted_anything = true;
            _ = try stdout.sendFileAll(&stdin_reader, .unlimited);
        } else if (mem.startsWith(u8, arg, "-")) {
            return usage(exe);
        } else {
            const file = cwd.openFile(arg, .{}) catch |err| fatal("unable to open file: {t}\n", .{err});
            defer file.close();

            catted_anything = true;
            var file_reader = file.reader(&.{});
            _ = try stdout.sendFileAll(&file_reader, .unlimited);
        }
    }
    if (!catted_anything) {
        _ = try stdout.sendFileAll(&stdin_reader, .unlimited);
    }
}

fn usage(exe: []const u8) !void {
    warn("Usage: {s} [FILE]...\n", .{exe});
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
