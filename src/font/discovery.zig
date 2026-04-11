/// Platform font discovery dispatcher (D-11).
///
/// Uses comptime platform dispatch to find system fonts by family name.
/// Linux: fontconfig, macOS: CoreText, Windows: directory scanning.
const builtin = @import("builtin");

/// Result of a font discovery operation.
pub const DiscoverResult = struct {
    path: []const u8,
    index: u32, // face index within the file (for .ttc collections)
};

pub const discoverFont = switch (builtin.os.tag) {
    .linux => @import("discovery_fontconfig.zig").discover,
    .macos => @import("discovery_coretext.zig").discover,
    .windows => @import("discovery_windows.zig").discover,
    else => @compileError("unsupported platform for font discovery"),
};

/// Try to discover the first available monospace font from platform defaults.
pub const discoverDefaultMonospace = switch (builtin.os.tag) {
    .linux => @import("discovery_fontconfig.zig").discoverDefaultMonospace,
    .macos => @import("discovery_coretext.zig").discoverDefaultMonospace,
    .windows => @import("discovery_windows.zig").discoverDefaultMonospace,
    else => @compileError("unsupported platform for font discovery"),
};

/// Discover a color emoji font for the current platform.
/// Returns null if no emoji font is found (emoji will render as missing glyph rectangles).
pub const discoverEmojiFont = switch (builtin.os.tag) {
    .linux => @import("discovery_fontconfig.zig").discoverEmojiFont,
    .macos => @import("discovery_coretext.zig").discoverEmojiFont,
    .windows => @import("discovery_windows.zig").discoverEmojiFont,
    else => @compileError("unsupported platform for font discovery"),
};
