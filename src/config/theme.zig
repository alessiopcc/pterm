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
    pane_border_active: [3]u8,
    status_bar_bg: [3]u8,
    agent_alert: [3]u8,
    search_bar_bg: [3]u8 = .{ 0x18, 0x18, 0x25 },
    search_match: [3]u8 = .{ 0x58, 0x4A, 0x1E },
    search_current_match: [3]u8 = .{ 0x6B, 0x2E, 0x3A },
    url_hover: [3]u8 = .{ 0x89, 0xB4, 0xFA },
    bell_flash: [3]u8 = .{ 0xF9, 0xE2, 0xAF },
    bell_badge: [3]u8 = .{ 0xF3, 0x8B, 0xA8 },
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
    ui_pane_border_active: Color,
    ui_status_bar_bg: Color,
    ui_agent_alert: Color,
    // UI colors
    ui_search_bar_bg: Color,
    ui_search_match: Color,
    ui_search_current_match: Color,
    ui_url_hover: Color,
    ui_bell_flash: Color,
    ui_bell_badge: Color,

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
        .ui_pane_border_active = colorFromU8Array(palette.ui.pane_border_active),
        .ui_status_bar_bg = colorFromU8Array(palette.ui.status_bar_bg),
        .ui_agent_alert = colorFromU8Array(palette.ui.agent_alert),
        .ui_search_bar_bg = colorFromU8Array(palette.ui.search_bar_bg),
        .ui_search_match = colorFromU8Array(palette.ui.search_match),
        .ui_search_current_match = colorFromU8Array(palette.ui.search_current_match),
        .ui_url_hover = colorFromU8Array(palette.ui.url_hover),
        .ui_bell_flash = colorFromU8Array(palette.ui.bell_flash),
        .ui_bell_badge = colorFromU8Array(palette.ui.bell_badge),
    };
}

/// Build a default RendererPalette matching the compile-time Catppuccin Mocha palette.
/// Used when no config file exists.
pub fn defaultRendererPalette() RendererPalette {
    const builtin_themes = @import("builtin_themes");
    const default_palette = builtin_themes.get("default").?;
    return buildRendererPalette(default_palette) catch unreachable;
}

/// Parse "#RRGGBB" hex string to [3]u8 array. Returns null on invalid format.
fn parseHexToU8Array(hex: []const u8) ?[3]u8 {
    if (hex.len != 7 or hex[0] != '#') return null;
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return null;
    return .{ r, g, b };
}

/// Overlay named ANSI color overrides onto a base [8][]const u8 array.
/// Each non-null field in `overrides` replaces the corresponding index.
/// Map: black=0, red=1, green=2, yellow=3, blue=4, magenta=5, cyan=6, white=7
fn overlayAnsiColors(base: [8][]const u8, overrides: anytype) [8][]const u8 {
    var result = base;
    if (overrides.black) |v| {
        result[0] = v;
    }
    if (overrides.red) |v| {
        result[1] = v;
    }
    if (overrides.green) |v| {
        result[2] = v;
    }
    if (overrides.yellow) |v| {
        result[3] = v;
    }
    if (overrides.blue) |v| {
        result[4] = v;
    }
    if (overrides.magenta) |v| {
        result[5] = v;
    }
    if (overrides.cyan) |v| {
        result[6] = v;
    }
    if (overrides.white) |v| {
        result[7] = v;
    }
    return result;
}

/// Overlay config UI color hex strings onto a base UiColors struct.
/// Each non-null hex string is parsed to [3]u8; invalid hex strings are ignored.
fn overlayUiColors(base: UiColors, ui_config: anytype) UiColors {
    var result = base;
    if (ui_config.tab_bar_bg) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.tab_bar_bg = c;
        }
    }
    if (ui_config.tab_active) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.tab_active = c;
        }
    }
    if (ui_config.tab_inactive) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.tab_inactive = c;
        }
    }
    if (ui_config.pane_border) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.pane_border = c;
        }
    }
    if (ui_config.pane_border_active) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.pane_border_active = c;
        }
    }
    if (ui_config.status_bar_bg) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.status_bar_bg = c;
        }
    }
    if (ui_config.agent_alert) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.agent_alert = c;
        }
    }
    if (ui_config.search_bar_bg) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.search_bar_bg = c;
        }
    }
    if (ui_config.search_match) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.search_match = c;
        }
    }
    if (ui_config.search_current_match) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.search_current_match = c;
        }
    }
    if (ui_config.url_hover) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.url_hover = c;
        }
    }
    if (ui_config.bell_flash) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.bell_flash = c;
        }
    }
    if (ui_config.bell_badge) |v| {
        if (parseHexToU8Array(v)) |c| {
            result.bell_badge = c;
        }
    }
    return result;
}

/// Format theme name list for warning output.
fn formatThemeList(names: []const []const u8) []const u8 {
    _ = names;
    return "default, dracula, solarized-dark, solarized-light, gruvbox-dark, nord, catppuccin-mocha, one-dark";
}

/// Build a RendererPalette from Config.Colors + theme name, using the named theme
/// as base and overlaying any non-null config color values on top.
/// Per D-03: theme selects base palette. Per D-04: inline overrides win.
/// Per D-05: unknown theme warns to stderr and falls back to "default".
/// Per D-07: all 13 UI color fields wired through overlay.
pub fn buildRendererPaletteFromConfig(colors: anytype, theme_name: ?[]const u8) RendererPalette {
    const builtin_themes = @import("builtin_themes");

    // D-03, D-05: Resolve theme by name, fallback to "default" on unknown
    const base_palette = blk: {
        if (theme_name) |name| {
            if (builtin_themes.get(name)) |palette| {
                break :blk palette;
            }
            // D-05: Unknown theme -- warn with available names, fall back to default
            const available = builtin_themes.list();
            std.log.warn("unknown theme '{s}'. Available themes: {s}. Falling back to 'default'.", .{
                name,
                formatThemeList(available),
            });
        }
        break :blk builtin_themes.get("default").?;
    };

    // D-04: Overlay inline [colors] overrides on theme base
    const merged = ColorPalette{
        .foreground = colors.foreground orelse base_palette.foreground,
        .background = colors.background orelse base_palette.background,
        .cursor = colors.cursor_color orelse base_palette.cursor,
        .cursor_text = colors.cursor_text orelse base_palette.cursor_text,
        .selection_bg = colors.selection_bg orelse base_palette.selection_bg,
        .selection_fg = colors.selection_fg orelse base_palette.selection_fg,
        // D-01: Overlay named ANSI color overrides on theme normals/brights
        .normal = overlayAnsiColors(base_palette.normal, colors.normal),
        .bright = overlayAnsiColors(base_palette.bright, colors.bright),
        // D-07: Overlay config UI colors on theme UI colors
        .ui = overlayUiColors(base_palette.ui, colors.ui),
    };

    return buildRendererPalette(merged) catch {
        // If any user-provided hex string is invalid, fall back to full defaults
        std.log.warn("Invalid color in config, falling back to default theme", .{});
        return defaultRendererPalette();
    };
}
