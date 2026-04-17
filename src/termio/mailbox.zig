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
        /// Signaled by push() when bytes are written, awaited by the parse thread
        /// via waitData() so it can sleep instead of busy-spinning when idle.
        data_event: std.Thread.ResetEvent = .{},

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
            if (written > 0) self.data_event.set();
            return written;
        }

        /// Block up to timeout_ns for a push signal, then reset the event so the
        /// next wait blocks again. Consumers call this when pop() returned 0.
        pub fn waitData(self: *Self, timeout_ns: u64) void {
            self.data_event.timedWait(timeout_ns) catch {};
            self.data_event.reset();
        }

        /// Unblock any thread currently inside waitData(). Used by shutdown.
        pub fn wake(self: *Self) void {
            self.data_event.set();
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
