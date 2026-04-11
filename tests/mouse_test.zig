const std = @import("std");
const mouse_mod = @import("core_mouse");
const selection_mod = @import("core_selection");
const parseSgrMouse = mouse_mod.parseSgrMouse;
const Selection = selection_mod.Selection;

test "parse SGR mouse press" {
    // Left button press at col 10, row 5: "0;10;5M"
    const event = try parseSgrMouse("0;10;5M");
    try std.testing.expectEqual(mouse_mod.MouseButton.left, event.button);
    try std.testing.expectEqual(mouse_mod.MouseAction.press, event.action);
    try std.testing.expectEqual(@as(u16, 10), event.col);
    try std.testing.expectEqual(@as(u16, 5), event.row);
    try std.testing.expectEqual(false, event.modifiers.shift);
    try std.testing.expectEqual(false, event.modifiers.alt);
    try std.testing.expectEqual(false, event.modifiers.ctrl);
}

test "parse SGR mouse release" {
    // Left button release at col 10, row 5: "0;10;5m" (lowercase m = release)
    const event = try parseSgrMouse("0;10;5m");
    try std.testing.expectEqual(mouse_mod.MouseButton.left, event.button);
    try std.testing.expectEqual(mouse_mod.MouseAction.release, event.action);
    try std.testing.expectEqual(@as(u16, 10), event.col);
    try std.testing.expectEqual(@as(u16, 5), event.row);
}

test "parse SGR mouse with modifiers" {
    // Shift+left press: Cb=4 (shift bit set), col 20, row 10: "4;20;10M"
    const event = try parseSgrMouse("4;20;10M");
    try std.testing.expectEqual(mouse_mod.MouseButton.left, event.button);
    try std.testing.expectEqual(mouse_mod.MouseAction.press, event.action);
    try std.testing.expectEqual(true, event.modifiers.shift);
    try std.testing.expectEqual(false, event.modifiers.alt);
    try std.testing.expectEqual(false, event.modifiers.ctrl);
    try std.testing.expectEqual(@as(u16, 20), event.col);
    try std.testing.expectEqual(@as(u16, 10), event.row);
}

test "parse SGR scroll" {
    // Scroll up: Cb=64, col 1, row 1: "64;1;1M"
    const event = try parseSgrMouse("64;1;1M");
    try std.testing.expectEqual(mouse_mod.MouseButton.scroll_up, event.button);
    try std.testing.expectEqual(mouse_mod.MouseAction.press, event.action);
    try std.testing.expectEqual(@as(u16, 1), event.col);
    try std.testing.expectEqual(@as(u16, 1), event.row);
}

test "selection begin update finish" {
    var sel = Selection.init();
    try std.testing.expectEqual(false, sel.active);
    try std.testing.expectEqual(@as(?selection_mod.SelectionRange, null), sel.range);

    // Begin selection at (0, 0)
    sel.begin(0, 0, .normal);
    try std.testing.expectEqual(true, sel.active);

    // Update to (0, 10)
    sel.update(0, 10);

    // Finish and verify range
    const range = sel.finish().?;
    try std.testing.expectEqual(false, sel.active);
    try std.testing.expectEqual(@as(u32, 0), range.start_row);
    try std.testing.expectEqual(@as(u16, 0), range.start_col);
    try std.testing.expectEqual(@as(u32, 0), range.end_row);
    try std.testing.expectEqual(@as(u16, 10), range.end_col);
}

test "selection clear" {
    var sel = Selection.init();
    sel.begin(5, 3, .word);
    try std.testing.expectEqual(true, sel.active);

    sel.clear();
    try std.testing.expectEqual(false, sel.active);
    try std.testing.expectEqual(@as(?selection_mod.SelectionRange, null), sel.range);
}

test "selection copy-on-select (D-14)" {
    const alloc = std.testing.allocator;

    // Simulate screen lines
    const screen_lines = [_][]const u8{
        "Hello World",
        "Second line here",
        "Third line data",
    };

    // Select "World" from first line (cols 6-10)
    const range = selection_mod.SelectionRange{
        .start_row = 0,
        .start_col = 6,
        .end_row = 0,
        .end_col = 10,
    };

    const text = try Selection.getSelectedText(range, &screen_lines, alloc);
    defer alloc.free(text);

    try std.testing.expectEqualStrings("World", text);
}

test "selection multi-line copy-on-select" {
    const alloc = std.testing.allocator;

    const screen_lines = [_][]const u8{
        "Hello World",
        "Second line here",
        "Third line data",
    };

    // Select from "World" on line 0 through "Second" on line 1
    const range = selection_mod.SelectionRange{
        .start_row = 0,
        .start_col = 6,
        .end_row = 1,
        .end_col = 5,
    };

    const text = try Selection.getSelectedText(range, &screen_lines, alloc);
    defer alloc.free(text);

    try std.testing.expectEqualStrings("World\nSecond", text);
}
