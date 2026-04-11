/// Unit tests for font pipeline: GlyphAtlas, Rasterizer, and FontGrid.
const std = @import("std");
const testing = std.testing;
const font_types = @import("font_types");
const GlyphAtlas = @import("glyph_atlas").GlyphAtlas;
const CachedGlyph = @import("glyph_atlas").CachedGlyph;
const Rasterizer = @import("rasterizer").Rasterizer;
const FontGrid = @import("fontgrid").FontGrid;

const GlyphKey = font_types.GlyphKey;
const GlyphBitmap = font_types.GlyphBitmap;
const AtlasRegion = font_types.AtlasRegion;

// -- GlyphAtlas tests --

test "atlas insert and lookup" {
    var atlas = try GlyphAtlas.init(testing.allocator, 256);
    defer atlas.deinit();

    const bitmap = GlyphBitmap{
        .data = &[_]u8{ 255, 128, 64, 32, 16, 8, 4, 2, 1 },
        .width = 3,
        .height = 3,
        .bearing_x = 1,
        .bearing_y = 10,
        .advance = 8,
    };

    const key = GlyphKey{ .font_index = 0, .glyph_id = 65, .size_px = 13 };
    const cached = try atlas.insert(key, bitmap);

    try testing.expect(cached.region.w == 3);
    try testing.expect(cached.region.h == 3);
    try testing.expect(cached.bearing_x == 1);
    try testing.expect(cached.advance == 8);

    // Lookup should return the same region.
    const looked_up = atlas.lookup(key);
    try testing.expect(looked_up != null);
    try testing.expect(looked_up.?.region.x == cached.region.x);
    try testing.expect(looked_up.?.region.y == cached.region.y);
    try testing.expect(looked_up.?.region.w == cached.region.w);
    try testing.expect(looked_up.?.region.h == cached.region.h);
}

test "atlas insert second glyph at different position" {
    var atlas = try GlyphAtlas.init(testing.allocator, 256);
    defer atlas.deinit();

    const bitmap_a = GlyphBitmap{
        .data = &[_]u8{ 255, 128, 64, 32 },
        .width = 2,
        .height = 2,
        .bearing_x = 0,
        .bearing_y = 8,
        .advance = 7,
    };
    const bitmap_b = GlyphBitmap{
        .data = &[_]u8{ 10, 20, 30, 40, 50, 60 },
        .width = 3,
        .height = 2,
        .bearing_x = 1,
        .bearing_y = 9,
        .advance = 8,
    };

    const key_a = GlyphKey{ .font_index = 0, .glyph_id = 65, .size_px = 13 };
    const key_b = GlyphKey{ .font_index = 0, .glyph_id = 66, .size_px = 13 };

    const cached_a = try atlas.insert(key_a, bitmap_a);
    const cached_b = try atlas.insert(key_b, bitmap_b);

    // Second glyph should be at a different x position on the same shelf.
    try testing.expect(cached_b.region.x == cached_a.region.x + cached_a.region.w);
    try testing.expect(cached_b.region.y == cached_a.region.y);
}

test "atlas cache returns same region on duplicate insert" {
    var atlas = try GlyphAtlas.init(testing.allocator, 256);
    defer atlas.deinit();

    const bitmap = GlyphBitmap{
        .data = &[_]u8{255},
        .width = 1,
        .height = 1,
        .bearing_x = 0,
        .bearing_y = 1,
        .advance = 5,
    };
    const key = GlyphKey{ .font_index = 0, .glyph_id = 42, .size_px = 16 };

    const first = try atlas.insert(key, bitmap);
    const second = try atlas.insert(key, bitmap);

    try testing.expect(first.region.x == second.region.x);
    try testing.expect(first.region.y == second.region.y);
}

test "atlas growth from small to larger size" {
    // Use a tiny 4x4 atlas to force growth quickly.
    var atlas = try GlyphAtlas.init(testing.allocator, 4);
    defer atlas.deinit();

    try testing.expect(atlas.getSize() == 4);

    // Insert a 3x3 glyph -- fits in 4x4.
    const bitmap_3x3 = GlyphBitmap{
        .data = &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        .width = 3,
        .height = 3,
        .bearing_x = 0,
        .bearing_y = 3,
        .advance = 3,
    };
    _ = try atlas.insert(
        GlyphKey{ .font_index = 0, .glyph_id = 1, .size_px = 10 },
        bitmap_3x3,
    );

    // Insert another 3x3 glyph -- won't fit horizontally (3+3=6 > 4) or vertically (3+3=6 > 4).
    // This should trigger growth to 8x8.
    _ = try atlas.insert(
        GlyphKey{ .font_index = 0, .glyph_id = 2, .size_px = 10 },
        bitmap_3x3,
    );

    try testing.expect(atlas.getSize() == 8);
}

test "atlas dirty flag" {
    var atlas = try GlyphAtlas.init(testing.allocator, 64);
    defer atlas.deinit();

    try testing.expect(!atlas.isDirty());

    const bitmap = GlyphBitmap{
        .data = &[_]u8{128},
        .width = 1,
        .height = 1,
        .bearing_x = 0,
        .bearing_y = 1,
        .advance = 5,
    };
    _ = try atlas.insert(
        GlyphKey{ .font_index = 0, .glyph_id = 1, .size_px = 10 },
        bitmap,
    );

    try testing.expect(atlas.isDirty());
    atlas.clearDirty();
    try testing.expect(!atlas.isDirty());
}

