/// Shared types for the renderer subsystem.
const std = @import("std");

/// RGBA color packed into u32 (0xRRGGBBAA).
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn toU32(self: Color) u32 {
        return (@as(u32, self.r) << 24) | (@as(u32, self.g) << 16) | (@as(u32, self.b) << 8) | @as(u32, self.a);
    }

    pub fn fromU32(value: u32) Color {
        return .{
            .r = @truncate(value >> 24),
            .g = @truncate(value >> 16),
            .b = @truncate(value >> 8),
            .a = @truncate(value),
        };
    }

    pub fn eql(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }
};

/// Default color palette -- Catppuccin Mocha (from UI-SPEC).
pub const palette = struct {
    pub const default_bg = Color{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
    pub const default_fg = Color{ .r = 0xcd, .g = 0xd6, .b = 0xf4 };
    pub const cursor_color = Color{ .r = 0xf5, .g = 0xe0, .b = 0xdc };
    pub const selection_bg = Color{ .r = 0x45, .g = 0x47, .b = 0x5a };

    /// ANSI 16 normal colors (indices 0-7).
    pub const ansi_normal = [8]Color{
        .{ .r = 0x45, .g = 0x47, .b = 0x5a }, // 0: Black
        .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, // 1: Red
        .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 }, // 2: Green
        .{ .r = 0xf9, .g = 0xe2, .b = 0xaf }, // 3: Yellow
        .{ .r = 0x89, .g = 0xb4, .b = 0xfa }, // 4: Blue
        .{ .r = 0xf5, .g = 0xc2, .b = 0xe7 }, // 5: Magenta
        .{ .r = 0x94, .g = 0xe2, .b = 0xd5 }, // 6: Cyan
        .{ .r = 0xba, .g = 0xc2, .b = 0xde }, // 7: White
    };

    /// ANSI 16 bright colors (indices 8-15).
    pub const ansi_bright = [8]Color{
        .{ .r = 0x58, .g = 0x5b, .b = 0x70 }, // 8: Bright Black
        .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, // 9: Bright Red
        .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 }, // 10: Bright Green
        .{ .r = 0xf9, .g = 0xe2, .b = 0xaf }, // 11: Bright Yellow
        .{ .r = 0x89, .g = 0xb4, .b = 0xfa }, // 12: Bright Blue
        .{ .r = 0xf5, .g = 0xc2, .b = 0xe7 }, // 13: Bright Magenta
        .{ .r = 0x94, .g = 0xe2, .b = 0xd5 }, // 14: Bright Cyan
        .{ .r = 0xa6, .g = 0xad, .b = 0xc8 }, // 15: Bright White
    };

    /// Resolve a 256-color index to an RGB Color.
    /// 0-15: ANSI 16, 16-231: 6x6x6 RGB cube, 232-255: grayscale ramp.
    pub fn resolve256(index: u8) Color {
        if (index < 8) {
            return ansi_normal[index];
        } else if (index < 16) {
            return ansi_bright[index - 8];
        } else if (index < 232) {
            // 6x6x6 color cube: indices 16-231
            const cube_index = index - 16;
            const r_idx = cube_index / 36;
            const g_idx = (cube_index % 36) / 6;
            const b_idx = cube_index % 6;

            // Each channel: 0 -> 0, 1 -> 95, 2 -> 135, 3 -> 175, 4 -> 215, 5 -> 255
            const cube_values = [6]u8{ 0, 95, 135, 175, 215, 255 };
            return Color{
                .r = cube_values[r_idx],
                .g = cube_values[g_idx],
                .b = cube_values[b_idx],
            };
        } else {
            // Grayscale ramp: indices 232-255 -> 24 shades from #080808 to #eeeeee
            const gray: u8 = @intCast(@as(u16, index - 232) * 10 + 8);
            return Color{ .r = gray, .g = gray, .b = gray };
        }
    }
};

/// Bit flags for CellInstance.flags field.
pub const CellFlags = struct {
    pub const WIDE_CHAR: u16 = 0x0001;
    pub const WIDE_CONTINUATION: u16 = 0x0002;
    pub const LIGATURE_HEAD: u16 = 0x0004;
    pub const LIGATURE_CONTINUATION: u16 = 0x0008;
    pub const COLOR_GLYPH: u16 = 0x0010;
};

/// Per-cell instance data for GPU instanced rendering.
/// 32 bytes, aligned for GPU buffer upload.
pub const CellInstance = extern struct {
    grid_col: u16,
    grid_row: u16,
    atlas_x: u16,
    atlas_y: u16,
    atlas_w: u16,
    atlas_h: u16,
    bearing_x: i16,
    bearing_y: i16,
    fg_color: u32,
    bg_color: u32,
    flags: u16,
    _pad0: u16 = 0,
    _pad1: u32 = 0,
};

/// Render state snapshot passed to the renderer each frame.
pub const RenderState = struct {
    cells: []const CellInstance,
    bg_cells: []const CellInstance,
    block_cells: []const CellInstance = &.{},
    cursor: CursorState,
    grid_cols: u16,
    grid_rows: u16,
    cell_width: f32,
    cell_height: f32,
    viewport_width: u32,
    viewport_height: u32,
    grid_padding: f32 = 4.0,
};

