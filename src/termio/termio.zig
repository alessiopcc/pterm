/// Terminal I/O coordinator with single-buffer mutex (D-17).
///
/// Orchestrates the full terminal pipeline:
///   PTY -> reader -> mailbox -> parser -> terminal (mutex-protected)
///
/// Thread ownership model:
///   Main thread:    owns TermIO, calls resize/writeInput
///   Reader thread:  reads PTY -> pushes to mailbox (owned by TermIO)
///   Parser thread:  pops from mailbox -> feeds terminal (under mutex)
///   Render thread:  reads terminal (under mutex) -> builds RenderState
///
/// Single buffer with mutex: simple, correct, no stale-state bugs.
/// The mutex is held briefly for reads (render) and writes (parser).

const std = @import("std");
const terminal_mod = @import("terminal");
const observer_mod = @import("observer");
const mailbox_mod = @import("mailbox");
const parser_mod = @import("parser");
const reader_mod = @import("reader");
const pty_mod = @import("pty");

const PTermTerminal = terminal_mod.PTermTerminal;
const Config = terminal_mod.Config;
const MailboxType = mailbox_mod.Mailbox(65536);
const ParseThread = parser_mod.ParseThread;
const PtyReader = reader_mod.PtyReader;
const Pty = pty_mod.Pty;

pub const TermIOConfig = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    scrollback_lines: u32 = 10_000,
};

pub const TermIO = struct {
    /// Single terminal buffer, protected by mutex.
    terminal: *PTermTerminal,
    /// Kept for API compatibility — points to same terminal.
    terminal_back: *PTermTerminal,
    /// Parse thread: pops from mailbox, feeds terminal.
    parser: ?ParseThread,
    /// SPSC ring buffer connecting reader -> parser.
    mailbox: *MailboxType,
    /// Mutex protecting all terminal access.
    mutex: std.Thread.Mutex,
    /// Allocator used for terminal creation.
    allocator: std.mem.Allocator,
    /// PTY reader thread: reads from PTY, pushes to mailbox.
    reader: ?PtyReader,
    /// Reference to the attached PTY (owned externally).
    pty: ?*Pty,

    pub fn init(allocator: std.mem.Allocator, config: TermIOConfig) !TermIO {
        const term_config = Config{
            .cols = config.cols,
            .rows = config.rows,
            .scrollback_lines = config.scrollback_lines,
        };

        const term = try allocator.create(PTermTerminal);
        errdefer allocator.destroy(term);
        term.* = try PTermTerminal.init(allocator, term_config);
        errdefer term.deinit();

        const mailbox = try allocator.create(MailboxType);
        errdefer allocator.destroy(mailbox);
        mailbox.* = .{};

        return TermIO{
            .terminal = term,
            .terminal_back = term,
            .parser = null,
            .mailbox = mailbox,
            .mutex = .{},
            .allocator = allocator,
            .reader = null,
            .pty = null,
        };
    }

    pub fn deinit(self: *TermIO) void {
        self.stop();
        self.terminal.deinit();
        self.allocator.destroy(self.terminal);
        self.allocator.destroy(self.mailbox);
    }

    pub fn attachPty(self: *TermIO, pty: *Pty) void {
        self.pty = pty;
        self.reader = PtyReader.init(pty, self.mailbox);
    }

    pub fn start(self: *TermIO) !void {
        self.parser = ParseThread.init(self.terminal, self.mailbox);
        if (self.parser) |*p| {
            p.term_mutex = &self.mutex;
        }

        if (self.parser) |*p| {
            try p.start();
        }

        if (self.reader) |*r| {
            try r.start();
        }
    }

    pub fn stop(self: *TermIO) void {
        if (self.reader) |*r| {
            r.stop();
        }
        if (self.parser) |*p| {
            p.stop();
        }
        self.parser = null;
    }

    /// No-op swap for API compatibility. Single buffer needs no swap.
    pub fn swap(self: *TermIO) void {
        _ = self;
    }

    /// No-op for API compatibility.
    pub fn applyPendingFrontResize(self: *TermIO) void {
        _ = self;
    }

    /// Get the terminal for rendering. Caller MUST call unlockTerminal() when done.
    pub fn lockTerminal(self: *TermIO) *const PTermTerminal {
        self.mutex.lock();
        return self.terminal;
    }

    pub fn unlockTerminal(self: *TermIO) void {
        self.mutex.unlock();
    }

    /// Legacy API — returns terminal pointer. For backwards compat only.
    pub fn getSnapshot(self: *TermIO) *const PTermTerminal {
        return self.terminal;
    }

    /// Resize terminal and PTY (D-10).
    /// Acquires mutex to safely resize the single terminal buffer.
    pub fn resize(self: *TermIO, cols: u16, rows: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.terminal.config.cols == cols and self.terminal.config.rows == rows) return;
        try self.terminal.resize(cols, rows);

        if (self.pty) |pty| {
            pty.resize(cols, rows) catch {};
        }
    }

    pub fn writeInput(self: *TermIO, data: []const u8) !void {
        if (self.pty) |pty| {
            _ = try pty.write(data);
        } else {
            return error.NoPty;
        }
    }

    pub fn feedMailbox(self: *TermIO, data: []const u8) usize {
        return self.mailbox.push(data);
    }
};