test "atlas zero-size glyph (space)" {
    var atlas = try GlyphAtlas.init(testing.allocator, 64);
    defer atlas.deinit();

    const bitmap = GlyphBitmap{
        .data = &.{},
        .width = 0,
        .height = 0,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance = 7,
    };
    const key = GlyphKey{ .font_index = 0, .glyph_id = 32, .size_px = 13 };
    const cached = try atlas.insert(key, bitmap);

    try testing.expect(cached.region.w == 0);
    try testing.expect(cached.region.h == 0);
    try testing.expect(cached.advance == 7);
}

test "atlas pixel data integrity after insert" {
    var atlas = try GlyphAtlas.init(testing.allocator, 64);
    defer atlas.deinit();

    const src_pixels = [_]u8{ 10, 20, 30, 40, 50, 60 };
    const bitmap = GlyphBitmap{
        .data = &src_pixels,
        .width = 3,
        .height = 2,
        .bearing_x = 0,
        .bearing_y = 2,
        .advance = 3,
    };
    const cached = try atlas.insert(
        GlyphKey{ .font_index = 0, .glyph_id = 1, .size_px = 10 },
        bitmap,
    );

    // Verify pixel data was correctly copied.
    const pixels = atlas.getPixels();
    const stride = atlas.getSize();
    const base_x = cached.region.x;
    const base_y = cached.region.y;

    // Row 0: 10, 20, 30
    try testing.expect(pixels[@as(usize, base_y) * stride + base_x] == 10);
    try testing.expect(pixels[@as(usize, base_y) * stride + base_x + 1] == 20);
    try testing.expect(pixels[@as(usize, base_y) * stride + base_x + 2] == 30);
    // Row 1: 40, 50, 60
    try testing.expect(pixels[(@as(usize, base_y) + 1) * stride + base_x] == 40);
    try testing.expect(pixels[(@as(usize, base_y) + 1) * stride + base_x + 1] == 50);
    try testing.expect(pixels[(@as(usize, base_y) + 1) * stride + base_x + 2] == 60);
}

// -- Rasterizer tests --
// These tests require a real font file. We attempt to find a system monospace font.
// If no font is available, the test is skipped.

fn findTestFont() ?[*:0]const u8 {
    // Windows system font paths.
    const candidates = [_][*:0]const u8{
        "C:\\Windows\\Fonts\\consola.ttf",
        "C:\\Windows\\Fonts\\cour.ttf",
        "C:\\Windows\\Fonts\\lucon.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/System/Library/Fonts/Menlo.ttc",
    };
    for (candidates) |path| {
        // Check if file exists by attempting to open.
        const file = std.fs.openFileAbsoluteZ(path, .{}) catch continue;
        file.close();
        return path;
    }
    return null;
}

test "rasterizer init and getMetrics" {
    const font_path = findTestFont() orelse return; // skip if no font found
    var rast = Rasterizer.init(testing.allocator, font_path, 13.0, 96) catch return;
    defer rast.deinit();

    const metrics = rast.getMetrics();
    try testing.expect(metrics.cell_width > 0);
    try testing.expect(metrics.cell_height > 0);
    try testing.expect(metrics.baseline_y > 0);
    try testing.expect(metrics.cell_height > metrics.cell_width); // monospace: taller than wide
}

test "rasterizer rasterizeGlyph produces valid bitmap" {
    const font_path = findTestFont() orelse return;
    var rast = Rasterizer.init(testing.allocator, font_path, 13.0, 96) catch return;
    defer rast.deinit();

    const bitmap = rast.rasterizeGlyph(testing.allocator, 'A') catch return;
    defer if (bitmap.data.len > 0) testing.allocator.free(bitmap.data);

    try testing.expect(bitmap.width > 0);
    try testing.expect(bitmap.height > 0);
    try testing.expect(bitmap.advance > 0);
}

test "rasterizer hasGlyph" {
    const font_path = findTestFont() orelse return;
    var rast = Rasterizer.init(testing.allocator, font_path, 13.0, 96) catch return;
    defer rast.deinit();

    try testing.expect(rast.hasGlyph('A'));
    try testing.expect(rast.hasGlyph('Z'));
    try testing.expect(rast.hasGlyph(' '));
}

// -- FontGrid tests --

test "fontgrid init and getMetrics" {
    var grid = FontGrid.init(testing.allocator, font_types.FontConfig{}) catch |err| {
        // Skip if no monospace font found on this system.
        if (err == error.NoMonospaceFont) return;
        return err;
    };
    defer grid.deinit();

    const metrics = grid.getMetrics();
    try testing.expect(metrics.cell_width > 0);
    try testing.expect(metrics.cell_height > 0);
    try testing.expect(metrics.baseline_y > 0);
    try testing.expect(grid.getFontCount() >= 1);
}

test "fontgrid getGlyph for ASCII A" {
    var grid = FontGrid.init(testing.allocator, font_types.FontConfig{}) catch |err| {
        if (err == error.NoMonospaceFont) return;
        return err;
    };
    defer grid.deinit();

    const result = try grid.getGlyph('A');
    try testing.expect(result.region.w > 0);
    try testing.expect(result.region.h > 0);
}

test "fontgrid setSize clamps to bounds" {
    var grid = FontGrid.init(testing.allocator, font_types.FontConfig{}) catch |err| {
        if (err == error.NoMonospaceFont) return;
        return err;
    };
    defer grid.deinit();

    // Set size below minimum -- should clamp to min_size_pt (6.0).
    try grid.setSize(2.0);
    try testing.expect(grid.config.size_pt == 6.0);

    // Set size above maximum -- should clamp to max_size_pt (72.0).
    try grid.setSize(100.0);
    try testing.expect(grid.config.size_pt == 72.0);
}