/// Cursor rendering state.
pub const CursorState = struct {
    col: u16,
    row: u16,
    style: CursorStyle = .block,
    visible: bool = true,
    color: u32,
};

pub const CursorStyle = enum { block, hollow, ibeam, underline };

/// Adaptive frame scheduler.
pub const FrameScheduler = struct {
    last_activity_ns: i128 = 0,
    idle_threshold_ns: i128 = 100_000_000, // 100ms

    pub fn markActive(self: *FrameScheduler) void {
        self.last_activity_ns = std.time.nanoTimestamp();
    }

    pub fn shouldRender(self: *const FrameScheduler) bool {
        const now = std.time.nanoTimestamp();
        return (now - self.last_activity_ns) < self.idle_threshold_ns;
    }
};

/// Renderer diagnostics for latency measurement.
pub const Diagnostics = struct {
    frame_time_us: u64 = 0,
    instance_build_us: u64 = 0,
    draw_calls: u32 = 0,
    glyph_cache_hits: u64 = 0,
    glyph_cache_misses: u64 = 0,
};

// -------------------------------------------------------
// Tests
// -------------------------------------------------------

test "Color.toU32 and fromU32 roundtrip" {
    const c = Color{ .r = 0xAB, .g = 0xCD, .b = 0xEF, .a = 0x42 };
    const color_u32 = c.toU32();
    try std.testing.expectEqual(@as(u32, 0xABCDEF42), color_u32);
    const unpacked = Color.fromU32(color_u32);
    try std.testing.expect(c.eql(unpacked));
}

test "Color.toU32 default alpha" {
    const c = Color{ .r = 0xFF, .g = 0x00, .b = 0x80 };
    try std.testing.expectEqual(@as(u32, 0xFF0080FF), c.toU32());
}

test "palette.resolve256 ANSI black (index 0)" {
    const black = palette.resolve256(0);
    try std.testing.expect(black.eql(palette.ansi_normal[0]));
}

test "palette.resolve256 ANSI bright white (index 15)" {
    const bright_white = palette.resolve256(15);
    try std.testing.expect(bright_white.eql(palette.ansi_bright[7]));
}

test "palette.resolve256 grayscale index 232 = #080808" {
    const gray = palette.resolve256(232);
    try std.testing.expectEqual(@as(u8, 8), gray.r);
    try std.testing.expectEqual(@as(u8, 8), gray.g);
    try std.testing.expectEqual(@as(u8, 8), gray.b);
}

test "palette.resolve256 grayscale index 255 = #eeeeee" {
    const gray = palette.resolve256(255);
    try std.testing.expectEqual(@as(u8, 238), gray.r);
    try std.testing.expectEqual(@as(u8, 238), gray.g);
    try std.testing.expectEqual(@as(u8, 238), gray.b);
}

test "palette.resolve256 color cube index 16 = pure black (0,0,0)" {
    const c = palette.resolve256(16);
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "palette.resolve256 color cube index 196 = pure red (255,0,0)" {
    // Index 196 = 16 + 5*36 + 0*6 + 0 = 16 + 180 = 196
    const c = palette.resolve256(196);
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "CellInstance is 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CellInstance));
}

test "FrameScheduler marks active and should render" {
    var scheduler = FrameScheduler{};
    scheduler.markActive();
    try std.testing.expect(scheduler.shouldRender());
}

test "FrameScheduler idle after threshold" {
    var scheduler = FrameScheduler{
        .last_activity_ns = 0,
        .idle_threshold_ns = 1,
    };
    // last_activity_ns is 0 (epoch), threshold is 1ns, current time is way past that
    try std.testing.expect(!scheduler.shouldRender());
}

test "RenderState has block_cells field" {
    try std.testing.expect(@hasField(RenderState, "block_cells"));
}

test "CellInstance atlas_x fits Powerline codepoint" {
    const cp: u16 = 0xE0B0; // Powerline right arrow
    const ci = CellInstance{
        .grid_col = 0,
        .grid_row = 0,
        .atlas_x = cp,
        .atlas_y = 0,
        .atlas_w = 0,
        .atlas_h = 0,
        .bearing_x = 0,
        .bearing_y = 0,
        .fg_color = 0,
        .bg_color = 0,
        .flags = 0,
    };
    try std.testing.expectEqual(@as(u16, 0xE0B0), ci.atlas_x);
}

test "CellInstance atlas_x fits box-drawing codepoint" {
    const cp: u16 = 0x2502; // Box-drawing vertical line
    const ci = CellInstance{
        .grid_col = 0,
        .grid_row = 0,
        .atlas_x = cp,
        .atlas_y = 0,
        .atlas_w = 0,
        .atlas_h = 0,
        .bearing_x = 0,
        .bearing_y = 0,
        .fg_color = 0,
        .bg_color = 0,
        .flags = 0,
    };
    try std.testing.expectEqual(@as(u16, 0x2502), ci.atlas_x);
}
