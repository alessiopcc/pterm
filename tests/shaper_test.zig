const std = @import("std");
const shaper_mod = @import("shaper");
const c = shaper_mod.c;

// CORE-05a: Ligature formation
test "Shaper: ligature sequences produce fewer glyphs than input codepoints" {
    // Requires font fixture with liga/calt tables (e.g., Fira Code).
    // Will be testable after FontGrid integration or with embedded test font.
}

// CORE-04a: CJK wide characters
test "Shaper: CJK codepoints shape to single glyphs with correct cluster mapping" {
    // Shape a CJK codepoint (U+4E16), expect 1 glyph, cluster == 0
    // Requires font fixture -- will be testable after FontGrid integration or with embedded test font.
}

// CORE-04b: Combining marks
test "Shaper: combining mark sequences shape to composed glyphs" {
    // Shape 'e' + U+0301 (combining acute), expect correct cluster grouping
    // Requires font fixture -- will be testable after FontGrid integration or with embedded test font.
}

// CORE-04c: Grapheme clusters (flag emoji, skin tones)
test "Shaper: multi-codepoint grapheme clusters shape as single visual unit" {
    // Shape regional indicator pair U+1F1FA U+1F1F8 (US flag),
    // expect single glyph or glyph cluster with cluster mapping covering both codepoints
    // Requires font fixture -- will be testable after FontGrid integration or with embedded test font.
}

// HarfBuzz buffer lifecycle -- runs immediately using HarfBuzz C API
test "Shaper: HarfBuzz buffer creation and destruction" {
    const buf = c.hb_buffer_create();
    defer c.hb_buffer_destroy(buf);
    try std.testing.expect(c.hb_buffer_allocation_successful(buf) != 0);

    // Add some codepoints and verify buffer length
    c.hb_buffer_add(buf, 'H', 0);
    c.hb_buffer_add(buf, 'i', 1);
    c.hb_buffer_set_content_type(buf, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
    c.hb_buffer_set_direction(buf, c.HB_DIRECTION_LTR);

    var len: c_uint = 0;
    _ = c.hb_buffer_get_glyph_infos(buf, &len);
    try std.testing.expectEqual(@as(c_uint, 2), len);
}
