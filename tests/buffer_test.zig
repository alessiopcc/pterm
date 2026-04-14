const std = @import("std");
const buffer_mod = @import("core_buffer");
const ScrollbackBuffer = buffer_mod.ScrollbackBuffer;

test "scrollback push and get" {
    const alloc = std.testing.allocator;
    var buf = try ScrollbackBuffer.init(alloc, 100);
    defer buf.deinit();

    // Push 10 lines with distinct codepoints
    for (0..10) |i| {
        const cp: u21 = @intCast(65 + i); // 'A', 'B', 'C', ...
        const codepoints = &[_]u21{ cp, cp, cp };
        buf.pushLine(codepoints);
    }

    try std.testing.expectEqual(@as(u32, 10), buf.lineCount());

    // Verify each line contains correct codepoints
    for (0..10) |i| {
        const cp: u21 = @intCast(65 + i);
        const line = buf.getLine(@intCast(i)).?;
        try std.testing.expectEqual(@as(usize, 3), line.len);
        try std.testing.expectEqual(cp, line[0]);
    }
}

test "scrollback ring eviction" {
    const alloc = std.testing.allocator;
    // Use a small capacity for testing
    const capacity: u32 = 100;
    var buf = try ScrollbackBuffer.init(alloc, capacity);
    defer buf.deinit();

    // Push capacity + 1 lines
    for (0..capacity + 1) |i| {
        const cp: u21 = @intCast(i);
        buf.pushLine(&[_]u21{cp});
    }

    // Should still have exactly `capacity` lines
    try std.testing.expectEqual(capacity, buf.lineCount());

    // Oldest line (index 0) should be the SECOND line pushed (codepoint 1),
    // not the first (codepoint 0) -- that one was evicted
    const oldest = buf.getLine(0).?;
    try std.testing.expectEqual(@as(u21, 1), oldest[0]);

    // Newest line (index capacity-1) should be the last pushed (codepoint capacity)
    const newest = buf.getLine(capacity - 1).?;
    try std.testing.expectEqual(@as(u21, @intCast(capacity)), newest[0]);
}

test "scrollback line count" {
    const alloc = std.testing.allocator;
    var buf = try ScrollbackBuffer.init(alloc, 1000);
    defer buf.deinit();

    for (0..50) |_| {
        buf.pushLine(&[_]u21{65});
    }
    try std.testing.expectEqual(@as(u32, 50), buf.lineCount());

    // Push more, still under capacity
    for (0..100) |_| {
        buf.pushLine(&[_]u21{66});
    }
    try std.testing.expectEqual(@as(u32, 150), buf.lineCount());
}

test "scrollback clear" {
    const alloc = std.testing.allocator;
    var buf = try ScrollbackBuffer.init(alloc, 100);
    defer buf.deinit();

    for (0..50) |_| {
        buf.pushLine(&[_]u21{65});
    }
    try std.testing.expectEqual(@as(u32, 50), buf.lineCount());

    buf.clear();
    try std.testing.expectEqual(@as(u32, 0), buf.lineCount());
    try std.testing.expectEqual(@as(?[]const u21, null), buf.getLine(0));
}

test "scrollback capacity configurable" {
    const alloc = std.testing.allocator;
    var buf = try ScrollbackBuffer.init(alloc, 100);
    defer buf.deinit();

    // Push 200 lines into 100-capacity buffer
    for (0..200) |i| {
        const cp: u21 = @intCast(i);
        buf.pushLine(&[_]u21{cp});
    }

    // Should retain only 100 lines
    try std.testing.expectEqual(@as(u32, 100), buf.lineCount());

    // Oldest retained should be line 100 (0-indexed)
    const oldest = buf.getLine(0).?;
    try std.testing.expectEqual(@as(u21, 100), oldest[0]);

    // Newest should be line 199
    const newest = buf.getLine(99).?;
    try std.testing.expectEqual(@as(u21, 199), newest[0]);
}

test "serialize stub" {
    const alloc = std.testing.allocator;
    var buf = try ScrollbackBuffer.init(alloc, 100);
    defer buf.deinit();

    buf.pushLine(&[_]u21{ 72, 101, 108, 108, 111 }); // "Hello"
    buf.pushLine(&[_]u21{ 87, 111, 114, 108, 100 }); // "World"

    // Serialize to memory buffer
    var out_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&out_buf);
    try buf.serialize(stream.writer());

    // Deserialize back
    const written = stream.pos;
    var read_stream = std.io.fixedBufferStream(out_buf[0..written]);
    var restored = try ScrollbackBuffer.deserialize(alloc, read_stream.reader());
    defer restored.deinit();

    try std.testing.expectEqual(@as(u32, 2), restored.lineCount());

    // Verify first line
    const line0 = restored.getLine(0).?;
    try std.testing.expectEqual(@as(u21, 72), line0[0]); // 'H'
    try std.testing.expectEqual(@as(usize, 5), line0.len);

    // Verify second line
    const line1 = restored.getLine(1).?;
    try std.testing.expectEqual(@as(u21, 87), line1[0]); // 'W'
}
