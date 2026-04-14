/// macOS font discovery using CoreText.
///
/// Finds font files by family name using the CoreText API.
/// NOTE: This handles font DISCOVERY only. Rasterization is in rasterizer_coretext.zig.
const std = @import("std");
const DiscoverResult = @import("discovery.zig").DiscoverResult;

const c = @cImport({
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

/// Discover a font file path by family name.
/// Returns null if no matching font is found.
pub fn discover(allocator: std.mem.Allocator, family: []const u8) ?DiscoverResult {
    const family_z = allocator.dupeZ(u8, family) catch return null;
    defer allocator.free(family_z);

    const name_cfstr = c.CFStringCreateWithCString(null, family_z.ptr, c.kCFStringEncodingUTF8);
    if (name_cfstr == null) return null;
    defer c.CFRelease(name_cfstr);

    // Create a font descriptor with the given name.
    const desc = c.CTFontDescriptorCreateWithNameAndSize(name_cfstr, 0.0);
    if (desc == null) return null;
    defer c.CFRelease(desc);

    // Get the font URL attribute.
    const url_attr = c.CTFontDescriptorCopyAttribute(desc, c.kCTFontURLAttribute);
    if (url_attr == null) return null;
    defer c.CFRelease(url_attr);

    const url_ref = @as(c.CFURLRef, @ptrCast(url_attr));

    // Convert CFURL to file path.
    var path_buf: [1024]u8 = undefined;
    const path_cfstr = c.CFURLCopyFileSystemPath(url_ref, c.kCFURLPOSIXPathStyle);
    if (path_cfstr == null) return null;
    defer c.CFRelease(path_cfstr);

    if (c.CFStringGetCString(path_cfstr, &path_buf, path_buf.len, c.kCFStringEncodingUTF8) == 0) {
        return null;
    }

    const path_slice = std.mem.sliceTo(&path_buf, 0);
    const owned_path = allocator.dupe(u8, path_slice) catch return null;

    return DiscoverResult{
        .path = owned_path,
        .index = 0,
    };
}

/// Discover the first available system monospace font.
pub fn discoverDefaultMonospace(allocator: std.mem.Allocator) ?DiscoverResult {
    const defaults = [_][]const u8{
        "JetBrainsMono-Regular",
        "SFMono-Regular",
        "Menlo-Regular",
        "Monaco",
    };
    for (defaults) |family| {
        if (discover(allocator, family)) |result| return result;
    }
    return null;
}

/// Discover the Apple Color Emoji font (macOS default color emoji font).
pub fn discoverEmojiFont(allocator: std.mem.Allocator) ?DiscoverResult {
    return discover(allocator, "Apple Color Emoji");
}

/// Discover a Nerd Font symbols-only font.
/// Queries CoreText for known Nerd Font family names.
pub fn discoverNerdFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const nerd_families = [_][]const u8{
        "Symbols Nerd Font Mono",
        "Symbols Nerd Font",
    };
    for (nerd_families) |family| {
        if (discover(allocator, family)) |result| return result;
    }
    return null;
}

/// Discover a general Unicode symbol font (Dingbats, geometric shapes, etc.).
pub fn discoverSymbolFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const symbol_families = [_][]const u8{
        "Apple Symbols",
        "Menlo",
    };
    for (symbol_families) |family| {
        if (discover(allocator, family)) |result| return result;
    }
    return null;
}

/// Discover a CJK-capable font.
pub fn discoverCJKFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const cjk_fonts = [_][]const u8{ "Hiragino Sans", "PingFang SC", "Apple SD Gothic Neo" };
    for (cjk_fonts) |family| {
        if (discover(allocator, family)) |result| return result;
    }
    return null;
}
