/// Shared types for the font subsystem.

/// Glyph bitmap pixel format.
pub const GlyphFormat = enum { grayscale, rgba };

/// Result of rasterizing a single glyph via FreeType.
pub const GlyphBitmap = struct {
    data: []const u8,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: u32,
    format: GlyphFormat = .grayscale,
};

/// Cache key for glyph atlas lookup.
/// The `is_glyph_index` field disambiguates between codepoint-based lookups
/// (getGlyph, where glyph_id is a Unicode codepoint) and glyph-index-based
/// lookups (getGlyphByID, where glyph_id is a font-internal glyph index
/// from HarfBuzz shaping). Without this, the two namespaces collide: e.g.
/// HarfBuzz glyph index 101 for 'L' would hit the cached bitmap for 'e'
/// (Unicode codepoint 101), causing wrong characters to render.
pub const GlyphKey = struct {
    font_index: u8,
    glyph_id: u32,
    size_px: u16,
    is_glyph_index: bool = false,
};

/// Region within the glyph atlas texture.
pub const AtlasRegion = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

/// Font metrics computed from the primary font, used for cell grid sizing.
pub const FontMetrics = struct {
    cell_width: f32,
    cell_height: f32,
    baseline_y: f32,
    ascender: f32,
    descender: f32,
    line_gap: f32,
    underline_offset: f32,
    underline_thickness: f32,
    strikethrough_offset: f32,
};

/// Font configuration (subset of TOML config relevant to font pipeline).
pub const FontConfig = struct {
    family: ?[]const u8 = null,
    size_pt: f32 = 13.0,
    min_size_pt: f32 = 6.0,
    max_size_pt: f32 = 72.0,
    dpi_scale: f32 = 1.0,
};
