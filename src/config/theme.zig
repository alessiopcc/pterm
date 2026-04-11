/// Color theme types and hex parsing for the configuration system.
///
/// Bridges between Config (hex strings in TOML) and the renderer (Color structs).
/// Provides RendererPalette — a runtime-resolved color palette used by
/// RenderState and Backend instead of the compile-time palette in renderer/types.zig.
const std = @import("std");
const Color = @import("renderer_types").Color;

/// Parse a #RRGGBB hex color string into a renderer Color.
/// Returns error.InvalidColorFormat for malformed input (per D-31).
pub fn parseHexColor(hex: []const u8) !Color {
    if (hex.len != 7 or hex[0] != '#') return error.InvalidColorFormat;
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch return error.InvalidColorFormat;
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return error.InvalidColorFormat;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return error.InvalidColorFormat;
    return Color{ .r = r, .g = g, .b = b, .a = 255 };
}

/// Convert a [3]u8 RGB array to a renderer Color.
pub fn colorFromU8Array(rgb: [3]u8) Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
}

/// UI chrome colors (D-28: tab bar, pane borders, status bar, agent alert).
pub const UiColors = struct {
    tab_bar_bg: [3]u8,
    tab_active: [3]u8,
    tab_inactive: [3]u8,
    pane_border: [3]u8,
    status_bar_bg: [3]u8,
    agent_alert: [3]u8,
};

/// Color palette as stored in config: hex strings for ANSI + named colors,
/// plus [3]u8 arrays for UI chrome.
pub const ColorPalette = struct {
    foreground: []const u8,
    background: []const u8,
    cursor: []const u8,
    cursor_text: []const u8,
    selection_bg: []const u8,
    selection_fg: []const u8,
    normal: [8][]const u8,
    bright: [8][]const u8,
    ui: UiColors,

    /// Convert this palette to a RendererPalette (hex strings -> Color structs).
    pub fn toRendererPalette(self: ColorPalette) !RendererPalette {
        return buildRendererPalette(self);
    }
};

/// Runtime color palette resolved from config hex strings.
/// This is the bridge between Config (hex strings) and renderer (Color structs).
pub const RendererPalette = struct {
    default_bg: Color,
    default_fg: Color,
    cursor_color: Color,
    cursor_text: Color,
    selection_bg: Color,
    selection_fg: Color,
    ansi_normal: [8]Color,
    ansi_bright: [8]Color,
    // D-28 UI chrome colors
    ui_tab_bar_bg: Color,
    ui_tab_active: Color,
    ui_tab_inactive: Color,
    ui_pane_border: Color,
    ui_status_bar_bg: Color,
    ui_agent_alert: Color,

    /// Resolve a 256-color index using this palette's ANSI colors.
    /// Indices 0-7: normal, 8-15: bright, 16-231: 6x6x6 cube, 232-255: grayscale.
    pub fn resolve256(self: RendererPalette, idx: u8) Color {
        if (idx < 8) return self.ansi_normal[idx];
        if (idx < 16) return self.ansi_bright[idx - 8];
        if (idx < 232) {
            // 6x6x6 color cube: indices 16-231
            const cube_index = idx - 16;
            const r_idx = cube_index / 36;
            const g_idx = (cube_index % 36) / 6;
            const b_idx = cube_index % 6;
            const cube_values = [6]u8{ 0, 95, 135, 175, 215, 255 };
            return Color{
                .r = cube_values[r_idx],
                .g = cube_values[g_idx],
                .b = cube_values[b_idx],
            };
        }
        // Grayscale ramp: indices 232-255 -> 24 shades from #080808 to #eeeeee
        const gray: u8 = @intCast(@as(u16, idx - 232) * 10 + 8);
        return Color{ .r = gray, .g = gray, .b = gray };
    }
};

/// Build RendererPalette from ColorPalette (hex strings -> Color structs).
pub fn buildRendererPalette(palette: ColorPalette) !RendererPalette {
    var normal: [8]Color = undefined;
    var bright: [8]Color = undefined;
    for (0..8) |i| {
        normal[i] = try parseHexColor(palette.normal[i]);
        bright[i] = try parseHexColor(palette.bright[i]);
    }
    return RendererPalette{
        .default_fg = try parseHexColor(palette.foreground),
        .default_bg = try parseHexColor(palette.background),
        .cursor_color = try parseHexColor(palette.cursor),
        .cursor_text = try parseHexColor(palette.cursor_text),
        .selection_bg = try parseHexColor(palette.selection_bg),
        .selection_fg = try parseHexColor(palette.selection_fg),
        .ansi_normal = normal,
        .ansi_bright = bright,
        .ui_tab_bar_bg = colorFromU8Array(palette.ui.tab_bar_bg),
        .ui_tab_active = colorFromU8Array(palette.ui.tab_active),
        .ui_tab_inactive = colorFromU8Array(palette.ui.tab_inactive),
        .ui_pane_border = colorFromU8Array(palette.ui.pane_border),
        .ui_status_bar_bg = colorFromU8Array(palette.ui.status_bar_bg),
        .ui_agent_alert = colorFromU8Array(palette.ui.agent_alert),
    };
}

/// Build a default RendererPalette matching the compile-time Catppuccin Mocha palette.
/// Used when no config file exists for identical behavior to pre-Phase 4.
pub fn defaultRendererPalette() RendererPalette {
    const builtin_themes = @import("builtin_themes");
    const default_palette = builtin_themes.get("default").?;
    return buildRendererPalette(default_palette) catch unreachable;
}

/// Build a RendererPalette from Config.Colors, using default theme values
/// as fallback for any unset (null) fields.
/// This bridges the optional Config.Colors fields to the required ColorPalette fields.
pub fn buildRendererPaletteFromConfig(colors: anytype) RendererPalette {
    const builtin_themes = @import("builtin_themes");
    const defaults = builtin_themes.get("default").?;

    // Build a ColorPalette by overlaying config values on defaults
    const merged = ColorPalette{
        .foreground = colors.foreground orelse defaults.foreground,
        .background = colors.background orelse defaults.background,
        .cursor = colors.cursor_color orelse defaults.cursor,
        .cursor_text = colors.cursor_text orelse defaults.cursor_text,
        .selection_bg = colors.selection_bg orelse defaults.selection_bg,
        .selection_fg = colors.selection_fg orelse defaults.selection_fg,
        .normal = defaults.normal, // ANSI colors not yet in Config.Colors; use defaults
        .bright = defaults.bright,
        .ui = defaults.ui, // UI colors not wired until Phase 5/7
    };

    return buildRendererPalette(merged) catch {
        // If any user-provided hex string is invalid, fall back to full defaults
        std.log.warn("Invalid color in config, falling back to default theme", .{});
        return defaultRendererPalette();
    };
}
