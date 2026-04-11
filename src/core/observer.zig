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

    pub fn notify(self: *const Observer, event: Event) void {
        switch (event) {
            .output => |bytes| if (self.onOutput) |cb| cb(bytes),
            .screen_change => if (self.onScreenChange) |cb| cb(self.screen_change_ctx),
            .mode_change => |m| if (self.onModeChange) |cb| cb(m.mode, m.enabled),
            .sequence => |s| if (self.onSequence) |cb| cb(s.action, s.params),
        }
    }
};
