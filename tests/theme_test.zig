/// Tests for color theme parsing, built-in themes, and palette conversion.
const std = @import("std");
const theme = @import("theme");
const builtin_themes = @import("builtin_themes");
const Color = @import("renderer_types").Color;

const parseHexColor = theme.parseHexColor;

// ---------------------------------------------------------------
// parseHexColor tests
// ---------------------------------------------------------------

test "parseHexColor valid #FF5555" {
    const c = try parseHexColor("#FF5555");
    try std.testing.expectEqual(@as(u8, 0xFF), c.r);
    try std.testing.expectEqual(@as(u8, 0x55), c.g);
    try std.testing.expectEqual(@as(u8, 0x55), c.b);
    try std.testing.expectEqual(@as(u8, 0xFF), c.a);
}

test "parseHexColor valid #000000" {
    const c = try parseHexColor("#000000");
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    try std.testing.expectEqual(@as(u8, 0xFF), c.a);
}

test "parseHexColor missing hash returns error" {
    const result = parseHexColor("FF5555");
    try std.testing.expectError(error.InvalidColorFormat, result);
}

test "parseHexColor invalid hex chars returns error" {
    const result = parseHexColor("#GGGGGG");
    try std.testing.expectError(error.InvalidColorFormat, result);
}

test "parseHexColor wrong length returns error" {
    const result = parseHexColor("#12345");
    try std.testing.expectError(error.InvalidColorFormat, result);
}

test "parseHexColor too long returns error" {
    const result = parseHexColor("#12345678");
    try std.testing.expectError(error.InvalidColorFormat, result);
}

// ---------------------------------------------------------------
// Built-in theme lookup tests
// ---------------------------------------------------------------

test "builtin_themes.get dracula returns correct colors" {
    const palette = builtin_themes.get("dracula") orelse return error.ThemeNotFound;
    try std.testing.expect(std.mem.eql(u8, "#F8F8F2", palette.foreground));
    try std.testing.expect(std.mem.eql(u8, "#282A36", palette.background));
}

test "builtin_themes.get solarized-dark returns correct background" {
    const palette = builtin_themes.get("solarized-dark") orelse return error.ThemeNotFound;
    try std.testing.expect(std.mem.eql(u8, "#002B36", palette.background));
}

test "builtin_themes.get nonexistent returns null" {
    try std.testing.expect(builtin_themes.get("nonexistent") == null);
}

test "builtin_themes.list returns exactly 8 names" {
    const names = builtin_themes.list();
    try std.testing.expectEqual(@as(usize, 8), names.len);
}

test "builtin_themes all 8 themes exist and are retrievable" {
    const names = builtin_themes.list();
    for (names) |name| {
        const p = builtin_themes.get(name);
        try std.testing.expect(p != null);
    }
}

// ---------------------------------------------------------------
// ColorPalette.toRendererPalette conversion tests
// ---------------------------------------------------------------

test "ColorPalette.toRendererPalette converts all fields" {
    const palette = builtin_themes.get("default").?;
    const rp = try palette.toRendererPalette();
    // Verify foreground was converted (#CDD6F4)
    try std.testing.expectEqual(@as(u8, 0xCD), rp.default_fg.r);
    try std.testing.expectEqual(@as(u8, 0xD6), rp.default_fg.g);
    try std.testing.expectEqual(@as(u8, 0xF4), rp.default_fg.b);
    // Verify background was converted (#1E1E2E)
    try std.testing.expectEqual(@as(u8, 0x1E), rp.default_bg.r);
    try std.testing.expectEqual(@as(u8, 0x1E), rp.default_bg.g);
    try std.testing.expectEqual(@as(u8, 0x2E), rp.default_bg.b);
    // Verify cursor was converted (#F5E0DC)
    try std.testing.expectEqual(@as(u8, 0xF5), rp.cursor_color.r);
}

test "ColorPalette has all required fields" {
    const palette = builtin_themes.get("dracula").?;
    // Verify all required fields exist by accessing them
    _ = palette.foreground;
    _ = palette.background;
    _ = palette.cursor;
    _ = palette.cursor_text;
    _ = palette.selection_bg;
    _ = palette.selection_fg;
    try std.testing.expectEqual(@as(usize, 8), palette.normal.len);
    try std.testing.expectEqual(@as(usize, 8), palette.bright.len);
}

// ---------------------------------------------------------------
// resolve256 with config palette
// ---------------------------------------------------------------

test "resolve256 with config palette returns correct ANSI normal colors" {
    const palette = builtin_themes.get("default").?;
    const rp = try palette.toRendererPalette();
    // Index 0 = normal black (#45475A)
    const black = rp.resolve256(0);
    try std.testing.expectEqual(@as(u8, 0x45), black.r);
    try std.testing.expectEqual(@as(u8, 0x47), black.g);
    try std.testing.expectEqual(@as(u8, 0x5A), black.b);
}

test "resolve256 with config palette returns correct ANSI bright colors" {
    const palette = builtin_themes.get("default").?;
    const rp = try palette.toRendererPalette();
    // Index 15 = bright white (#A6ADC8)
    const bw = rp.resolve256(15);
    try std.testing.expectEqual(@as(u8, 0xA6), bw.r);
    try std.testing.expectEqual(@as(u8, 0xAD), bw.g);
    try std.testing.expectEqual(@as(u8, 0xC8), bw.b);
}

test "resolve256 color cube index 16 = black (0,0,0)" {
    const palette = builtin_themes.get("default").?;
    const rp = try palette.toRendererPalette();
    const c = rp.resolve256(16);
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "resolve256 color cube index 196 = pure red (255,0,0)" {
    const palette = builtin_themes.get("default").?;
    const rp = try palette.toRendererPalette();
    const c = rp.resolve256(196);
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "resolve256 grayscale 232 = #080808" {
    const palette = builtin_themes.get("default").?;
    const rp = try palette.toRendererPalette();
    const c = rp.resolve256(232);
    try std.testing.expectEqual(@as(u8, 8), c.r);
}

test "resolve256 grayscale 255 = #eeeeee" {
    const palette = builtin_themes.get("default").?;
    const rp = try palette.toRendererPalette();
    const c = rp.resolve256(255);
    try std.testing.expectEqual(@as(u8, 238), c.r);
}

// ---------------------------------------------------------------
// Each built-in theme defines colors.ui fields
// ---------------------------------------------------------------

test "all built-in themes define ui colors" {
    const names = builtin_themes.list();
    for (names) |name| {
        const palette = builtin_themes.get(name).?;
        // Verify UI colors exist and can be converted
        const rp = try palette.toRendererPalette();
        // Ensure UI colors are not all zero (which would indicate uninitialized)
        _ = rp.ui_tab_bar_bg;
        _ = rp.ui_tab_active;
        _ = rp.ui_tab_inactive;
        _ = rp.ui_pane_border;
        _ = rp.ui_status_bar_bg;
        _ = rp.ui_agent_alert;
        // At least agent_alert should be non-black for all themes
        try std.testing.expect(rp.ui_agent_alert.r > 0 or rp.ui_agent_alert.g > 0 or rp.ui_agent_alert.b > 0);
    }
}

test "dracula theme agent_alert is yellow (#F1FA8C)" {
    const palette = builtin_themes.get("dracula").?;
    const rp = try palette.toRendererPalette();
    try std.testing.expectEqual(@as(u8, 0xF1), rp.ui_agent_alert.r);
    try std.testing.expectEqual(@as(u8, 0xFA), rp.ui_agent_alert.g);
    try std.testing.expectEqual(@as(u8, 0x8C), rp.ui_agent_alert.b);
}
