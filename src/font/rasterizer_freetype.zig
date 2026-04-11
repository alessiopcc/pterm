/// FreeType rasterization backend for Linux/Windows.
///
/// Wraps the FreeType C API to rasterize individual glyphs into bitmaps
/// and compute font metrics for cell grid sizing.
const std = @import("std");
const font_types = @import("font_types");

const GlyphBitmap = font_types.GlyphBitmap;
const FontMetrics = font_types.FontMetrics;

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const FreeTypeRasterizer = struct {
    library: c.FT_Library,
    face: c.FT_Face,
    allocator: std.mem.Allocator,
    /// Retained copy of font file data for FT_New_Memory_Face (must outlive face).
    retained_data: ?[]const u8,

    /// Initialize from a font file path.
    pub fn init(allocator: std.mem.Allocator, font_path: [*:0]const u8, size_pt: f32, dpi: u32) !FreeTypeRasterizer {
        var library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(library);

        var face: c.FT_Face = null;
        if (c.FT_New_Face(library, font_path, 0, &face) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_Face(face);

        var self = FreeTypeRasterizer{
            .library = library,
            .face = face,
            .allocator = allocator,
            .retained_data = null,
        };
        try self.setSizeInternal(size_pt, dpi);
        return self;
    }

    /// Initialize from in-memory font data.
    pub fn initFromMemory(allocator: std.mem.Allocator, data: []const u8, size_pt: f32, dpi: u32) !FreeTypeRasterizer {
        var library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(library);

        // Copy data so it outlives the face (FreeType requires the buffer to persist).
        const owned = try allocator.dupe(u8, data);
        errdefer allocator.free(owned);

        var face: c.FT_Face = null;
        if (c.FT_New_Memory_Face(library, owned.ptr, @intCast(owned.len), 0, &face) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_Face(face);

        var self = FreeTypeRasterizer{
            .library = library,
            .face = face,
            .allocator = allocator,
            .retained_data = owned,
        };
        try self.setSizeInternal(size_pt, dpi);
        return self;
    }

    /// Release all FreeType resources.
    pub fn deinit(self: *FreeTypeRasterizer) void {
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.library);
        if (self.retained_data) |d| {
            self.allocator.free(d);
        }
        self.* = undefined;
    }

    /// Rasterize a single glyph for the given codepoint.
    /// Returns error.GlyphNotFound if the font does not contain this codepoint.
    pub fn rasterizeGlyph(self: *FreeTypeRasterizer, allocator: std.mem.Allocator, codepoint: u21) !GlyphBitmap {
        const glyph_index = c.FT_Get_Char_Index(self.face, @as(c.FT_ULong, codepoint));
        if (glyph_index == 0) return error.GlyphNotFound;

        if (c.FT_Load_Glyph(self.face, glyph_index, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT) != 0) {
            return error.GlyphRenderFailed;
        }

        const slot = self.face.*.glyph;
        const bitmap = slot.*.bitmap;

        const width: u32 = bitmap.width;
        const height: u32 = bitmap.rows;

        // Copy bitmap buffer to owned memory (FreeType buffer is transient).
        const pixel_count = @as(usize, width) * @as(usize, height);
        const data = if (pixel_count > 0) blk: {
            const buf = try allocator.alloc(u8, pixel_count);
            if (bitmap.buffer != null) {
                // Handle pitch != width (bitmap rows may have padding).
                const pitch: usize = @intCast(@as(u32, @bitCast(bitmap.pitch)));
                if (pitch == width) {
                    @memcpy(buf, bitmap.buffer[0..pixel_count]);
                } else {
                    for (0..height) |row| {
                        const src_offset = row * pitch;
                        const dst_offset = row * @as(usize, width);
                        @memcpy(buf[dst_offset .. dst_offset + width], bitmap.buffer[src_offset .. src_offset + width]);
                    }
                }
            } else {
                @memset(buf, 0);
            }
            break :blk buf;
        } else blk: {
            break :blk @as([]u8, &.{});
        };

        return GlyphBitmap{
            .data = data,
            .width = width,
            .height = height,
            .bearing_x = @intCast(@as(i32, @intCast(slot.*.bitmap_left))),
            .bearing_y = @intCast(@as(i32, @intCast(slot.*.bitmap_top))),
            .advance = @intCast(@as(u32, @intCast(slot.*.advance.x >> 6))),
        };
    }

    /// Compute font metrics from the loaded face.
    pub fn getMetrics(self: *FreeTypeRasterizer) FontMetrics {
        const metrics = self.face.*.size.*.metrics;

        const ascender: f32 = @floatFromInt(@as(i32, @intCast(metrics.ascender >> 6)));
        const descender_raw: f32 = @floatFromInt(@as(i32, @intCast(metrics.descender >> 6)));
        const descender = @abs(descender_raw);
        const height_raw: f32 = @floatFromInt(@as(i32, @intCast(metrics.height >> 6)));
        const line_gap = height_raw - ascender - descender;

        // cell_width = max advance width across ASCII printable range.
        var max_advance: f32 = 0;
        for (0x20..0x7F) |cp| {
            const glyph_index = c.FT_Get_Char_Index(self.face, @intCast(cp));
            if (glyph_index == 0) continue;
            if (c.FT_Load_Glyph(self.face, glyph_index, c.FT_LOAD_DEFAULT) != 0) continue;
            const adv: f32 = @floatFromInt(@as(i32, @intCast(self.face.*.glyph.*.advance.x >> 6)));
            if (adv > max_advance) max_advance = adv;
        }

        const cell_height = ascender + descender + @max(line_gap, 0);
        const underline_thickness = @max(@as(f32, 1.0), @round(cell_height / 14.0));

        return FontMetrics{
            .cell_width = max_advance,
            .cell_height = cell_height,
            .baseline_y = ascender,
            .ascender = ascender,
            .descender = descender,
            .line_gap = @max(line_gap, 0),
            .underline_offset = descender + 1.0,
            .underline_thickness = underline_thickness,
            .strikethrough_offset = ascender / 3.0,
        };
    }

    /// Change the font size.
    pub fn setSize(self: *FreeTypeRasterizer, size_pt: f32, dpi: u32) !void {
        try self.setSizeInternal(size_pt, dpi);
    }

    /// Check whether the font contains a glyph for the given codepoint.
    pub fn hasGlyph(self: *FreeTypeRasterizer, codepoint: u21) bool {
        return c.FT_Get_Char_Index(self.face, @as(c.FT_ULong, codepoint)) != 0;
    }

    // -- internal helpers --

    fn setSizeInternal(self: *FreeTypeRasterizer, size_pt: f32, dpi: u32) !void {
        // FreeType uses 26.6 fixed point for char size (1/64th of a point).
        const char_size: c.FT_F26Dot6 = @intFromFloat(size_pt * 64.0);
        if (c.FT_Set_Char_Size(self.face, 0, char_size, dpi, dpi) != 0) {
            return error.SetSizeFailed;
        }
    }
};
