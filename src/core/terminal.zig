const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const observer_mod = @import("observer.zig");

pub const Observer = observer_mod.Observer;
pub const Event = observer_mod.Event;

pub const Config = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    scrollback_lines: u32 = 10_000,
    utf8_only: bool = true,
};

pub const TermPTerminal = struct {
    terminal: ghostty_vt.Terminal,
    allocator: std.mem.Allocator,
    observer: Observer,
    config: Config,

    pub fn init(alloc: std.mem.Allocator, config: Config) !TermPTerminal {
        const t: ghostty_vt.Terminal = try .init(alloc, .{
            .cols = config.cols,
            .rows = config.rows,
        });
        return TermPTerminal{
            .terminal = t,
            .allocator = alloc,
            .observer = .{},
            .config = config,
        };
    }

    pub fn deinit(self: *TermPTerminal) void {
        self.terminal.deinit(self.allocator);
    }

    /// Feed raw bytes to the terminal via the VT stream parser.
    /// This processes escape sequences (CSI, OSC, DEC modes, SGR, etc.)
    /// unlike printString which only handles display text.
    /// Notifies observer before and after parsing (D-06).
    /// Per D-11, only UTF-8 is accepted.
    pub fn feedBytes(self: *TermPTerminal, bytes: []const u8) !void {
        // Notify observer before parsing (D-06)
        self.observer.notify(.{ .output = bytes });

        // Feed raw bytes through the VT stream parser
        var stream = self.terminal.vtStream();
        stream.nextSlice(bytes);

        // Notify screen change after parsing
        self.observer.notify(.screen_change);
    }

    /// Feed display text to the terminal (no escape sequence processing).
    /// Use feedBytes for raw terminal I/O with escape sequences.
    pub fn printText(self: *TermPTerminal, text: []const u8) !void {
        try self.terminal.printString(text);
    }

    /// Get plain text representation of current screen.
    pub fn getScreenText(self: *TermPTerminal) ![]const u8 {
        return try self.terminal.plainString(self.allocator);
    }

    /// Resize the terminal (D-10: PTY resize support from day one).
    pub fn resize(self: *TermPTerminal, cols: u16, rows: u16) !void {
        try self.terminal.resize(self.allocator, cols, rows);
        self.config.cols = cols;
        self.config.rows = rows;
    }

    /// Get current cursor position.
    pub fn getCursorPos(self: *TermPTerminal) struct { row: usize, col: usize } {
        const cursor = self.terminal.screens.active.cursor;
        return .{
            .row = cursor.y,
            .col = cursor.x,
        };
    }

    /// Access the underlying ghostty-vt ScreenSet for advanced queries.
    pub fn getScreens(self: *TermPTerminal) *ghostty_vt.ScreenSet {
        return &self.terminal.screens;
    }
};
