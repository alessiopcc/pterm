/// Observer hooks for agent monitor.
/// Agent Monitor uses these hooks to tap into terminal output
/// without refactoring the parser.
pub const Event = union(enum) {
    /// Raw bytes before parsing
    output: []const u8,
    /// Screen state changed (cursor moved, cells written, etc.)
    screen_change,
    /// DEC mode changed (alternate screen, focus events, etc.)
    mode_change: struct { mode: u16, enabled: bool },
    /// Parsed escape sequence notification (CSI/ESC action + params).
    /// Integration point for agent monitor pattern matching.
    sequence: struct { action: u8, params: []const u16 },
};

/// Program status report (OSC 7501, or OSC 9;4 progress mapped onto it).
/// Slices are borrowed and only valid during the callback.
pub const StatusReport = struct {
    pub const State = enum { idle, working, done, blocked, err, clear };
    pub const Kind = enum { permission, question, auth };

    state: State,
    /// Record id ("" = the program's root record). `/` separates levels.
    id: []const u8 = "",
    kind: ?Kind = null,
    app: []const u8 = "",
    /// Decoded UTF-8 title / message (no control characters).
    title: []const u8 = "",
    msg: []const u8 = "",
    progress: ?u8 = null,
};

pub const Observer = struct {
    onOutput: ?*const fn (bytes: []const u8) void = null,
    onScreenChange: ?*const fn (ctx: ?*anyopaque) void = null,
    screen_change_ctx: ?*anyopaque = null,
    onModeChange: ?*const fn (mode: u16, enabled: bool) void = null,
    /// Fired when custom VT parser replaces ghostty-vt.
    onSequence: ?*const fn (action: u8, params: []const u16) void = null,

    /// Bell callback. Fired by the VT parser for a real BEL; the BEL that
    /// terminates an OSC sequence (e.g. a title update) does not count.
    onBell: ?*const fn (ctx: ?*anyopaque) void = null,
    bell_ctx: ?*anyopaque = null,

    /// Agent output callback. Fired on every raw output event.
    /// Used to clear waiting state, reset idle timer, and schedule scan.
    onAgentOutput: ?*const fn (ctx: ?*anyopaque) void = null,
    agent_ctx: ?*anyopaque = null,

    // ── Agent status (parse thread, receive agent_ctx) ──

    /// Program status report (OSC 7501 / OSC 9;4).
    onStatus: ?*const fn (ctx: ?*anyopaque, report: StatusReport) void = null,
    /// Desktop notification request (OSC 9 / OSC 777). Borrowed slices.
    onNotification: ?*const fn (ctx: ?*anyopaque, title: []const u8, body: []const u8) void = null,
    /// Shell integration: a new prompt started (OSC 133;A).
    onPromptStart: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Window title changed (OSC 0 / 2). Borrowed slice.
    onTitle: ?*const fn (ctx: ?*anyopaque, title: []const u8) void = null,

    /// Reply to the program (query responses). Receives `write_ctx`.
    /// When null the terminal answers no queries.
    onWritePty: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
    write_ctx: ?*anyopaque = null,

    pub fn notify(self: *const Observer, event: Event) void {
        switch (event) {
            .output => |bytes| {
                if (self.onOutput) |cb| cb(bytes);
                // Agent output notification (instant clear, idle reset, scan schedule)
                if (self.onAgentOutput) |agent_cb| {
                    agent_cb(self.agent_ctx);
                }
            },
            .screen_change => if (self.onScreenChange) |cb| cb(self.screen_change_ctx),
            .mode_change => |m| if (self.onModeChange) |cb| cb(m.mode, m.enabled),
            .sequence => |s| if (self.onSequence) |cb| cb(s.action, s.params),
        }
    }
};
