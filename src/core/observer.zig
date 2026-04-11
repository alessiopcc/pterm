/// Observer hooks for agent monitor (D-06).
/// Phase 7 (Agent Monitor) will use these hooks to tap into terminal output
/// without refactoring the parser.

pub const Event = union(enum) {
    /// Raw bytes before parsing
    output: []const u8,
    /// Screen state changed (cursor moved, cells written, etc.)
    screen_change,
    /// DEC mode changed (alternate screen, focus events, etc.)
    mode_change: struct { mode: u16, enabled: bool },
    /// Parsed escape sequence notification (CSI/ESC action + params).
    /// Phase 7 integration point for agent monitor pattern matching.
    sequence: struct { action: u8, params: []const u16 },
};

pub const Observer = struct {
    onOutput: ?*const fn (bytes: []const u8) void = null,
    onScreenChange: ?*const fn (ctx: ?*anyopaque) void = null,
    screen_change_ctx: ?*anyopaque = null,
    onModeChange: ?*const fn (mode: u16, enabled: bool) void = null,
    /// Phase 7 integration point. Fired when custom VT parser replaces ghostty-vt (D-01).
    onSequence: ?*const fn (action: u8, params: []const u16) void = null,

    /// Phase 6 D-26: Bell detection callback. Fired when BEL byte (0x07) is found
    /// in the raw output stream before VT parsing strips it.
    onBell: ?*const fn (ctx: ?*anyopaque) void = null,
    bell_ctx: ?*anyopaque = null,

    /// Phase 7: Agent output callback. Fired on every raw output event.
    /// Used to clear waiting state (D-04), reset idle timer, and schedule scan.
    onAgentOutput: ?*const fn (ctx: ?*anyopaque) void = null,
    agent_ctx: ?*anyopaque = null,

    pub fn notify(self: *const Observer, event: Event) void {
        switch (event) {
            .output => |bytes| {
                if (self.onOutput) |cb| cb(bytes);
                // Bell detection: scan for BEL byte (0x07) in raw output
                if (self.onBell) |bell_cb| {
                    for (bytes) |b| {
                        if (b == 0x07) {
                            bell_cb(self.bell_ctx);
                            break;
                        }
                    }
                }
                // Phase 7: Agent output notification (D-04 instant clear, idle reset, scan schedule)
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
