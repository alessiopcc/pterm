/// PTY Reader Thread (D-07: PTY read on dedicated thread)
///
/// Continuously reads bytes from the PTY master fd and pushes them into
/// the SPSC mailbox for consumption by the parse thread. This separation
/// ensures that blocking I/O on the PTY does not stall VT parsing.
///
/// The reader runs in a tight loop: read from PTY -> push to mailbox.
/// When the mailbox is full, bytes are dropped (non-blocking push).
/// When the PTY has no data, the read call blocks (which is expected).

const std = @import("std");
const builtin = @import("builtin");
const mailbox_mod = @import("mailbox");
const pty_mod = @import("pty");

const Pty = pty_mod.Pty;
const MailboxType = mailbox_mod.Mailbox(65536);

pub const PtyReader = struct {
    pty: *Pty,
    mailbox: *MailboxType,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(pty: *Pty, mailbox: *MailboxType) PtyReader {
        return .{
            .pty = pty,
            .mailbox = mailbox,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    /// Start the reader thread. Spawns a new OS thread that reads
    /// from the PTY and pushes data to the mailbox.
    pub fn start(self: *PtyReader) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
    }

    /// Stop the reader thread. Sets the running flag to false and
    /// joins the thread. The thread will exit on its next read attempt
    /// or when the PTY pipe breaks.
    pub fn stop(self: *PtyReader) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Internal read loop executed on the reader thread.
    fn readLoop(self: *PtyReader) void {
        var read_buf: [4096]u8 = undefined;

        while (self.running.load(.acquire)) {
            // Read from PTY (may block on Unix, uses PeekNamedPipe on Windows)
            const n = self.readFromPty(&read_buf) catch |err| {
                switch (err) {
                    // Child process exited or pipe broken -- stop gracefully
                    error.ReadFailed => break,
                    else => break,
                }
            };

            if (n > 0) {
                // Push to mailbox, retrying until all bytes are delivered.
                // Dropping bytes mid-stream corrupts escape sequences.
                var sent: usize = 0;
                while (sent < n and self.running.load(.acquire)) {
                    const wrote = self.mailbox.push(read_buf[sent..n]);
                    sent += wrote;
                    if (sent < n) {
                        // Mailbox full — yield briefly and retry
                        std.Thread.yield() catch {};
                    }
                }
            } else {
                // No data available, yield to avoid busy-waiting
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    /// Platform-aware PTY read. On Windows, uses PeekNamedPipe to avoid
    /// blocking indefinitely (which would prevent the running flag check).
    fn readFromPty(self: *PtyReader, buf: []u8) !usize {
        if (comptime builtin.os.tag == .windows) {
            return self.readFromPtyWindows(buf);
        } else {
            return try self.pty.read(buf);
        }
    }

    const PeekNamedPipeFn = if (builtin.os.tag == .windows) struct {
        extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: std.os.windows.HANDLE,
            lpBuffer: ?[*]u8,
            nBufferSize: std.os.windows.DWORD,
            lpBytesRead: ?*std.os.windows.DWORD,
            lpTotalBytesAvail: ?*std.os.windows.DWORD,
            lpBytesLeftThisMessage: ?*std.os.windows.DWORD,
        ) callconv(.c) std.os.windows.BOOL;
    }.PeekNamedPipe else void;

    fn readFromPtyWindows(self: *PtyReader, buf: []u8) !usize {
        // Use PeekNamedPipe to check for data without blocking
        var avail: std.os.windows.DWORD = 0;
        const peek_ok = PeekNamedPipeFn(self.pty.output_read, null, 0, null, &avail, null);
        if (peek_ok == 0) return error.ReadFailed; // pipe broken
        if (avail > 0) {
            return try self.pty.read(buf);
        }
        return 0; // no data available
    }
};
