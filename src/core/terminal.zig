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

pub const PTermTerminal = struct {
    terminal: ghostty_vt.Terminal,
    allocator: std.mem.Allocator,
    observer: Observer,
    config: Config,
    /// Persistent VT stream — reused across feedBytes calls to preserve
    /// parser state for escape sequences split across read boundaries.
    /// Lazily initialized on first feedBytes call (not in init) because
    /// the stream captures a pointer to `terminal` — if created during
    /// init the struct may move when returned by value, invalidating it.
    vt_stream: ?ghostty_vt.TerminalStream,

    pub fn init(alloc: std.mem.Allocator, config: Config) !PTermTerminal {
        const t: ghostty_vt.Terminal = try .init(alloc, .{
            .cols = config.cols,
            .rows = config.rows,
        });
        return PTermTerminal{
            .terminal = t,
            .allocator = alloc,
            .observer = .{},
            .config = config,
            .vt_stream = null,
        };
    }

    pub fn deinit(self: *PTermTerminal) void {
        if (self.vt_stream) |*s| s.deinit();
        self.terminal.deinit(self.allocator);
    }

    /// Feed raw bytes to the terminal via the VT stream parser.
    /// This processes escape sequences (CSI, OSC, DEC modes, SGR, etc.)
    /// unlike printString which only handles display text.
    /// Notifies observer before and after parsing.
    /// Per only UTF-8 is accepted.
    pub fn feedBytes(self: *PTermTerminal, bytes: []const u8) !void {
        // Notify observer before parsing
        self.observer.notify(.{ .output = bytes });

        // Lazily create the persistent stream on first call.
        // At this point `self` is at its final heap address, so
        // the stream's internal pointer to `terminal` stays valid.
        if (self.vt_stream == null) {
            self.vt_stream = self.terminal.vtStream();
        }
        self.vt_stream.?.nextSlice(bytes);

        // Notify screen change after parsing
        self.observer.notify(.screen_change);
    }

    /// Feed display text to the terminal (no escape sequence processing).
    /// Use feedBytes for raw terminal I/O with escape sequences.
    pub fn printText(self: *PTermTerminal, text: []const u8) !void {
        try self.terminal.printString(text);
    }

    /// Get plain text representation of current screen.
    pub fn getScreenText(self: *PTermTerminal) ![]const u8 {
        return try self.terminal.plainString(self.allocator);
    }

    /// Resize the terminal.
    pub fn resize(self: *PTermTerminal, cols: u16, rows: u16) !void {
        try self.terminal.resize(self.allocator, cols, rows);
        self.config.cols = cols;
        self.config.rows = rows;
    }

    /// Get current cursor position.
    pub fn getCursorPos(self: *PTermTerminal) struct { row: usize, col: usize } {
        const cursor = self.terminal.screens.active.cursor;
        return .{
            .row = cursor.y,
            .col = cursor.x,
        };
    }

    /// Returns true if the terminal's DECTCEM mode (DEC mode 25) says the
    /// cursor should be visible.  Applications hide the cursor with `\e[?25l`.
    pub fn isCursorVisible(self: *PTermTerminal) bool {
        return self.terminal.modes.get(.cursor_visible);
    }

    /// Returns true if any mouse tracking mode is active (1000/1002/1003).
    pub fn isMouseTrackingEnabled(self: *PTermTerminal) bool {
        return self.terminal.modes.get(.mouse_event_normal) or
            self.terminal.modes.get(.mouse_event_button) or
            self.terminal.modes.get(.mouse_event_any);
    }

    /// Returns true if SGR extended mouse format (mode 1006) is active.
    pub fn isMouseFormatSgr(self: *PTermTerminal) bool {
        return self.terminal.modes.get(.mouse_format_sgr);
    }

    /// Returns true if bracketed paste mode (DEC mode 2004) is active.
    /// When enabled, pasted text must be wrapped in \e[200~ ... \e[201~
    /// so the shell treats it as a single paste rather than individual lines.
    pub fn isBracketedPasteEnabled(self: *PTermTerminal) bool {
        return self.terminal.modes.get(.bracketed_paste);
    }

    /// Access the underlying ghostty-vt ScreenSet for advanced queries.
    pub fn getScreens(self: *PTermTerminal) *ghostty_vt.ScreenSet {
        return &self.terminal.screens;
    }
};
