/// Linux font discovery using fontconfig (D-11).
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
