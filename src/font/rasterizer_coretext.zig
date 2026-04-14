/// CoreText rasterization backend for macOS (D-07).
///
/// Uses macOS CoreText + CoreGraphics C APIs to rasterize glyphs
/// and compute font metrics. This backend is selected at comptime
/// on macOS via src/font/Rasterizer.zig.
const std = @import("std");
const font_types = @import("font_types");

const GlyphBitmap = font_types.GlyphBitmap;
const FontMetrics = font_types.FontMetrics;

const c = @cImport({
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const CoreTextRasterizer = struct {
    font: c.CTFontRef,
    allocator: std.mem.Allocator,
    size_pt: f32,
    dpi: u32,
    /// Retained data provider for memory-loaded fonts.
    data_provider: ?c.CGDataProviderRef,
    /// Retained CGFont for memory-loaded fonts.
    cg_font: ?c.CGFontRef,
    /// FreeType library handle (kept alive for HarfBuzz shaping via hb-ft).
    ft_library: c.FT_Library,
    /// FreeType face (kept alive for HarfBuzz shaping via hb-ft).
    ft_face: c.FT_Face,
    /// Retained copy of font data for FT_New_Memory_Face (must outlive face).
    ft_retained_data: ?[]const u8,

    /// Initialize from a font file path.
    pub fn init(allocator: std.mem.Allocator, font_path: [*:0]const u8, size_pt: f32, dpi: u32) !CoreTextRasterizer {
        const scaled_size = size_pt * @as(f32, @floatFromInt(dpi)) / 72.0;

        // Create CFURL from file path.
        const path_cfstr = c.CFStringCreateWithCString(null, font_path, c.kCFStringEncodingUTF8);
        if (path_cfstr == null) return error.FontLoadFailed;
        defer c.CFRelease(path_cfstr);

        const url = c.CFURLCreateWithFileSystemPath(null, path_cfstr, c.kCFURLPOSIXPathStyle, @as(c.Boolean, 0));
        if (url == null) return error.FontLoadFailed;
        defer c.CFRelease(url);

        // Create font descriptors from the file URL.
        const descriptors = c.CTFontManagerCreateFontDescriptorsFromURL(url);
        if (descriptors == null) return error.FontLoadFailed;
        defer c.CFRelease(descriptors);

        if (c.CFArrayGetCount(descriptors) == 0) return error.FontLoadFailed;

        const desc = @as(c.CTFontDescriptorRef, @ptrCast(c.CFArrayGetValueAtIndex(descriptors, 0)));
        const ct_font = c.CTFontCreateWithFontDescriptor(desc, @as(c.CGFloat, scaled_size), null);
        if (ct_font == null) return error.FontLoadFailed;

        // Also create a FreeType face for HarfBuzz shaping (hb-ft bridge).
        var ft_library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&ft_library) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_FreeType(ft_library);

        var ft_face: c.FT_Face = null;
        if (c.FT_New_Face(ft_library, font_path, 0, &ft_face) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_Face(ft_face);

        const ft_size = @as(c_long, @intFromFloat(@round(scaled_size * 64.0)));
        if (c.FT_Set_Char_Size(ft_face, 0, ft_size, dpi, dpi) != 0) return error.FontLoadFailed;

        return CoreTextRasterizer{
            .font = ct_font,
            .allocator = allocator,
            .size_pt = size_pt,
            .dpi = dpi,
            .data_provider = null,
            .cg_font = null,
            .ft_library = ft_library,
            .ft_face = ft_face,
            .ft_retained_data = null,
        };
    }

    /// Initialize from in-memory font data.
    pub fn initFromMemory(allocator: std.mem.Allocator, data: []const u8, size_pt: f32, dpi: u32) !CoreTextRasterizer {
        const scaled_size = size_pt * @as(f32, @floatFromInt(dpi)) / 72.0;

        const provider = c.CGDataProviderCreateWithData(null, data.ptr, data.len, null);
        if (provider == null) return error.FontLoadFailed;
        errdefer c.CGDataProviderRelease(provider);

        const cg_font = c.CGFontCreateWithDataProvider(provider);
        if (cg_font == null) return error.FontLoadFailed;
        errdefer c.CGFontRelease(cg_font);

        const ct_font = c.CTFontCreateWithGraphicsFont(cg_font, @as(c.CGFloat, scaled_size), null, null);
        if (ct_font == null) return error.FontLoadFailed;

        // Also create a FreeType face for HarfBuzz shaping (hb-ft bridge).
        var ft_library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&ft_library) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_FreeType(ft_library);

        // Copy data so it outlives the FT_Face.
        const ft_data = try allocator.dupe(u8, data);
        errdefer allocator.free(ft_data);

        var ft_face: c.FT_Face = null;
        if (c.FT_New_Memory_Face(ft_library, ft_data.ptr, @intCast(ft_data.len), 0, &ft_face) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_Face(ft_face);

        const ft_size = @as(c_long, @intFromFloat(@round(scaled_size * 64.0)));
        if (c.FT_Set_Char_Size(ft_face, 0, ft_size, dpi, dpi) != 0) return error.FontLoadFailed;

        return CoreTextRasterizer{
            .font = ct_font,
            .allocator = allocator,
            .size_pt = size_pt,
            .dpi = dpi,
            .data_provider = provider,
            .cg_font = cg_font,
            .ft_library = ft_library,
            .ft_face = ft_face,
            .ft_retained_data = ft_data,
        };
    }

    /// Release all CoreText/CoreGraphics/FreeType resources.
    pub fn deinit(self: *CoreTextRasterizer) void {
        _ = c.FT_Done_Face(self.ft_face);
        _ = c.FT_Done_FreeType(self.ft_library);
        if (self.ft_retained_data) |d| self.allocator.free(d);
        c.CFRelease(self.font);
        if (self.cg_font) |cg| c.CGFontRelease(cg);
        if (self.data_provider) |dp| c.CGDataProviderRelease(dp);
        self.* = undefined;
    }

    /// Return the underlying FreeType face for HarfBuzz font creation.
    pub fn getFace(self: *CoreTextRasterizer) c.FT_Face {
        return self.ft_face;
    }

    /// Rasterize a single glyph for the given codepoint.
    pub fn rasterizeGlyph(self: *CoreTextRasterizer, allocator: std.mem.Allocator, codepoint: u21) !GlyphBitmap {
        // Map codepoint to glyph.
        var chars: [2]u16 = undefined;
        var glyphs: [2]c.CGGlyph = undefined;
        var char_count: usize = 1;

        if (codepoint <= 0xFFFF) {
            chars[0] = @intCast(codepoint);
        } else {
            // Surrogate pair for codepoints > 0xFFFF.
            const cp = codepoint - 0x10000;
            chars[0] = @intCast(0xD800 + (cp >> 10));
            chars[1] = @intCast(0xDC00 + (cp & 0x3FF));
            char_count = 2;
        }

        if (!c.CTFontGetGlyphsForCharacters(self.font, &chars, &glyphs, @intCast(char_count))) {
            return error.GlyphNotFound;
        }

        // Get bounding box.
        var bounding_rect: c.CGRect = undefined;
        _ = c.CTFontGetBoundingRectsForGlyphs(self.font, c.kCTFontOrientationDefault, &glyphs, &bounding_rect, 1);

        const width: u32 = @intFromFloat(@ceil(bounding_rect.size.width));
        const height: u32 = @intFromFloat(@ceil(bounding_rect.size.height));

        if (width == 0 or height == 0) {
            // Space-like glyph with no visual representation.
            var advance: c.CGSize = undefined;
            _ = c.CTFontGetAdvancesForGlyphs(self.font, c.kCTFontOrientationDefault, &glyphs, &advance, 1);
            return GlyphBitmap{
                .data = &.{},
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = @intFromFloat(@round(advance.width)),
            };
        }

        // Create bitmap context (8-bit grayscale).
        const buf = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
        @memset(buf, 0);

        const colorspace = c.CGColorSpaceCreateDeviceGray();
        defer c.CGColorSpaceRelease(colorspace);

        const ctx = c.CGBitmapContextCreate(
            buf.ptr,
            width,
            height,
            8,
            width,
            colorspace,
            c.kCGImageAlphaNone,
        );
        if (ctx == null) {
            allocator.free(buf);
            return error.GlyphRenderFailed;
        }
        defer c.CGContextRelease(ctx);

        // Set white text on transparent background.
        c.CGContextSetGrayFillColor(ctx, 1.0, 1.0);

        // Position glyph so bearing is accounted for.
        const origin_x: c.CGFloat = -bounding_rect.origin.x;
        const origin_y: c.CGFloat = -bounding_rect.origin.y;
        var position = c.CGPoint{ .x = origin_x, .y = origin_y };

        c.CTFontDrawGlyphs(self.font, &glyphs, &position, 1, ctx);

        // Get advance.
        var advance: c.CGSize = undefined;
        _ = c.CTFontGetAdvancesForGlyphs(self.font, c.kCTFontOrientationDefault, &glyphs, &advance, 1);

        return GlyphBitmap{
            .data = buf,
            .width = width,
            .height = height,
            .bearing_x = @intFromFloat(@round(bounding_rect.origin.x)),
            .bearing_y = @intFromFloat(@round(bounding_rect.origin.y + bounding_rect.size.height)),
            .advance = @intFromFloat(@round(advance.width)),
        };
    }

    /// Rasterize a single glyph with color (emoji) support.
    /// CoreText always renders in grayscale via CGBitmapContext, so this
    /// delegates to the standard rasterizeGlyph path.
    pub fn rasterizeGlyphColor(self: *CoreTextRasterizer, allocator: std.mem.Allocator, codepoint: u21) !GlyphBitmap {
        return self.rasterizeGlyph(allocator, codepoint);
    }

    /// Rasterize a glyph by its CoreText glyph index (not codepoint).
    /// When `color` is true, attempts color rendering (currently same path).
    pub fn rasterizeGlyphByID(self: *CoreTextRasterizer, allocator: std.mem.Allocator, glyph_id: u32, color: bool) !GlyphBitmap {
        _ = color;
        const glyph: c.CGGlyph = @intCast(glyph_id);

        // Get bounding box.
        var bounding_rect: c.CGRect = undefined;
        _ = c.CTFontGetBoundingRectsForGlyphs(self.font, c.kCTFontOrientationDefault, &glyph, &bounding_rect, 1);

        const width: u32 = @intFromFloat(@ceil(bounding_rect.size.width));
        const height: u32 = @intFromFloat(@ceil(bounding_rect.size.height));

        if (width == 0 or height == 0) {
            var advance: c.CGSize = undefined;
            _ = c.CTFontGetAdvancesForGlyphs(self.font, c.kCTFontOrientationDefault, &glyph, &advance, 1);
            return GlyphBitmap{
                .data = &.{},
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = @intFromFloat(@round(advance.width)),
            };
        }

        const buf = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
        @memset(buf, 0);

        const colorspace = c.CGColorSpaceCreateDeviceGray();
        defer c.CGColorSpaceRelease(colorspace);

        const ctx = c.CGBitmapContextCreate(buf.ptr, width, height, 8, width, colorspace, c.kCGImageAlphaNone);
        if (ctx == null) {
            allocator.free(buf);
            return error.GlyphRenderFailed;
        }
        defer c.CGContextRelease(ctx);

        c.CGContextSetGrayFillColor(ctx, 1.0, 1.0);

        const origin_x: c.CGFloat = -bounding_rect.origin.x;
        const origin_y: c.CGFloat = -bounding_rect.origin.y;
        var position = c.CGPoint{ .x = origin_x, .y = origin_y };

        c.CTFontDrawGlyphs(self.font, &glyph, &position, 1, ctx);

        var advance: c.CGSize = undefined;
        _ = c.CTFontGetAdvancesForGlyphs(self.font, c.kCTFontOrientationDefault, &glyph, &advance, 1);

        return GlyphBitmap{
            .data = buf,
            .width = width,
            .height = height,
            .bearing_x = @intFromFloat(@round(bounding_rect.origin.x)),
            .bearing_y = @intFromFloat(@round(bounding_rect.origin.y + bounding_rect.size.height)),
            .advance = @intFromFloat(@round(advance.width)),
        };
    }

    /// Compute font metrics from the CoreText font.
    pub fn getMetrics(self: *CoreTextRasterizer) FontMetrics {
        const ascent: f32 = @floatCast(c.CTFontGetAscent(self.font));
        const descent: f32 = @floatCast(c.CTFontGetDescent(self.font));
        const leading: f32 = @floatCast(c.CTFontGetLeading(self.font));
        const underline_pos: f32 = @floatCast(@abs(c.CTFontGetUnderlinePosition(self.font)));
        const underline_thick: f32 = @max(@as(f32, 1.0), @as(f32, @floatCast(c.CTFontGetUnderlineThickness(self.font))));

        // Compute cell_width from max advance across ASCII printable range.
        var max_advance: f32 = 0;
        for (0x20..0x7F) |cp_usize| {
            const cp: u21 = @intCast(cp_usize);
            var ch: [1]u16 = .{@intCast(cp)};
            var glyph: [1]c.CGGlyph = undefined;
            if (c.CTFontGetGlyphsForCharacters(self.font, &ch, &glyph, 1)) {
                var adv: c.CGSize = undefined;
                _ = c.CTFontGetAdvancesForGlyphs(self.font, c.kCTFontOrientationDefault, &glyph, &adv, 1);
                const advance_f: f32 = @floatCast(adv.width);
                if (advance_f > max_advance) max_advance = advance_f;
            }
        }

        const cell_height = ascent + descent + leading;

        return FontMetrics{
            .cell_width = max_advance,
            .cell_height = cell_height,
            .baseline_y = ascent,
            .ascender = ascent,
            .descender = descent,
            .line_gap = leading,
            .underline_offset = underline_pos,
            .underline_thickness = underline_thick,
            .strikethrough_offset = ascent / 3.0,
        };
    }

    /// Change the font size.
    pub fn setSize(self: *CoreTextRasterizer, size_pt: f32, dpi: u32) !void {
        const scaled_size = size_pt * @as(f32, @floatFromInt(dpi)) / 72.0;
        const new_font = if (self.cg_font) |cg|
            c.CTFontCreateWithGraphicsFont(cg, @as(c.CGFloat, scaled_size), null, null)
        else
            c.CTFontCreateCopyWithAttributes(self.font, @as(c.CGFloat, scaled_size), null, null);

        if (new_font == null) return error.SetSizeFailed;
        c.CFRelease(self.font);
        self.font = new_font;
        self.size_pt = size_pt;
        self.dpi = dpi;

        // Keep FreeType face in sync for HarfBuzz shaping.
        const ft_size = @as(c_long, @intFromFloat(@round(scaled_size * 64.0)));
        if (c.FT_Set_Char_Size(self.ft_face, 0, ft_size, dpi, dpi) != 0) return error.SetSizeFailed;
    }

    /// Check whether the font contains a glyph for the given codepoint.
    pub fn hasGlyph(self: *CoreTextRasterizer, codepoint: u21) bool {
        var ch: [1]u16 = .{0};
        var glyph: [1]c.CGGlyph = undefined;
        if (codepoint <= 0xFFFF) {
            ch[0] = @intCast(codepoint);
        } else {
            return false; // Simplified -- surrogate pair check would be needed for non-BMP
        }
        return c.CTFontGetGlyphsForCharacters(self.font, &ch, &glyph, 1);
    }
};
