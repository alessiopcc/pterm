const std = @import("std");
const pio = @import("pio");
const ghostty_vt = @import("ghostty-vt");
const observer_mod = @import("observer.zig");

pub const Observer = observer_mod.Observer;
pub const Event = observer_mod.Event;
pub const StatusReport = observer_mod.StatusReport;

const Handler = @FieldType(ghostty_vt.TerminalStream, "handler");
const ProgramStatusReport = ghostty_vt.osc.Command.ProgramStatus.Report;
const ProgressReport = ghostty_vt.osc.Command.ProgressReport;
const DesktopNotification = @typeInfo(@typeInfo(@typeInfo(@FieldType(@FieldType(Handler, "effects"), "desktop_notification")).optional.child).pointer.child).@"fn".param_types[1].?;

/// Record id used for OSC 9;4 progress, which has no id of its own. Not a
/// valid OSC 7501 id (`#` is outside the id alphabet), so it cannot collide.
pub const progress_record_id = "#progress";

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
    /// Serializes writes to the PTY: query replies (parse thread) and user
    /// input (main thread) must not interleave.
    write_mutex: pio.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, config: Config) !PTermTerminal {
        const t: ghostty_vt.Terminal = try .init(pio.io, alloc, .{
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
            self.installEffects(&self.vt_stream.?.handler);
        }
        self.vt_stream.?.nextSlice(bytes);

        // Notify screen change after parsing
        self.observer.notify(.screen_change);
    }

    /// Wire the VT handler's side effects to the observer: query replies,
    /// bells, notifications, progress, program status, prompt marks.
    /// Status effects are only installed when the observer listens, so a pane
    /// with status reporting disabled does not answer the OSC 7501 query.
    fn installEffects(self: *PTermTerminal, handler: *Handler) void {
        handler.effects.write_pty = &effectWritePty;
        handler.effects.device_attributes = &effectDeviceAttributes;
        handler.effects.bell = &effectBell;
        if (self.observer.onNotification != null) handler.effects.desktop_notification = &effectDesktopNotification;
        if (self.observer.onStatus != null) {
            handler.effects.progress_report = &effectProgressReport;
            handler.effects.program_status = &effectProgramStatus;
        }
        if (self.observer.onPromptStart != null) handler.effects.semantic_prompt = &effectSemanticPrompt;
        if (self.observer.onTitle != null) handler.effects.title_changed = &effectTitleChanged;
    }

    fn effectTitleChanged(handler: *Handler) void {
        const self = fromHandler(handler);
        const cb = self.observer.onTitle orelse return;
        cb(self.observer.agent_ctx, self.terminal.getTitle() orelse "");
    }

    fn fromHandler(handler: *Handler) *PTermTerminal {
        return @fieldParentPtr("terminal", handler.terminal);
    }

    fn effectWritePty(handler: *Handler, data: []const u8) void {
        const self = fromHandler(handler);
        const cb = self.observer.onWritePty orelse return;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        cb(self.observer.write_ctx, data);
    }

    fn effectDeviceAttributes(_: *Handler) ghostty_vt.device_attributes.Attributes {
        return .{};
    }

    fn effectBell(handler: *Handler) void {
        const self = fromHandler(handler);
        if (self.observer.onBell) |cb| cb(self.observer.bell_ctx);
    }

    fn effectDesktopNotification(handler: *Handler, n: DesktopNotification) void {
        const self = fromHandler(handler);
        if (self.observer.onNotification) |cb| cb(self.observer.agent_ctx, n.title, n.body);
    }

    fn effectProgressReport(handler: *Handler, p: ProgressReport) void {
        const self = fromHandler(handler);
        const cb = self.observer.onStatus orelse return;
        const state: StatusReport.State = switch (p.state) {
            .remove => .clear,
            .set, .indeterminate, .pause => .working,
            .@"error" => .err,
        };
        cb(self.observer.agent_ctx, .{ .state = state, .id = progress_record_id, .progress = p.progress });
    }

    fn effectProgramStatus(handler: *Handler, report: ProgramStatusReport) void {
        const self = fromHandler(handler);
        const cb = self.observer.onStatus orelse return;
        const state: StatusReport.State = switch (report.state) {
            .idle => .idle,
            .working => .working,
            .done => .done,
            .blocked => .blocked,
            .@"error" => .err,
            .clear => .clear,
        };
        const kind: ?StatusReport.Kind = if (report.readOption(.kind)) |k| switch (k) {
            .permission => .permission,
            .question => .question,
            .auth => .auth,
        } else null;

        var title_buf: [256]u8 = undefined;
        var title_w: std.Io.Writer = .fixed(&title_buf);
        report.writeText(.title, &title_w) catch {};
        var msg_buf: [2048]u8 = undefined;
        var msg_w: std.Io.Writer = .fixed(&msg_buf);
        report.writeText(.msg, &msg_w) catch {};

        cb(self.observer.agent_ctx, .{
            .state = state,
            .id = report.readOption(.id) orelse "",
            .kind = kind,
            .app = report.readOption(.app) orelse "",
            .title = title_w.buffered(),
            .msg = msg_w.buffered(),
            .progress = report.readOption(.progress),
        });
    }

    fn effectSemanticPrompt(handler: *Handler, ev: ghostty_vt.SemanticPrompt) void {
        const self = fromHandler(handler);
        if (ev.kind != .prompt_start) return;
        if (self.observer.onPromptStart) |cb| cb(self.observer.agent_ctx);
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
        try self.terminal.resize(self.allocator, .{ .cols = cols, .rows = rows });
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
