/// Dynamic texture atlas with shelf packing (D-08).
///
/// Packs rasterized glyph bitmaps into a single flat pixel buffer using
/// a shelf-based algorithm. The atlas grows on demand from an initial size
/// (1024) up to a maximum (4096). GPU texture upload is handled externally
/// by the OpenGL backend -- this module only manages the CPU pixel buffer
/// and the packing layout.
const std = @import("std");
const font_types = @import("font_types");

const GlyphKey = font_types.GlyphKey;
const GlyphBitmap = font_types.GlyphBitmap;
const AtlasRegion = font_types.AtlasRegion;

/// A horizontal shelf within the atlas where glyphs are packed left-to-right.
const Shelf = struct {
    y: u16,
    height: u16,
    next_x: u16,
};

/// Cached glyph entry: atlas region plus bearing info for positioning.
pub const CachedGlyph = struct {
    region: AtlasRegion,
    bearing_x: i32,
    bearing_y: i32,
    advance: u32,
};

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    size: u32,
    max_size: u32,
    shelves: std.ArrayListUnmanaged(Shelf),
    cache: std.AutoHashMapUnmanaged(GlyphKey, CachedGlyph),
    dirty: bool,

    /// Create a new atlas with the given initial dimensions (square).
    pub fn init(allocator: std.mem.Allocator, initial_size: u32) !GlyphAtlas {
        const pixel_count = @as(usize, initial_size) * @as(usize, initial_size);
        const pixels = try allocator.alloc(u8, pixel_count);
        @memset(pixels, 0);

        return GlyphAtlas{
            .allocator = allocator,
            .pixels = pixels,
            .size = initial_size,
            .max_size = 4096,
            .shelves = .empty,
            .cache = .empty,
            .dirty = false,
        };
    }

    /// Release all resources.
    pub fn deinit(self: *GlyphAtlas) void {
        self.allocator.free(self.pixels);
        self.shelves.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.* = undefined;
    }

    /// Insert a rasterized glyph bitmap into the atlas.
    /// Returns the atlas region where the glyph was placed.
    /// If the glyph is already cached, returns the cached region.
    pub fn insert(self: *GlyphAtlas, key: GlyphKey, bitmap: GlyphBitmap) !CachedGlyph {
        // Check cache first.
        if (self.cache.get(key)) |cached| {
            return cached;
        }

        const w: u16 = @intCast(bitmap.width);
        const h: u16 = @intCast(bitmap.height);

        // Handle zero-size glyphs (e.g., space).
        if (w == 0 or h == 0) {
            const entry = CachedGlyph{
                .region = AtlasRegion{ .x = 0, .y = 0, .w = 0, .h = 0 },
                .bearing_x = bitmap.bearing_x,
                .bearing_y = bitmap.bearing_y,
                .advance = bitmap.advance,
            };
            try self.cache.put(self.allocator, key, entry);
            return entry;
        }

        // Try to find an existing shelf with enough space.
        const region = try self.findOrCreateRegion(w, h);

        // Copy bitmap pixels into the atlas buffer.
        self.copyPixels(region, bitmap);
        self.dirty = true;

        const entry = CachedGlyph{
            .region = region,
            .bearing_x = bitmap.bearing_x,
            .bearing_y = bitmap.bearing_y,
            .advance = bitmap.advance,
        };
        try self.cache.put(self.allocator, key, entry);
        return entry;
    }

    /// Look up a previously cached glyph.
    pub fn lookup(self: *const GlyphAtlas, key: GlyphKey) ?CachedGlyph {
        return self.cache.get(key);
    }

    /// Return the raw pixel buffer for GPU texture upload.
    pub fn getPixels(self: *const GlyphAtlas) []const u8 {
        return self.pixels;
    }

    /// Current atlas texture dimension (square: size x size).
    pub fn getSize(self: *const GlyphAtlas) u32 {
        return self.size;
    }

    /// True if pixels changed since last GPU upload.
    pub fn isDirty(self: *const GlyphAtlas) bool {
        return self.dirty;
    }

    /// Mark the atlas as uploaded (clear dirty flag).
    pub fn clearDirty(self: *GlyphAtlas) void {
        self.dirty = false;
    }

    /// Clear all cached glyphs and shelves (used on font size change).
    pub fn clear(self: *GlyphAtlas) void {
        @memset(self.pixels, 0);
        self.shelves.clearRetainingCapacity();
        self.cache.clearRetainingCapacity();
        self.dirty = true;
    }

    // -- internal helpers --

    fn findOrCreateRegion(self: *GlyphAtlas, w: u16, h: u16) !AtlasRegion {
        // Try existing shelves.
        for (self.shelves.items) |*shelf| {
            if (shelf.height >= h and shelf.next_x + w <= @as(u16, @intCast(self.size))) {
                const region = AtlasRegion{
                    .x = shelf.next_x,
                    .y = shelf.y,
                    .w = w,
                    .h = h,
                };
                shelf.next_x += w;
                return region;
            }
        }

        // No existing shelf fits -- create a new one.
        const shelf_y: u16 = if (self.shelves.items.len > 0) blk: {
            const last = self.shelves.items[self.shelves.items.len - 1];
            break :blk last.y + last.height;
        } else 0;

        // Check if there's vertical space.
        if (@as(u32, shelf_y) + @as(u32, h) > self.size) {
            // Need to grow the atlas.
            try self.grow();
            return self.findOrCreateRegion(w, h);
        }

        try self.shelves.append(self.allocator, Shelf{
            .y = shelf_y,
            .height = h,
            .next_x = w,
        });

        return AtlasRegion{
            .x = 0,
            .y = shelf_y,
            .w = w,
            .h = h,
        };
    }

    fn grow(self: *GlyphAtlas) !void {
        const new_size = self.size * 2;
        if (new_size > self.max_size) {
            return error.AtlasFull;
        }

        const new_pixel_count = @as(usize, new_size) * @as(usize, new_size);
        const new_pixels = try self.allocator.alloc(u8, new_pixel_count);
        @memset(new_pixels, 0);

        // Copy old content row by row into the new buffer.
        const old_size = @as(usize, self.size);
        for (0..old_size) |row| {
            const old_offset = row * old_size;
            const new_offset = row * @as(usize, new_size);
            @memcpy(new_pixels[new_offset .. new_offset + old_size], self.pixels[old_offset .. old_offset + old_size]);
        }

        self.allocator.free(self.pixels);
        self.pixels = new_pixels;
        self.size = new_size;
        self.dirty = true;
    }

    fn copyPixels(self: *GlyphAtlas, region: AtlasRegion, bitmap: GlyphBitmap) void {
        const atlas_stride = @as(usize, self.size);
        const glyph_w = @as(usize, region.w);
        const glyph_h = @as(usize, region.h);
        const base_x = @as(usize, region.x);
        const base_y = @as(usize, region.y);

        for (0..glyph_h) |row| {
            const src_offset = row * glyph_w;
            const dst_offset = (base_y + row) * atlas_stride + base_x;
            @memcpy(
                self.pixels[dst_offset .. dst_offset + glyph_w],
                bitmap.data[src_offset .. src_offset + glyph_w],
            );
        }
    }
};
