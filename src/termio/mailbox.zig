/// SPSC (Single Producer, Single Consumer) ring buffer mailbox.
/// Used to transfer bytes from the PTY reader thread to the parse thread.
///
/// This is a lock-free ring buffer using atomic operations for thread safety.
/// The reader thread pushes bytes (producer), and the parser thread pops bytes (consumer).
const std = @import("std");

pub fn Mailbox(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]u8 = [_]u8{0} ** capacity,
        write_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        read_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        /// Push data into the mailbox. Returns the number of bytes actually written.
        /// If the buffer is full, excess bytes are dropped (non-blocking).
        pub fn push(self: *Self, data: []const u8) usize {
            const w = self.write_pos.load(.acquire);
            const r = self.read_pos.load(.acquire);

            // Available space in the ring buffer
            const space = if (w >= r) capacity - (w - r) - 1 else r - w - 1;
            const to_write = @min(data.len, space);

            var written: usize = 0;
            var pos = w;
            while (written < to_write) : (written += 1) {
                self.buffer[pos % capacity] = data[written];
                pos += 1;
            }

            self.write_pos.store(pos % capacity, .release);
            return written;
        }

        /// Pop data from the mailbox into the provided buffer.
        /// Returns the number of bytes actually read.
        pub fn pop(self: *Self, buf: []u8) usize {
            const w = self.write_pos.load(.acquire);
            const r = self.read_pos.load(.acquire);

            // Available data in the ring buffer
            const data_available = if (w >= r) w - r else capacity - r + w;
            const to_read = @min(buf.len, data_available);

            var read_count: usize = 0;
            var pos = r;
            while (read_count < to_read) : (read_count += 1) {
                buf[read_count] = self.buffer[pos % capacity];
                pos += 1;
            }

            self.read_pos.store(pos % capacity, .release);
            return read_count;
        }

        /// Returns the number of bytes available for reading.
        pub fn available(self: *const Self) usize {
            const w = self.write_pos.load(.acquire);
            const r = self.read_pos.load(.acquire);
            return if (w >= r) w - r else capacity - r + w;
        }

        /// Returns the number of bytes available for writing.
        pub fn freeSpace(self: *const Self) usize {
            const w = self.write_pos.load(.acquire);
            const r = self.read_pos.load(.acquire);
            return if (w >= r) capacity - (w - r) - 1 else r - w - 1;
        }
    };
}
