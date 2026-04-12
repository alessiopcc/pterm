/// Lightweight layout types for the renderer module.
/// Duplicates Rect from layout/Rect.zig to avoid circular dependency
/// between renderer and layout modules.
///
/// IMPORTANT: This struct must stay in sync with layout/Rect.zig.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    /// Check whether a pixel coordinate falls within this rectangle.
    pub fn contains(self: Rect, px: i32, py: i32) bool {
        const right: i32 = self.x + @as(i32, @intCast(self.w));
        const bottom: i32 = self.y + @as(i32, @intCast(self.h));
        return px >= self.x and px < right and py >= self.y and py < bottom;
    }
};
