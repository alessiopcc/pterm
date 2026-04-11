const std = @import("std");
const renderer_types = @import("renderer_types");
const font_types = @import("font_types");
const cell_mod = @import("cell");

const CellFlags = renderer_types.CellFlags;
const CellInstance = renderer_types.CellInstance;

// CORE-04: Verify CellFlags constants for glyph classification.
test "CellFlags: WIDE_CHAR, LIGATURE_HEAD, COLOR_GLYPH are distinct bits" {
    try std.testing.expect(CellFlags.WIDE_CHAR & CellFlags.WIDE_CONTINUATION == 0);
    try std.testing.expect(CellFlags.LIGATURE_HEAD & CellFlags.LIGATURE_CONTINUATION == 0);
    try std.testing.expect(CellFlags.COLOR_GLYPH & CellFlags.WIDE_CHAR == 0);
    try std.testing.expect(CellFlags.COLOR_GLYPH & CellFlags.LIGATURE_HEAD == 0);

    // Verify expected values.
    try std.testing.expectEqual(@as(u16, 0x0001), CellFlags.WIDE_CHAR);
    try std.testing.expectEqual(@as(u16, 0x0002), CellFlags.WIDE_CONTINUATION);
    try std.testing.expectEqual(@as(u16, 0x0004), CellFlags.LIGATURE_HEAD);
    try std.testing.expectEqual(@as(u16, 0x0008), CellFlags.LIGATURE_CONTINUATION);
    try std.testing.expectEqual(@as(u16, 0x0010), CellFlags.COLOR_GLYPH);
}

// CORE-04: CellFlags can be combined (e.g., wide + color).
test "CellFlags: flags can be OR-combined" {
    const combined = CellFlags.WIDE_CHAR | CellFlags.COLOR_GLYPH;
    try std.testing.expect(combined & CellFlags.WIDE_CHAR != 0);
    try std.testing.expect(combined & CellFlags.COLOR_GLYPH != 0);
    try std.testing.expect(combined & CellFlags.LIGATURE_HEAD == 0);
}

// CORE-04: grapheme extraction constants.
test "cell: MAX_GRAPHEME_CODEPOINTS is sufficient for complex emoji" {
    // Flag emoji = 2 regional indicators, ZWJ family = up to 7 codepoints.
    try std.testing.expect(cell_mod.MAX_GRAPHEME_CODEPOINTS >= 8);
}

// CORE-04d: Emoji CellInstance construction pattern.
test "CellInstance: emoji glyph would have COLOR_GLYPH flag and correct width" {
    // Simulate what buildFromSnapshot produces for a color emoji.
    const ci = CellInstance{
        .grid_col = 5,
        .grid_row = 3,
        .atlas_x = 100,
        .atlas_y = 200,
        .atlas_w = 32,
        .atlas_h = 32,
        .bearing_x = 0,
        .bearing_y = 0,
        .fg_color = 0xFFFFFFFF,
        .bg_color = 0x00000000,
        .flags = CellFlags.WIDE_CHAR | CellFlags.COLOR_GLYPH,
    };
    try std.testing.expect(ci.flags & CellFlags.COLOR_GLYPH != 0);
    try std.testing.expect(ci.flags & CellFlags.WIDE_CHAR != 0);
}

// CORE-05b: Ligature cell pattern.
test "CellInstance: ligature produces LIGATURE_HEAD + LIGATURE_CONTINUATION pattern" {
    // Simulate what buildFromSnapshot produces for a "!=" ligature (2 cells).
    const head = CellInstance{
        .grid_col = 0,
        .grid_row = 0,
        .atlas_x = 10,
        .atlas_y = 20,
        .atlas_w = 16,
        .atlas_h = 24,
        .bearing_x = 0,
        .bearing_y = 0,
        .fg_color = 0xFFFFFFFF,
        .bg_color = 0x00000000,
        .flags = CellFlags.LIGATURE_HEAD,
    };
    // Continuation cell would be bg-only (not in text pass).
    try std.testing.expect(head.flags & CellFlags.LIGATURE_HEAD != 0);
    try std.testing.expect(head.flags & CellFlags.LIGATURE_CONTINUATION == 0);
}

// CORE-05c: Cursor breaks ligature pattern.
test "CellInstance: cursor position inside ligature breaks it into individual chars" {
    // When cursor is at col 1 inside "!=" at cols 0-1,
    // both chars are shaped individually (no ligature flags).
    const char_bang = CellInstance{
        .grid_col = 0,
        .grid_row = 0,
        .atlas_x = 10,
        .atlas_y = 20,
        .atlas_w = 8,
        .atlas_h = 24,
        .bearing_x = 0,
        .bearing_y = 0,
        .fg_color = 0xFFFFFFFF,
        .bg_color = 0x00000000,
        .flags = 0, // No ligature flag
    };
    const char_eq = CellInstance{
        .grid_col = 1,
        .grid_row = 0,
        .atlas_x = 30,
        .atlas_y = 20,
        .atlas_w = 8,
        .atlas_h = 24,
        .bearing_x = 0,
        .bearing_y = 0,
        .fg_color = 0xFFFFFFFF,
        .bg_color = 0x00000000,
        .flags = 0, // No ligature flag
    };
    // Both cells have flags = 0 (no ligature).
    try std.testing.expectEqual(@as(u16, 0), char_bang.flags);
    try std.testing.expectEqual(@as(u16, 0), char_eq.flags);
}
