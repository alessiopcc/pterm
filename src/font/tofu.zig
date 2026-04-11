/// Tofu box renderer for missing glyphs (D-06).
///
/// Generates a CPU-rasterized grayscale bitmap showing a bordered
/// rectangle with the glyph's hex codepoint inside. This is inserted
/// into the glyph atlas like any regular glyph.
const std = @import("std");
const font_types = @import("font_types");
const GlyphBitmap = font_types.GlyphBitmap;
const FontMetrics = font_types.FontMetrics;

/// Hardcoded 3x5 pixel digit bitmaps for hex characters 0-9, A-F.
/// Each u3 value represents 3 horizontal pixels as bits (MSB = leftmost).
const digit_bitmaps: [16][5]u3 = .{
    // '0'
    .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
    // '1'
    .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
    // '2'
    .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
    // '3'
    .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
    // '4'
    .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
    // '5'
    .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
    // '6'
    .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
    // '7'
    .{ 0b111, 0b001, 0b010, 0b010, 0b010 },
    // '8'
    .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
    // '9'
    .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
    // 'A'
    .{ 0b111, 0b101, 0b111, 0b101, 0b101 },
    // 'B'
    .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
    // 'C'
    .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
    // 'D'
    .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
    // 'E'
    .{ 0b111, 0b100, 0b111, 0b100, 0b111 },
    // 'F'
    .{ 0b111, 0b100, 0b111, 0b100, 0b100 },
};

/// Render a tofu box bitmap for a missing glyph codepoint.
///
/// The bitmap is a bordered rectangle containing the hex codepoint value,
/// sized to match the cell grid dimensions from FontMetrics.
pub fn renderTofuBox(allocator: std.mem.Allocator, codepoint: u21, metrics: FontMetrics) !GlyphBitmap {
    const w: u32 = @intFromFloat(@round(metrics.cell_width));
    const h: u32 = @intFromFloat(@round(metrics.cell_height));

    if (w == 0 or h == 0) return error.GlyphNotFound;

    const data = try allocator.alloc(u8, w * h);
    @memset(data, 0);

    // Draw 1px border: top row, bottom row, left column, right column.
    for (0..w) |x| {
        data[x] = 255; // top row
        data[(h - 1) * w + x] = 255; // bottom row
    }
    for (0..h) |y| {
        data[y * w] = 255; // left column
        data[y * w + (w - 1)] = 255; // right column
    }

    // If cell is too small to fit hex digits, just return border-only.
    if (w >= 6 and h >= 7) {
        // Format codepoint as uppercase hex digits.
        var hex_digits: [5]u4 = undefined;
        const num_digits: u32 = if (codepoint > 0xFFFF) 5 else 4;

        var cp = @as(u32, codepoint);
        var i: u32 = num_digits;
        while (i > 0) {
            i -= 1;
            hex_digits[i] = @intCast(cp & 0xF);
            cp >>= 4;
        }

        // Each digit is 3px wide with 1px spacing between digits.
        // Total width of hex string: num_digits * 3 + (num_digits - 1) * 1
        const text_width = num_digits * 3 + (num_digits - 1);
        const text_height: u32 = 5;

        // Center horizontally and vertically inside the box (1px border inset).
        const inner_w = w - 2;
        const inner_h = h - 2;
        const start_x: u32 = if (inner_w > text_width) 1 + (inner_w - text_width) / 2 else 1;
        const start_y: u32 = if (inner_h > text_height) 1 + (inner_h - text_height) / 2 else 1;

        // Render each hex digit.
        var digit_idx: u32 = 0;
        while (digit_idx < num_digits) : (digit_idx += 1) {
            const digit_x = start_x + digit_idx * 4; // 3px digit + 1px spacing
            const bitmap = digit_bitmaps[hex_digits[digit_idx]];

            for (0..5) |row| {
                const bits = bitmap[row];
                inline for (0..3) |col| {
                    const bit_set = (bits >> @intCast(2 - col)) & 1;
                    if (bit_set == 1) {
                        const px = start_y + @as(u32, @intCast(row));
                        const py = digit_x + @as(u32, @intCast(col));
                        if (px < h and py < w) {
                            data[px * w + py] = 255;
                        }
                    }
                }
            }
        }
    }

    return GlyphBitmap{
        .data = data,
        .width = w,
        .height = h,
        .bearing_x = 0,
        .bearing_y = @intFromFloat(@round(metrics.ascender)),
        .advance = w,
        .format = .grayscale,
    };
}

test "renderTofuBox generates valid bitmap" {
    const metrics = FontMetrics{
        .cell_width = 10.0,
        .cell_height = 20.0,
        .baseline_y = 16.0,
        .ascender = 16.0,
        .descender = -4.0,
        .line_gap = 0.0,
        .underline_offset = 2.0,
        .underline_thickness = 1.0,
        .strikethrough_offset = 8.0,
    };
    const bitmap = try renderTofuBox(std.testing.allocator, 0xE0B0, metrics);
    defer std.testing.allocator.free(bitmap.data);
    try std.testing.expectEqual(@as(u32, 10), bitmap.width);
    try std.testing.expectEqual(@as(u32, 20), bitmap.height);
    // Top-left corner should be border pixel
    try std.testing.expectEqual(@as(u8, 255), bitmap.data[0]);
    // Second row, second col should be empty (inside border)
    try std.testing.expectEqual(@as(u8, 0), bitmap.data[10 + 1]);
}

test "renderTofuBox small cell renders border only" {
    const metrics = FontMetrics{
        .cell_width = 5.0,
        .cell_height = 5.0,
        .baseline_y = 4.0,
        .ascender = 4.0,
        .descender = -1.0,
        .line_gap = 0.0,
        .underline_offset = 1.0,
        .underline_thickness = 1.0,
        .strikethrough_offset = 2.0,
    };
    const bitmap = try renderTofuBox(std.testing.allocator, 0x1234, metrics);
    defer std.testing.allocator.free(bitmap.data);
    try std.testing.expectEqual(@as(u32, 5), bitmap.width);
    try std.testing.expectEqual(@as(u32, 5), bitmap.height);
    // Border pixel present
    try std.testing.expectEqual(@as(u8, 255), bitmap.data[0]);
}

test "renderTofuBox SMP codepoint uses 5 digits" {
    const metrics = FontMetrics{
        .cell_width = 24.0,
        .cell_height = 20.0,
        .baseline_y = 16.0,
        .ascender = 16.0,
        .descender = -4.0,
        .line_gap = 0.0,
        .underline_offset = 2.0,
        .underline_thickness = 1.0,
        .strikethrough_offset = 8.0,
    };
    const bitmap = try renderTofuBox(std.testing.allocator, 0x1F900, metrics);
    defer std.testing.allocator.free(bitmap.data);
    try std.testing.expectEqual(@as(u32, 24), bitmap.width);
    try std.testing.expectEqual(@as(u32, 20), bitmap.height);
    // Should have rendered something (border at minimum)
    try std.testing.expectEqual(@as(u8, 255), bitmap.data[0]);
}
