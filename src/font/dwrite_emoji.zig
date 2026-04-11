/// DirectWrite emoji rasterizer (Windows only).
///
/// Renders multi-codepoint emoji sequences that HarfBuzz + Segoe UI Emoji
/// can't compose (flags, ZWJ families, skin-tone modifiers) by delegating
/// to DirectWrite + Direct2D, which has built-in emoji composition.
const std = @import("std");
const builtin = @import("builtin");
const font_types = @import("font_types");

const GlyphBitmap = font_types.GlyphBitmap;

const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("dwrite_emoji.h");
}) else struct {};

/// Initialize the DirectWrite emoji renderer. Call once at startup.
pub fn init(font_size_pt: f32, dpi: f32) bool {
    if (builtin.os.tag != .windows) return false;
    return c.dwrite_emoji_init(font_size_pt, dpi) == 0;
}

/// Update font size (after zoom).
pub fn setSize(font_size_pt: f32, dpi: f32) void {
    if (builtin.os.tag != .windows) return;
    c.dwrite_emoji_set_size(font_size_pt, dpi);
}

/// Render a multi-codepoint emoji sequence to an RGBA bitmap.
/// `cell_height` is used to size the emoji to match the terminal grid.
/// Returns null if DirectWrite can't render it.
/// Lazily initializes DirectWrite on first call.
pub fn render(allocator: std.mem.Allocator, codepoints: []const u21, cell_height: f32) ?GlyphBitmap {
    if (builtin.os.tag != .windows) return null;

    // Lazy init: initialize DirectWrite on first call.
    // Use cell_height as the font size in pixels (DPI=96 means 1pt ≈ 1.33px,
    // so we convert cell_height pixels to points).
    const S = struct {
        var initialized: bool = false;
        var init_ok: bool = false;
        var last_size: f32 = 0;
    };
    const size_pt = cell_height * 72.0 / 96.0;
    if (!S.initialized) {
        S.initialized = true;
        S.init_ok = init(size_pt, 96.0);
        S.last_size = size_pt;
    }
    if (!S.init_ok) return null;
    // Update size if font changed (zoom).
    if (@abs(size_pt - S.last_size) > 0.5) {
        setSize(size_pt, 96.0);
        S.last_size = size_pt;
    }

    var cp32: [64]u32 = undefined;
    const len = @min(codepoints.len, cp32.len);
    for (0..len) |i| {
        cp32[i] = @intCast(codepoints[i]);
    }

    var bmp: c.DWriteEmojiBitmap = undefined;
    const result = c.dwrite_emoji_render(&cp32, @intCast(len), &bmp);
    if (result != 0) return null;

    if (bmp.width == 0 or bmp.height == 0 or bmp.data == null) {
        c.dwrite_emoji_free(&bmp);
        return null;
    }

    // Copy data to Zig-managed memory so caller can free with allocator.
    const pixel_count: usize = @as(usize, bmp.width) * @as(usize, bmp.height) * 4;
    const data = allocator.alloc(u8, pixel_count) catch {
        c.dwrite_emoji_free(&bmp);
        return null;
    };
    @memcpy(data, bmp.data[0..pixel_count]);
    c.dwrite_emoji_free(&bmp);

    return GlyphBitmap{
        .data = data,
        .width = bmp.width,
        .height = bmp.height,
        .bearing_x = bmp.bearing_x,
        .bearing_y = bmp.bearing_y,
        .advance = bmp.advance,
        .format = .rgba,
    };
}

/// Shut down DirectWrite resources.
pub fn shutdown() void {
    if (builtin.os.tag != .windows) return;
    c.dwrite_emoji_shutdown();
}
