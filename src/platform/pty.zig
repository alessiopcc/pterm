const std = @import("std");
const builtin = @import("builtin");

/// PTY configuration for spawning a pseudo-terminal.
pub const PtyConfig = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    env: ?[*:null]const ?[*:0]const u8 = null,
};

/// Cross-platform PTY type selected at compile time (D-08).
/// Unix uses forkpty, Windows uses ConPTY.
pub const Pty = switch (builtin.os.tag) {
    .linux, .macos => @import("posix_pty.zig").PosixPty,
    .windows => @import("conpty.zig").ConPty,
    else => @compileError("unsupported OS for PTY"),
};
