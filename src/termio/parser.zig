/// Dedicated parse thread (D-07).
///
/// Consumes bytes from the mailbox (SPSC ring buffer) and feeds them
/// to the terminal's VT parser via feedBytes(). Holds the terminal mutex
/// during feedBytes() to synchronize with the render thread.

const std = @import("std");
const terminal_mod = @import("terminal");
const mailbox_mod = @import("mailbox");

const TermPTerminal = terminal_mod.TermPTerminal;
const MailboxType = mailbox_mod.Mailbox(65536);

pub const ParseThread = struct {
    terminal: *TermPTerminal,
    mailbox: *MailboxType,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    /// Pointer to TermIO's mutex — held during feedBytes/resize.
    term_mutex: ?*std.Thread.Mutex,
    /// Pending resize signaled by TermIO.resize().
    pending_resize_cols: std.atomic.Value(u16),
    pending_resize_rows: std.atomic.Value(u16),
    pending_resize: std.atomic.Value(bool),

    pub fn init(terminal: *TermPTerminal, mailbox: *MailboxType) ParseThread {
        return .{
            .terminal = terminal,
            .mailbox = mailbox,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
            .term_mutex = null,
            .pending_resize_cols = std.atomic.Value(u16).init(0),
            .pending_resize_rows = std.atomic.Value(u16).init(0),
            .pending_resize = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *ParseThread) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, parseLoop, .{self});
    }

    pub fn stop(self: *ParseThread) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn parseLoop(self: *ParseThread) void {
        var buf: [8192]u8 = undefined;

        while (self.running.load(.acquire)) {
            const n = self.mailbox.pop(&buf);
            if (n > 0) {
                if (self.term_mutex) |m| m.lock();
                self.terminal.feedBytes(buf[0..n]) catch |err| {
                    std.debug.print("ParseThread: feedBytes error: {}\n", .{err});
                };
                if (self.term_mutex) |m| m.unlock();
            } else {
                std.Thread.yield() catch {};
            }
        }

        // Drain remaining data
        var buf2: [8192]u8 = undefined;
        while (true) {
            const n = self.mailbox.pop(&buf2);
            if (n == 0) break;
            if (self.term_mutex) |m| m.lock();
            self.terminal.feedBytes(buf2[0..n]) catch {};
            if (self.term_mutex) |m| m.unlock();
        }
    }
};
