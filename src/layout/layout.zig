/// Layout module root: re-exports all layout types for multi-pane tab management.
///
/// Binary tree pane model, Tab, TabManager, Rect, tree operations.
/// Compositor, TabBarRenderer, PaneState, PaneRegistry.
pub const PaneTree = @import("PaneTree.zig");
pub const Tab = @import("Tab.zig");
pub const TabManager = @import("TabManager.zig");
pub const Rect = @import("Rect.zig");
pub const tree_ops = @import("tree_ops.zig");
pub const Compositor = @import("Compositor.zig");
pub const TabBarRenderer = @import("TabBarRenderer.zig");
pub const LayoutPreset = @import("LayoutPreset.zig");
pub const PresetPicker = @import("PresetPicker.zig");
pub const ShellPicker = @import("ShellPicker.zig");

test {
    // Pull in all module tests
    _ = PaneTree;
    _ = Tab;
    _ = TabManager;
    _ = Rect;
    _ = tree_ops;
    _ = Compositor;
    _ = TabBarRenderer;
    _ = LayoutPreset;
    _ = PresetPicker;
    _ = ShellPicker;
}
