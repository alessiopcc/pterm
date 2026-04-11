/// HarfBuzz text shaping wrapper (minimal for Phase 2).
///
/// Phase 2 uses direct codepoint-to-glyph via FreeType/CoreText for ASCII.
/// This is a minimal stub that will be expanded in Phase 3 for ligature
/// and complex script support using HarfBuzz.
const std = @import("std");

/// Result of shaping a single glyph.
pub const ShapedGlyph = struct {
    glyph_id: u32,
    x_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

pub const Shaper = struct {
    allocator: std.mem.Allocator,

    /// Initialize the shaper.
    /// TODO(Phase 3): Accept HarfBuzz font handle for full shaping.
    pub fn init(allocator: std.mem.Allocator) Shaper {
        return Shaper{
            .allocator = allocator,
        };
    }

    /// Release shaper resources.
    pub fn deinit(self: *Shaper) void {
        _ = self;
    }

    /// Shape a text string into positioned glyphs.
    /// TODO(Phase 3): Use hb_buffer_create, hb_buffer_add_utf8, hb_shape for
    /// proper ligature handling and complex script support.
    /// Current implementation: simple 1:1 codepoint-to-glyph passthrough.
    pub fn shape(self: *Shaper, text: []const u8) ![]ShapedGlyph {
        var result = std.ArrayListUnmanaged(ShapedGlyph).empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1;
                continue;
            };
            if (i + byte_len > text.len) break;

            const codepoint = std.unicode.utf8Decode(text[i .. i + byte_len]) catch {
                i += byte_len;
                continue;
            };

            try result.append(self.allocator, ShapedGlyph{
                .glyph_id = @intCast(codepoint),
                .x_advance = 0, // TODO(Phase 3): Get from HarfBuzz
                .x_offset = 0,
                .y_offset = 0,
            });

            i += byte_len;
        }

        return result.toOwnedSlice(self.allocator);
    }
};
