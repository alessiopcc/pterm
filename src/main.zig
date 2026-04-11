const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Create a terminal with 80x24 dimensions
    var t: ghostty_vt.Terminal = try .init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    // Feed a test string to the terminal
    try t.printString("Hello from TermP!");

    // Read back the screen text
    const str = try t.plainString(alloc);
    defer alloc.free(str);

    std.debug.print("Screen output: {s}\n", .{str});
}
