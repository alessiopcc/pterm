/// Font collection with ordered fallback chain (D-09).
///
/// Manages multiple Rasterizer instances (one per font in the fallback chain)
/// and a shared GlyphAtlas. Resolves any codepoint to an atlas region by
/// trying fonts in order until one can rasterize it.
const std = @import("std");
const font_types = @import("font_types");
const GlyphAtlas = @import("glyph_atlas").GlyphAtlas;
const CachedGlyph = @import("glyph_atlas").CachedGlyph;
const Rasterizer = @import("rasterizer").Rasterizer;
const discovery = @import("discovery");
const Shaper = @import("shaper").Shaper;

const GlyphKey = font_types.GlyphKey;
const AtlasRegion = font_types.AtlasRegion;
const FontMetrics = font_types.FontMetrics;
const FontConfig = font_types.FontConfig;

/// Result of resolving a glyph through the fallback chain.
pub const GlyphResult = struct {
    region: AtlasRegion,
    bearing_x: i32,
    bearing_y: i32,
};

/// A font handle in the fallback chain.
const FontEntry = struct {
    rasterizer: Rasterizer,
    /// Owned path (freed on deinit).
    path: ?[]const u8,
};

pub const FontGrid = struct {
    allocator: std.mem.Allocator,
    fonts: std.ArrayListUnmanaged(FontEntry),
    atlas: GlyphAtlas,
    config: FontConfig,
    metrics: FontMetrics,
    shaper: Shaper,
    emoji_font_index: ?u8,

    /// Initialize the font grid with the given configuration.
    /// Discovers and loads fonts, creating the fallback chain.
    pub fn init(allocator: std.mem.Allocator, config: FontConfig) !FontGrid {
        var fonts: std.ArrayListUnmanaged(FontEntry) = .empty;
        errdefer {
            for (fonts.items) |*entry| {
                entry.rasterizer.deinit();
                if (entry.path) |p| allocator.free(p);
            }
            fonts.deinit(allocator);
        }

        const dpi: u32 = @intFromFloat(@round(96.0 * config.dpi_scale));

        // Try to load the configured primary font.
        if (config.family) |family| {
            if (discovery.discoverFont(allocator, family)) |result| {
                if (loadFont(allocator, result, config.size_pt, dpi)) |entry| {
                    try fonts.append(allocator, entry);
                }
            }
        }

        // If no primary font loaded, try platform defaults.
        if (fonts.items.len == 0) {
            if (discovery.discoverDefaultMonospace(allocator)) |result| {
                if (loadFont(allocator, result, config.size_pt, dpi)) |entry| {
                    try fonts.append(allocator, entry);
                }
            }
        }

        if (fonts.items.len == 0) {
            return error.NoMonospaceFont;
        }

        // Create HarfBuzz shaper from the primary font face (fail-fast: a terminal
        // without text shaping cannot render correctly).
        // Use @ptrCast to bridge FT_Face types from different cimport modules
        // (rasterizer and shaper each have their own @cImport of freetype).
        const raw_face = fonts.items[0].rasterizer.getFace();
        var shaper = Shaper.init(allocator, @ptrCast(raw_face));
        errdefer shaper.deinit();

        // Discover and append emoji font to fallback chain.
        var emoji_font_index: ?u8 = null;
        if (discovery.discoverEmojiFont(allocator)) |result| {
            if (loadFont(allocator, result, config.size_pt, dpi)) |entry| {
                emoji_font_index = @intCast(fonts.items.len);
                try fonts.append(allocator, entry);
            }
        } else {
            std.log.warn("emoji font not found, emoji will render as missing glyph rectangles", .{});
        }

        var atlas = try GlyphAtlas.init(allocator, 1024);
        errdefer atlas.deinit();

        const metrics = fonts.items[0].rasterizer.getMetrics();

        return FontGrid{
            .allocator = allocator,
            .fonts = fonts,
            .atlas = atlas,
            .config = config,
            .metrics = metrics,
            .shaper = shaper,
            .emoji_font_index = emoji_font_index,
        };
    }

    /// Release all resources.
    pub fn deinit(self: *FontGrid) void {
        self.shaper.deinit();
        for (self.fonts.items) |*entry| {
            entry.rasterizer.deinit();
            if (entry.path) |p| self.allocator.free(p);
        }
        self.fonts.deinit(self.allocator);
        self.atlas.deinit();
        self.* = undefined;
    }

    /// Resolve a codepoint to an atlas region through the fallback chain.
    /// Tries each font in order; first one that has the glyph wins (D-09).
    pub fn getGlyph(self: *FontGrid, codepoint: u21) !GlyphResult {
        // Try each font in the fallback chain.
        for (self.fonts.items, 0..) |*entry, font_idx| {
            const key = GlyphKey{
                .font_index = @intCast(font_idx),
                .glyph_id = @as(u32, codepoint),
                .size_px = @intFromFloat(@round(self.config.size_pt * self.config.dpi_scale)),
            };

            // Check atlas cache.
            if (self.atlas.lookup(key)) |cached| {
                return GlyphResult{
                    .region = cached.region,
                    .bearing_x = cached.bearing_x,
                    .bearing_y = cached.bearing_y,
                };
            }

            // Try rasterizing.
            const bitmap = entry.rasterizer.rasterizeGlyph(self.allocator, codepoint) catch |err| {
                if (err == error.GlyphNotFound) continue;
                return err;
            };
            defer if (bitmap.data.len > 0) self.allocator.free(bitmap.data);

            const cached = try self.atlas.insert(key, bitmap);
            return GlyphResult{
                .region = cached.region,
                .bearing_x = cached.bearing_x,
                .bearing_y = cached.bearing_y,
            };
        }

        return error.GlyphNotFound;
    }

    /// Return metrics from the primary font (index 0).
    pub fn getMetrics(self: *const FontGrid) FontMetrics {
        return self.metrics;
    }

    /// Return atlas reference for GPU texture upload.
    pub fn getAtlas(self: *const FontGrid) *const GlyphAtlas {
        return &self.atlas;
    }

    /// Return mutable atlas reference for dirty flag management.
    pub fn getAtlasMut(self: *FontGrid) *GlyphAtlas {
        return &self.atlas;
    }

    /// Change font size. Clamps to min/max from config.
    /// Invalidates the atlas and recomputes metrics.
    pub fn setSize(self: *FontGrid, size_pt: f32) !void {
        const clamped = @max(self.config.min_size_pt, @min(self.config.max_size_pt, size_pt));
        self.config.size_pt = clamped;

        const dpi: u32 = @intFromFloat(@round(96.0 * self.config.dpi_scale));

        // Update all rasterizers.
        for (self.fonts.items) |*entry| {
            try entry.rasterizer.setSize(clamped, dpi);
        }

        // Notify shaper that the underlying FreeType face size changed.
        self.shaper.fontChanged();

        // Clear and rebuild atlas (full invalidation per UI-SPEC).
        self.atlas.clear();

        // Recompute metrics from primary font.
        self.metrics = self.fonts.items[0].rasterizer.getMetrics();
    }

    /// Resolve a glyph by its font-internal glyph ID (post-shaping).
    /// When `color` is true, stores in the color (RGBA) atlas for emoji.
    pub fn getGlyphByID(self: *FontGrid, font_index: u8, glyph_id: u32, color: bool) !GlyphResult {
        const key = GlyphKey{
            .font_index = font_index,
            .glyph_id = glyph_id,
            .size_px = @intFromFloat(@round(self.config.size_pt * self.config.dpi_scale)),
        };

        if (color) {
            if (self.atlas.lookupColor(key)) |cached| {
                return GlyphResult{
                    .region = cached.region,
                    .bearing_x = cached.bearing_x,
                    .bearing_y = cached.bearing_y,
                };
            }

            if (font_index >= self.fonts.items.len) return error.GlyphNotFound;
            const bitmap = try self.fonts.items[font_index].rasterizer.rasterizeGlyphByID(self.allocator, glyph_id, true);
            defer if (bitmap.data.len > 0) self.allocator.free(bitmap.data);

            const cached = try self.atlas.insertColor(key, bitmap);
            return GlyphResult{
                .region = cached.region,
                .bearing_x = cached.bearing_x,
                .bearing_y = cached.bearing_y,
            };
        } else {
            if (self.atlas.lookup(key)) |cached| {
                return GlyphResult{
                    .region = cached.region,
                    .bearing_x = cached.bearing_x,
                    .bearing_y = cached.bearing_y,
                };
            }

            if (font_index >= self.fonts.items.len) return error.GlyphNotFound;
            const bitmap = try self.fonts.items[font_index].rasterizer.rasterizeGlyphByID(self.allocator, glyph_id, false);
            defer if (bitmap.data.len > 0) self.allocator.free(bitmap.data);

            const cached = try self.atlas.insert(key, bitmap);
            return GlyphResult{
                .region = cached.region,
                .bearing_x = cached.bearing_x,
                .bearing_y = cached.bearing_y,
            };
        }
    }

    /// Return atlas reference (holds both grayscale and color data).
    pub fn getColorAtlas(self: *const FontGrid) *const GlyphAtlas {
        return &self.atlas;
    }

    /// Return a mutable pointer to the HarfBuzz shaper (non-optional, fail-fast on init).
    pub fn getShaper(self: *FontGrid) *Shaper {
        return &self.shaper;
    }

    /// Return the emoji font index in the fallback chain, or null if no emoji font loaded.
    pub fn getEmojiFontIndex(self: *const FontGrid) ?u8 {
        return self.emoji_font_index;
    }

    /// Number of fonts in the fallback chain.
    pub fn getFontCount(self: *const FontGrid) u8 {
        return @intCast(self.fonts.items.len);
    }

    // -- internal helpers --

    fn loadFont(allocator: std.mem.Allocator, result: discovery.DiscoverResult, size_pt: f32, dpi: u32) ?FontEntry {
        // Create a null-terminated path for FreeType.
        const path_z = allocator.dupeZ(u8, result.path) catch {
            allocator.free(result.path);
            return null;
        };
        defer allocator.free(path_z);

        const rast = Rasterizer.init(allocator, path_z.ptr, size_pt, dpi) catch {
            allocator.free(result.path);
            return null;
        };

        return FontEntry{
            .rasterizer = rast,
            .path = result.path,
        };
    }
};
