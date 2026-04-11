/// Utility functions: key mapping, modifier conversion, edge detection, pane ID generation.
const glfw = @import("zglfw");
const app_mod = @import("App.zig");
const App = app_mod.App;
const keybindings = @import("keybindings");

/// Map GLFW key code to lowercase ASCII character for keybinding lookup.
pub fn glfwKeyToChar(key: glfw.Key) ?u21 {
    const code: u32 = @intCast(@intFromEnum(key));
    // A-Z (GLFW codes 65-90) -> lowercase 'a'-'z'
    if (code >= 65 and code <= 90) return @intCast(code + 32);
    // 0-9 (GLFW codes 48-57) -> '0'-'9'
    if (code >= 48 and code <= 57) return @intCast(code);
    // Common punctuation
    return switch (key) {
        .minus => '-',
        .equal => '=',
        .left_bracket => '[',
        .right_bracket => ']',
        .backslash => '\\',
        .semicolon => ';',
        .apostrophe => '\'',
        .comma => ',',
        .period => '.',
        .slash => '/',
        .grave_accent => '`',
        .space => ' ',
        else => null,
    };
}

/// Convert GLFW modifier flags to keybinding Modifiers.
pub fn glfwModsToModifiers(mods: glfw.Mods) keybindings.Modifiers {
    return .{
        .ctrl = mods.control,
        .shift = mods.shift,
        .alt = mods.alt,
        .super = mods.super,
    };
}

/// Detect if cursor is on a window edge for resize (5px grab zone).
pub const resize_grab = 5;

pub fn detectWindowEdge(self: *App, x: i32, y: i32) App.WindowEdge {
    const fb = self.window.getFramebufferSize();
    const w: i32 = @intCast(fb.width);
    const h: i32 = @intCast(fb.height);
    return .{
        .left = x < resize_grab,
        .right = x >= w - resize_grab,
        .top = y < resize_grab,
        .bottom = y >= h - resize_grab,
    };
}

pub fn edgeIsAny(edge: App.WindowEdge) bool {
    return edge.left or edge.right or edge.top or edge.bottom;
}

/// Generate a unique pane ID by finding the max existing ID and incrementing.
pub fn generatePaneId(self: *App) u32 {
    // Simple incrementing ID across all tabs
    var max_id: u32 = 0;
    var it = self.pane_data.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* > max_id) max_id = entry.key_ptr.*;
    }
    return max_id + 1;
}
