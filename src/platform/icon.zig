/// Embedded application icon data for GLFW window icon.
///
/// Provides multiple icon sizes (16-256px) as compile-time embedded RGBA pixel
/// data. GLFW selects the best size for taskbar, title bar, and Alt-Tab.
const glfw = @import("zglfw");

pub const Icon = struct {
    width: c_int,
    height: c_int,
    pixels: []const u8,
};

// Embed raw RGBA pixel data at compile time.
const icon_16_pixels = @embedFile("icons/icon-16.rgba");
const icon_32_pixels = @embedFile("icons/icon-32.rgba");
const icon_48_pixels = @embedFile("icons/icon-48.rgba");
const icon_64_pixels = @embedFile("icons/icon-64.rgba");
const icon_128_pixels = @embedFile("icons/icon-128.rgba");
const icon_256_pixels = @embedFile("icons/icon-256.rgba");

/// All icon images, ordered smallest to largest.
/// GLFW picks the closest match for each context (title bar, taskbar, etc.).
pub const images = [_]glfw.Image{
    .{ .width = 16, .height = 16, .pixels = @ptrCast(@constCast(icon_16_pixels.ptr)) },
    .{ .width = 32, .height = 32, .pixels = @ptrCast(@constCast(icon_32_pixels.ptr)) },
    .{ .width = 48, .height = 48, .pixels = @ptrCast(@constCast(icon_48_pixels.ptr)) },
    .{ .width = 64, .height = 64, .pixels = @ptrCast(@constCast(icon_64_pixels.ptr)) },
    .{ .width = 128, .height = 128, .pixels = @ptrCast(@constCast(icon_128_pixels.ptr)) },
    .{ .width = 256, .height = 256, .pixels = @ptrCast(@constCast(icon_256_pixels.ptr)) },
};

/// Set the window icon using all embedded sizes.
pub fn setWindowIcon(handle: *glfw.Window) void {
    handle.setIcon(&images);
}
