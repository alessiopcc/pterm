/// Scrollback ring buffer manager for PTerm.
///
/// Wraps terminal scrollback with a fixed-capacity ring buffer.
/// When the buffer reaches capacity, the oldest line is evicted.
///
///(Alternate screen): ghostty-vt provides separate primary/alternate screen
/// buffers via its ScreenSet type. The ScrollbackBuffer ONLY manages the PRIMARY
/// screen's scrollback. When alternate screen is active (vim, htop, less), no lines
/// should be pushed to ScrollbackBuffer. The caller is responsible for checking the
/// active screen before pushing lines.
///
///(Serialization): serialize/deserialize stubs are provided for future session
/// persistence (v2). The API contract is established now; full implementation deferred.
const std = @import("std");

/// A single line in the scrollback buffer.
pub const Line = struct {
    /// Raw codepoints for this line. Owned by the ScrollbackBuffer allocator.
    codepoints: []u21,
    /// Whether this line has been modified since last render.
    dirty: bool,

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        if (self.codepoints.len > 0) {
            allocator.free(self.codepoints);
        }
        self.codepoints = &.{};
    }
};

/// Ring buffer for scrollback storage.
/// Fixed-size circular buffer with predictable memory usage.
/// Old lines are discarded when capacity is reached.
pub const ScrollbackBuffer = struct {
    lines: []Line,
    capacity: u32,
    write_pos: u32,
    line_count: u32,
    allocator: std.mem.Allocator,

    /// Initialize a scrollback buffer with the given capacity.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !ScrollbackBuffer {
        const lines = try allocator.alloc(Line, capacity);
        for (lines) |*line| {
            line.* = .{ .codepoints = &.{}, .dirty = false };
        }
        return ScrollbackBuffer{
            .lines = lines,
            .capacity = capacity,
            .write_pos = 0,
            .line_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScrollbackBuffer) void {
        for (self.lines) |*line| {
            line.deinit(self.allocator);
        }
        self.allocator.free(self.lines);
    }

    /// Append a line of codepoints to the ring buffer.
    /// If at capacity, overwrites the oldest line.
    pub fn pushLine(self: *ScrollbackBuffer, codepoints: []const u21) void {
        // Free old line data if we're overwriting
        var slot = &self.lines[self.write_pos];
        slot.deinit(self.allocator);

        // Copy codepoints into new allocation
        const owned = self.allocator.alloc(u21, codepoints.len) catch {
            // On allocation failure, store empty line
            slot.* = .{ .codepoints = &.{}, .dirty = true };
            self.advanceWrite();
            return;
        };
        @memcpy(owned, codepoints);

        slot.* = .{ .codepoints = owned, .dirty = true };
        self.advanceWrite();
    }

    /// Get line by index (0 = oldest visible line).
    /// Returns null if index is out of range.
    pub fn getLine(self: *const ScrollbackBuffer, index: u32) ?[]const u21 {
        if (index >= self.line_count) return null;

        // Calculate actual position in ring buffer
        const actual_pos = if (self.line_count < self.capacity)
            index
        else
            (self.write_pos + index) % self.capacity;

        const line = &self.lines[actual_pos];
        return line.codepoints;
    }

    /// Total number of lines currently stored.
    pub fn lineCount(self: *const ScrollbackBuffer) u32 {
        return self.line_count;
    }

    /// Reset the buffer, freeing all stored lines.
    pub fn clear(self: *ScrollbackBuffer) void {
        for (self.lines) |*line| {
            line.deinit(self.allocator);
            line.* = .{ .codepoints = &.{}, .dirty = false };
        }
        self.write_pos = 0;
        self.line_count = 0;
    }

    /// Serialize the buffer contents to a writer.
    /// Full implementation deferred to v2 session persistence.
    pub fn serialize(self: *const ScrollbackBuffer, writer: anytype) !void {
        // Write line count header
        try writer.writeInt(u32, self.line_count, .little);
        // Write each line's codepoint count and data
        var i: u32 = 0;
        while (i < self.line_count) : (i += 1) {
            if (self.getLine(i)) |codepoints| {
                const len: u32 = @intCast(codepoints.len);
                try writer.writeInt(u32, len, .little);
                for (codepoints) |cp| {
                    try writer.writeInt(u32, @as(u32, cp), .little);
                }
            } else {
                try writer.writeInt(u32, 0, .little);
            }
        }
    }

    /// Deserialize a buffer from a reader.
    /// Full implementation deferred to v2 session persistence.
    pub fn deserialize(allocator: std.mem.Allocator, reader: anytype) !ScrollbackBuffer {
        const line_count = try reader.readInt(u32, .little);
        var buffer = try ScrollbackBuffer.init(allocator, if (line_count > 0) line_count else 1);

        var i: u32 = 0;
        while (i < line_count) : (i += 1) {
            const len = try reader.readInt(u32, .little);
            const codepoints = try allocator.alloc(u21, len);
            defer allocator.free(codepoints);
            for (codepoints) |*cp| {
                cp.* = @intCast(try reader.readInt(u32, .little));
            }
            buffer.pushLine(codepoints);
        }

        return buffer;
    }

    // Internal: advance write position and update line count.
    fn advanceWrite(self: *ScrollbackBuffer) void {
        self.write_pos = (self.write_pos + 1) % self.capacity;
        if (self.line_count < self.capacity) {
            self.line_count += 1;
        }
    }
};
