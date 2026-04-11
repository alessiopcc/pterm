/// Unit tests for renderer logic that does not require an OpenGL context.
///
/// Tests cover: CellInstance GPU alignment, orthographic projection math,
/// Color roundtrip, and palette 256-color resolution.
const std = @import("std");
const types = @import("renderer_types");
const backend = @import("opengl_backend");

const CellInstance = types.CellInstance;
const Color = types.Color;
const palette = types.palette;
const computeOrthoMatrix = backend.computeOrthoMatrix;

// -------------------------------------------------------
// CellInstance size (GPU alignment)
// -------------------------------------------------------

test "CellInstance is 32 bytes (GPU aligned)" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CellInstance));
}

// -------------------------------------------------------
// Orthographic projection matrix
// -------------------------------------------------------

test "ortho(0, 800, 600, 0, -1, 1) has correct diagonal and translation" {
    const m = computeOrthoMatrix(0.0, 800.0, 600.0, 0.0, -1.0, 1.0);

    // Column-major: m[col*4 + row]
    // m[0][0] = 2/800 = 0.0025
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 800.0), m[0], 1e-6);
    // m[1][1] = 2/(0-600) = -1/300
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / -600.0), m[5], 1e-6);
    // m[3][0] = -(800+0)/800 = -1
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), m[12], 1e-6);
    // m[3][1] = -(0+600)/(-600) = 1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[13], 1e-6);
    // m[2][2] = -2/(1-(-1)) = -1
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), m[10], 1e-6);
    // m[3][3] = 1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[15], 1e-6);
}

test "ortho identity check: symmetric projection" {
    // ortho(-1, 1, -1, 1, -1, 1) should produce identity-like diagonals
    const m = computeOrthoMatrix(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[0], 1e-6); // 2/2
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[5], 1e-6); // 2/2
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), m[10], 1e-6); // -2/2
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[12], 1e-6); // translation x
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[13], 1e-6); // translation y
}

// -------------------------------------------------------
// Color roundtrip
// -------------------------------------------------------

test "Color.toU32 and fromU32 roundtrip" {
    const c = Color{ .r = 0xAB, .g = 0xCD, .b = 0xEF, .a = 0x42 };
    const color_u32 = c.toU32();
    try std.testing.expectEqual(@as(u32, 0xABCDEF42), color_u32);
    const unpacked = Color.fromU32(color_u32);
    try std.testing.expect(c.eql(unpacked));
}

test "Color default alpha is 255" {
    const c = Color{ .r = 0xFF, .g = 0x00, .b = 0x80 };
    try std.testing.expectEqual(@as(u32, 0xFF0080FF), c.toU32());
}

// -------------------------------------------------------
// Palette 256-color resolution
// -------------------------------------------------------

test "palette.resolve256: ANSI black (index 0)" {
    const black = palette.resolve256(0);
    try std.testing.expect(black.eql(palette.ansi_normal[0]));
}

test "palette.resolve256: ANSI red (index 1)" {
    const red = palette.resolve256(1);
    try std.testing.expect(red.eql(palette.ansi_normal[1]));
}

test "palette.resolve256: first cube color (index 16) = #000000" {
    const c = palette.resolve256(16);
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "palette.resolve256: last cube color (index 231) = #ffffff" {
    const c = palette.resolve256(231);
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 255), c.g);
    try std.testing.expectEqual(@as(u8, 255), c.b);
}

test "palette.resolve256: first grayscale (index 232) = #080808" {
    const gray = palette.resolve256(232);
    try std.testing.expectEqual(@as(u8, 8), gray.r);
    try std.testing.expectEqual(@as(u8, 8), gray.g);
    try std.testing.expectEqual(@as(u8, 8), gray.b);
}

test "palette.resolve256: last grayscale (index 255) = #eeeeee" {
    const gray = palette.resolve256(255);
    try std.testing.expectEqual(@as(u8, 238), gray.r);
    try std.testing.expectEqual(@as(u8, 238), gray.g);
    try std.testing.expectEqual(@as(u8, 238), gray.b);
}
