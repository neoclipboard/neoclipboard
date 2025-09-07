const std = @import("std");

// third-party
const clipboard_lib = @import("clipboard");
const zlua = @import("zlua");

// local
const nclip_lib = @import("neoclipboard");

const Lua = zlua.Lua;

// copied from zig's src/main.zig:69
// This can be global since stdout is a singleton.
var stdout_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

pub fn main() !void {
    // // Prints to stderr, ignoring potential errors.
    // try nclip_lib.bufferedPrint();

    // TODO: Replace with GPA because we do not want to keep holding memory after clipboard redices
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    const exe = args[0];
    var catted_anything = false;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    // NOTE: I am not sure why in zig they are using buffered stdin, empty buffer works fine as well
    var stdin_reader = std.fs.File.stdin().readerStreaming(&.{});

    const cwd = std.fs.cwd();

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-")) {
            catted_anything = true;
            const stdin = &stdin_reader.interface;
            const input = try stdin.allocRemaining(arena, .unlimited);

            try clipboard_lib.write(input);

            try stdout.writeAll(input);
            try stdout.flush();
        } else if (std.mem.eql(u8, arg, "-o")) {
            // copy xclip's option name for now
            try stdout.writeAll(clipboard_lib.read() catch "");
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-l")) {
            const stdin = &stdin_reader.interface;
            const input = try stdin.allocRemaining(arena, .unlimited);

            // Initialize the Lua vm
            var lua = try Lua.init(arena);
            defer lua.deinit();

            // https://luascripts.com/lua-embed
            // https://piembsystech.com/integrating-lua-as-a-scripting-language-in-c-c-applications/
            lua.openLibs();

            try lua.doFile("lua/trim.lua");
            _ = try lua.getGlobal("trim");
            try lua.pushAny(input);
            try lua.protectedCall(.{ .args = 1, .results = 1 });

            const result = try lua.toString(1);

            try clipboard_lib.write(result);

            try stdout.writeAll(result);
            try stdout.flush();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage(exe);
        } else {
            const file = cwd.openFile(arg, .{}) catch |err| std.process.fatal("unable to open file: {t}\n", .{err});
            defer file.close();

            catted_anything = true;
            var file_reader = file.reader(&.{});
            const input = try file_reader.interface.allocRemaining(arena, .unlimited);

            try clipboard_lib.write(input);

            try stdout.writeAll(input);
            try stdout.flush();
        }
    }
    if (!catted_anything) {
        const stdin = &stdin_reader.interface;
        const input = try stdin.allocRemaining(arena, .unlimited);

        try clipboard_lib.write(input);

        try stdout.writeAll(input);
        try stdout.flush();
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
