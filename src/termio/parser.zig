/// Dedicated parse thread (D-07).
///
/// Consumes bytes from the mailbox (SPSC ring buffer) and feeds them
/// to the terminal's VT parser via feedBytes(). This thread is the ONLY
/// thread that calls terminal.feedBytes() -- this is the thread safety contract.
///
/// The parse loop runs until stop() is called. When no data is available,
/// the thread yields to avoid busy-waiting.

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

    pub fn init(terminal: *TermPTerminal, mailbox: *MailboxType) ParseThread {
        return .{
            .terminal = terminal,
            .mailbox = mailbox,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    /// Start the parse thread. Spawns a new OS thread running the parse loop.
    pub fn start(self: *ParseThread) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, parseLoop, .{self});
    }

    /// Stop the parse thread. Sets running to false and joins the thread.
    pub fn stop(self: *ParseThread) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// The parse loop: pop bytes from mailbox and feed to terminal.
    /// This is the ONLY thread that calls terminal.feedBytes().
    fn parseLoop(self: *ParseThread) void {
        var buf: [8192]u8 = undefined;

        while (self.running.load(.acquire)) {
            const n = self.mailbox.pop(&buf);
            if (n > 0) {
                self.terminal.feedBytes(buf[0..n]) catch |err| {
                    std.debug.print("ParseThread: feedBytes error: {}\n", .{err});
                };
            } else {
                // No data available, yield to avoid busy-waiting
                std.Thread.yield() catch {};
            }
        }

        // Drain any remaining data after stop signal
        var buf2: [8192]u8 = undefined;
        while (true) {
            const n = self.mailbox.pop(&buf2);
            if (n == 0) break;
            self.terminal.feedBytes(buf2[0..n]) catch {};
        }
    }
};
