/// HarfBuzz text shaping wrapper.
///
/// Shapes sequences of Unicode codepoints into positioned glyphs using
/// HarfBuzz's OpenType layout engine. Creates an HarfBuzz font from an
/// existing FreeType face via the hb-ft bridge. Supports ligature (calt, liga)
/// and kerning (kern) features.
const std = @import("std");
const font_types = @import("font_types");

pub const c = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

/// Result of shaping a single glyph.
pub const ShapedGlyph = struct {
    glyph_id: u32,
    cluster: u32,
    x_advance: i32,
    x_offset: i32,
    y_offset: i32,
    num_chars: u32,
};

pub const Shaper = struct {
    allocator: std.mem.Allocator,
    hb_font: *c.hb_font_t,
    hb_buf: *c.hb_buffer_t,
    features: [3]c.hb_feature_t,
    num_features: u32,

    /// Initialize the shaper from an existing FreeType face.
    /// The FreeType face must remain valid for the lifetime of the Shaper.
    pub fn init(allocator: std.mem.Allocator, ft_face: c.FT_Face) Shaper {
        const hb_font = c.hb_ft_font_create_referenced(ft_face).?;
        const hb_buf = c.hb_buffer_create().?;

        var features: [3]c.hb_feature_t = undefined;

        // calt (contextual alternates)
        features[0] = .{
            .tag = c.HB_TAG('c', 'a', 'l', 't'),
            .value = 1,
            .start = 0,
            .end = std.math.maxInt(c_uint),
        };

        // liga (standard ligatures)
        features[1] = .{
            .tag = c.HB_TAG('l', 'i', 'g', 'a'),
            .value = 1,
            .start = 0,
            .end = std.math.maxInt(c_uint),
        };

        // kern (kerning)
        features[2] = .{
            .tag = c.HB_TAG('k', 'e', 'r', 'n'),
            .value = 1,
            .start = 0,
            .end = std.math.maxInt(c_uint),
        };

        return Shaper{
            .allocator = allocator,
            .hb_font = hb_font,
            .hb_buf = hb_buf,
            .features = features,
            .num_features = 3,
        };
    }

    /// Release shaper resources.
    pub fn deinit(self: *Shaper) void {
        c.hb_font_destroy(self.hb_font);
        c.hb_buffer_destroy(self.hb_buf);
        self.* = undefined;
    }

    /// Notify HarfBuzz that the underlying FreeType face size has changed.
    /// Must be called after any FreeType FT_Set_Char_Size on the same face.
    pub fn fontChanged(self: *Shaper) void {
        c.hb_ft_font_changed(self.hb_font);
    }

    /// Shape a sequence of Unicode codepoints into positioned glyphs.
    ///
    /// The returned slice is allocator-owned; the caller must free it.
    /// Each ShapedGlyph contains the font-internal glyph_id (for atlas lookup),
    /// the cluster index (maps back to source codepoints), positioning offsets,
    /// and num_chars (number of source codepoints this glyph covers).
    pub fn shape(self: *Shaper, codepoints: []const u21) ![]ShapedGlyph {
        c.hb_buffer_clear_contents(self.hb_buf);

        for (codepoints, 0..) |cp, i| {
            c.hb_buffer_add(self.hb_buf, @intCast(cp), @intCast(i));
        }

        c.hb_buffer_set_content_type(self.hb_buf, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
        c.hb_buffer_set_direction(self.hb_buf, c.HB_DIRECTION_LTR);
        c.hb_buffer_guess_segment_properties(self.hb_buf);

        c.hb_shape(self.hb_font, self.hb_buf, &self.features, self.num_features);

        var glyph_count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(self.hb_buf, &glyph_count);
        const positions = c.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);

        if (glyph_count == 0) {
            return try self.allocator.alloc(ShapedGlyph, 0);
        }

        const result = try self.allocator.alloc(ShapedGlyph, glyph_count);
        errdefer self.allocator.free(result);

        for (0..glyph_count) |i| {
            result[i] = ShapedGlyph{
                .glyph_id = infos[i].codepoint,
                .cluster = infos[i].cluster,
                .x_advance = @intCast(@as(i32, @intCast(positions[i].x_advance >> 6))),
                .x_offset = @intCast(@as(i32, @intCast(positions[i].x_offset >> 6))),
                .y_offset = @intCast(@as(i32, @intCast(positions[i].y_offset >> 6))),
                .num_chars = 0, // computed below
            };
        }

        // Compute num_chars: how many source codepoints each glyph covers.
        const total_codepoints: u32 = @intCast(codepoints.len);
        for (0..glyph_count) |i| {
            const next_cluster = if (i + 1 < glyph_count) result[i + 1].cluster else total_codepoints;
            result[i].num_chars = next_cluster - result[i].cluster;
        }

        return result;
    }
};
