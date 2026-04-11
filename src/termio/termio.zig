/// Terminal I/O coordinator with double-buffer swap (D-17).
///
/// Orchestrates the full terminal pipeline:
///   PTY -> reader -> mailbox -> parser -> terminal back buffer -> swap -> front buffer
///
/// Thread ownership model:
///   Main thread:    owns TermIO, calls getSnapshot/swap/resize/writeInput
///   Reader thread:  reads PTY -> pushes to mailbox (owned by TermIO)
///   Parser thread:  pops from mailbox -> feeds back buffer terminal (owned by TermIO)
///
/// The double-buffer swap (D-17) provides zero-contention rendering access.
/// The renderer reads from the front buffer via getSnapshot() while the parser
/// writes to the back buffer. swap() atomically exchanges them.

const std = @import("std");
const terminal_mod = @import("terminal");
const observer_mod = @import("observer");
const mailbox_mod = @import("mailbox");
const parser_mod = @import("parser");
const reader_mod = @import("reader");
const pty_mod = @import("pty");

const TermPTerminal = terminal_mod.TermPTerminal;
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
    /// Front buffer: read by the renderer (main thread).
    terminal_front: *TermPTerminal,
    /// Back buffer: written by the parser thread.
    terminal_back: *TermPTerminal,
    /// Parse thread: pops from mailbox, feeds back buffer.
    parser: ?ParseThread,
    /// SPSC ring buffer connecting reader -> parser.
    mailbox: *MailboxType,
    /// Mutex protecting the front/back buffer swap.
    mutex: std.Thread.Mutex,
    /// Allocator used for terminal creation.
    allocator: std.mem.Allocator,
    /// PTY reader thread: reads from PTY, pushes to mailbox.
    reader: ?PtyReader,
    /// Reference to the attached PTY (owned externally).
    pty: ?*Pty,

    /// Initialize the TermIO coordinator.
    /// Creates two TermPTerminal instances (front and back buffers per D-17)
    /// and a mailbox for the reader -> parser pipeline.
    pub fn init(allocator: std.mem.Allocator, config: TermIOConfig) !TermIO {
        const term_config = Config{
            .cols = config.cols,
            .rows = config.rows,
            .scrollback_lines = config.scrollback_lines,
        };

        // Allocate terminals on heap so pointers remain stable across swaps
        const front = try allocator.create(TermPTerminal);
        errdefer allocator.destroy(front);
        front.* = try TermPTerminal.init(allocator, term_config);
        errdefer front.deinit();

        const back = try allocator.create(TermPTerminal);
        errdefer allocator.destroy(back);
        back.* = try TermPTerminal.init(allocator, term_config);
        errdefer back.deinit();

        const mailbox = try allocator.create(MailboxType);
        errdefer allocator.destroy(mailbox);
        mailbox.* = .{};

        return TermIO{
            .terminal_front = front,
            .terminal_back = back,
            .parser = null,
            .mailbox = mailbox,
            .mutex = .{},
            .allocator = allocator,
            .reader = null,
            .pty = null,
        };
    }

    /// Clean up all resources.
    pub fn deinit(self: *TermIO) void {
        self.stop();

        self.terminal_front.deinit();
        self.allocator.destroy(self.terminal_front);

        self.terminal_back.deinit();
        self.allocator.destroy(self.terminal_back);

        self.allocator.destroy(self.mailbox);
    }

    /// Attach a PTY to the TermIO pipeline.
    /// Creates a PtyReader that reads from the PTY and pushes to the mailbox.
    /// The PTY is owned externally; TermIO only holds a reference.
    /// Must be called before start(). If called while running, the caller
    /// must stop() first, attach, then start() again.
    pub fn attachPty(self: *TermIO, pty: *Pty) void {
        self.pty = pty;
        self.reader = PtyReader.init(pty, self.mailbox);
    }

    /// Start the parser and reader threads.
    /// The parser reads from the mailbox and feeds the back buffer terminal.
    /// The reader reads from the PTY and pushes to the mailbox (if attached).
    pub fn start(self: *TermIO) !void {
        // Initialize parser pointing to back buffer
        self.parser = ParseThread.init(self.terminal_back, self.mailbox);

        // Start parser thread
        if (self.parser) |*p| {
            try p.start();
        }

        // Start reader thread (PTY -> mailbox)
        if (self.reader) |*r| {
            try r.start();
        }
    }

    /// Stop all threads (reverse order: reader first, then parser).
    pub fn stop(self: *TermIO) void {
        // Stop reader thread first (stops feeding mailbox)
        if (self.reader) |*r| {
            r.stop();
        }

        // Stop parser thread (stops consuming mailbox)
        if (self.parser) |*p| {
            p.stop();
        }
        self.parser = null;
    }

    /// Swap front and back buffers (D-17 double-buffer swap).
    /// Called periodically (e.g., at frame rate) by the renderer.
    /// For Phase 1, test harness calls it manually.
    pub fn swap(self: *TermIO) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tmp = self.terminal_front;
        self.terminal_front = self.terminal_back;
        self.terminal_back = tmp;

        // Re-point parser to new back buffer if running
        if (self.parser) |*p| {
            p.terminal = self.terminal_back;
        }
    }

    /// Get a snapshot of the front buffer for rendering.
    /// The returned pointer is valid until the next swap() call.
    /// Callers should not hold this pointer for extended periods.
    pub fn getSnapshot(self: *TermIO) *const TermPTerminal {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.terminal_front;
    }

    /// Resize both terminal buffers and the attached PTY (D-10).
    pub fn resize(self: *TermIO, cols: u16, rows: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.terminal_front.resize(cols, rows);
        try self.terminal_back.resize(cols, rows);

        // Resize PTY if attached (D-10)
        if (self.pty) |pty| {
            pty.resize(cols, rows) catch {};
        }
    }

    /// Write user input to the PTY (keyboard -> shell).
    /// Returns error.NoPty if no PTY is attached.
    pub fn writeInput(self: *TermIO, data: []const u8) !void {
        if (self.pty) |pty| {
            _ = try pty.write(data);
        } else {
            return error.NoPty;
        }
    }

    /// Feed bytes directly into the mailbox (for testing without a PTY).
    /// In production, the PTY reader pushes bytes to the mailbox.
    pub fn feedMailbox(self: *TermIO, data: []const u8) usize {
        return self.mailbox.push(data);
    }
};
