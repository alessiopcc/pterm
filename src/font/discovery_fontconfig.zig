/// Linux font discovery using fontconfig.
///
/// Finds font files by family name via the fontconfig C API.
const std = @import("std");
const DiscoverResult = @import("discovery.zig").DiscoverResult;

const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

/// Discover a font file path by family name.
/// Returns null if no matching font is found.
pub fn discover(allocator: std.mem.Allocator, family: []const u8) ?DiscoverResult {
    const config = c.FcInitLoadConfigAndFonts();
    if (config == null) return null;
    defer c.FcConfigDestroy(config);

    const pattern = c.FcPatternCreate();
    if (pattern == null) return null;
    defer c.FcPatternDestroy(pattern);

    // Add family name.
    const family_z = allocator.dupeZ(u8, family) catch return null;
    defer allocator.free(family_z);
    _ = c.FcPatternAddString(pattern, c.FC_FAMILY, @ptrCast(family_z.ptr));

    // Prefer monospace.
    _ = c.FcPatternAddInteger(pattern, c.FC_SPACING, c.FC_MONO);

    _ = c.FcConfigSubstitute(config, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(config, pattern, &result);
    if (match == null) return null;
    defer c.FcPatternDestroy(match);

    // Extract file path.
    var file_value: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_value) != c.FcResultMatch) {
        return null;
    }

    // Extract face index.
    var face_index: c_int = 0;
    _ = c.FcPatternGetInteger(match, c.FC_INDEX, 0, &face_index);

    const file_path = std.mem.span(@as([*:0]const u8, @ptrCast(file_value)));
    const owned_path = allocator.dupe(u8, file_path) catch return null;

    return DiscoverResult{
        .path = owned_path,
        .index = @intCast(face_index),
    };
}

/// Discover the first available system monospace font.
pub fn discoverDefaultMonospace(allocator: std.mem.Allocator) ?DiscoverResult {
    const defaults = [_][]const u8{
        "JetBrains Mono",
        "DejaVu Sans Mono",
        "Liberation Mono",
        "Noto Sans Mono",
        "monospace",
    };
    for (defaults) |family| {
        if (discover(allocator, family)) |result| return result;
    }
    return null;
}

/// Discover a color emoji font (tries Noto Color Emoji, then generic emoji family).
pub fn discoverEmojiFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const emoji_families = [_][]const u8{
        "Noto Color Emoji",
        "Twemoji",
        "emoji",
    };
    for (emoji_families) |family| {
        if (discoverNonMono(allocator, family)) |result| return result;
    }
    return null;
}

pub fn discoverCJKFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const cjk_families = [_][]const u8{
        "Noto Sans CJK",
        "Noto Sans CJK JP",
        "WenQuanYi Micro Hei",
        "Droid Sans Fallback",
    };
    for (cjk_families) |family| {
        if (discoverNonMono(allocator, family)) |result| return result;
    }
    return null;
}

/// Discover a Nerd Font symbols-only font.
/// Queries fontconfig for known Nerd Font family names.
pub fn discoverNerdFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const nerd_families = [_][]const u8{
        "Symbols Nerd Font Mono",
        "Symbols Nerd Font",
    };
    for (nerd_families) |family| {
        if (discoverNonMono(allocator, family)) |result| return result;
    }
    return null;
}

/// Discover a general Unicode symbol font (Dingbats, geometric shapes, etc.).
pub fn discoverSymbolFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const symbol_families = [_][]const u8{
        "Noto Sans Symbols",
        "Noto Sans Symbols2",
        "DejaVu Sans",
    };
    for (symbol_families) |family| {
        if (discoverNonMono(allocator, family)) |result| return result;
    }
    return null;
}

/// Discover a font without the monospace spacing constraint (for emoji fonts).
fn discoverNonMono(allocator: std.mem.Allocator, family: []const u8) ?DiscoverResult {
    const config = c.FcInitLoadConfigAndFonts();
    if (config == null) return null;
    defer c.FcConfigDestroy(config);

    const pattern = c.FcPatternCreate();
    if (pattern == null) return null;
    defer c.FcPatternDestroy(pattern);

    const family_z = allocator.dupeZ(u8, family) catch return null;
    defer allocator.free(family_z);
    _ = c.FcPatternAddString(pattern, c.FC_FAMILY, @ptrCast(family_z.ptr));

    _ = c.FcConfigSubstitute(config, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(config, pattern, &result);
    if (match == null) return null;
    defer c.FcPatternDestroy(match);

    var file_value: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_value) != c.FcResultMatch) {
        return null;
    }

    var face_index: c_int = 0;
    _ = c.FcPatternGetInteger(match, c.FC_INDEX, 0, &face_index);

    const file_path = std.mem.span(@as([*:0]const u8, @ptrCast(file_value)));
    const owned_path = allocator.dupe(u8, file_path) catch return null;

    return DiscoverResult{
        .path = owned_path,
        .index = @intCast(face_index),
    };
}
