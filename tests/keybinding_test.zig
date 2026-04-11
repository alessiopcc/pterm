/// Keybinding system tests (Phase 04 Plan 02).
///
/// Tests parseKeyCombo, isReservedClipboardKey, buildMap (with D-18 multi-combo),
/// conflict detection (D-25), unbind via none (D-23), and formatKeyCombo.
const std = @import("std");
const kb = @import("keybindings");

const Action = kb.Action;
const KeyCombo = kb.KeyCombo;
const KeyId = kb.KeyId;
const Modifiers = kb.Modifiers;
const UserBinding = kb.UserBinding;

// -------------------------------------------------------
// parseKeyCombo tests
// -------------------------------------------------------

test "parse ctrl+c" {
    const combo = try kb.parseKeyCombo("ctrl+c");
    try std.testing.expect(combo.key.eql(.{ .char = 'c' }));
    try std.testing.expect(combo.mods.ctrl);
    try std.testing.expect(!combo.mods.shift);
    try std.testing.expect(!combo.mods.alt);
    try std.testing.expect(!combo.mods.super);
}

test "parse ctrl+shift+t" {
    const combo = try kb.parseKeyCombo("ctrl+shift+t");
    try std.testing.expect(combo.key.eql(.{ .char = 't' }));
    try std.testing.expect(combo.mods.ctrl);
    try std.testing.expect(combo.mods.shift);
}

test "parse shift+insert (special key)" {
    const combo = try kb.parseKeyCombo("shift+insert");
    try std.testing.expect(combo.key.eql(.{ .special = .insert }));
    try std.testing.expect(combo.mods.shift);
}

test "parse ctrl+= (equals sign)" {
    const combo = try kb.parseKeyCombo("ctrl+=");
    try std.testing.expect(combo.key.eql(.{ .char = '=' }));
    try std.testing.expect(combo.mods.ctrl);
}

test "parse shift+pageup" {
    const combo = try kb.parseKeyCombo("shift+pageup");
    try std.testing.expect(combo.key.eql(.{ .special = .page_up }));
    try std.testing.expect(combo.mods.shift);
}

test "parse super+c (macOS Cmd)" {
    const combo = try kb.parseKeyCombo("super+c");
    try std.testing.expect(combo.key.eql(.{ .char = 'c' }));
    try std.testing.expect(combo.mods.super);
}

test "parse invalid key returns error" {
    try std.testing.expectError(kb.ParseError.InvalidKeyCombo, kb.parseKeyCombo("invalid"));
}

test "parse empty string returns error" {
    try std.testing.expectError(kb.ParseError.InvalidKeyCombo, kb.parseKeyCombo(""));
}

// -------------------------------------------------------
// isReservedClipboardKey tests
// -------------------------------------------------------

test "reserved: ctrl+c" {
    const combo = try kb.parseKeyCombo("ctrl+c");
    try std.testing.expect(kb.isReservedClipboardKey(combo));
}

test "reserved: ctrl+v" {
    const combo = try kb.parseKeyCombo("ctrl+v");
    try std.testing.expect(kb.isReservedClipboardKey(combo));
}

test "reserved: super+c (macOS Cmd+C)" {
    const combo = try kb.parseKeyCombo("super+c");
    try std.testing.expect(kb.isReservedClipboardKey(combo));
}

test "reserved: super+v (macOS Cmd+V)" {
    const combo = try kb.parseKeyCombo("super+v");
    try std.testing.expect(kb.isReservedClipboardKey(combo));
}

test "not reserved: ctrl+shift+t" {
    const combo = try kb.parseKeyCombo("ctrl+shift+t");
    try std.testing.expect(!kb.isReservedClipboardKey(combo));
}

test "not reserved: ctrl+shift+c (has shift)" {
    const combo = try kb.parseKeyCombo("ctrl+shift+c");
    try std.testing.expect(!kb.isReservedClipboardKey(combo));
}

// -------------------------------------------------------
// buildMap tests
// -------------------------------------------------------

test "default map has copy, paste, new_tab, scroll_page_up, font actions" {
    var map = try kb.buildMap(std.testing.allocator, null);
    defer map.deinit();

    // copy on ctrl+c
    const ctrl_c = try kb.parseKeyCombo("ctrl+c");
    try std.testing.expectEqual(Action.copy, map.get(ctrl_c).?);

    // paste on ctrl+v
    const ctrl_v = try kb.parseKeyCombo("ctrl+v");
    try std.testing.expectEqual(Action.paste, map.get(ctrl_v).?);

    // new_tab on ctrl+shift+t
    const cst = try kb.parseKeyCombo("ctrl+shift+t");
    try std.testing.expectEqual(Action.new_tab, map.get(cst).?);

    // scroll_page_up on shift+pageup
    const spu = try kb.parseKeyCombo("shift+pageup");
    try std.testing.expectEqual(Action.scroll_page_up, map.get(spu).?);

    // increase_font_size on ctrl+=
    const inc = try kb.parseKeyCombo("ctrl+=");
    try std.testing.expectEqual(Action.increase_font_size, map.get(inc).?);

    // decrease_font_size on ctrl+-
    const dec = try kb.parseKeyCombo("ctrl+-");
    try std.testing.expectEqual(Action.decrease_font_size, map.get(dec).?);

    // reset_font_size on ctrl+0
    const rst = try kb.parseKeyCombo("ctrl+0");
    try std.testing.expectEqual(Action.reset_font_size, map.get(rst).?);
}

test "buildMap: user override new_tab to ctrl+n" {
    const overrides = [_]UserBinding{
        .{ .action_name = "new_tab", .combo_str = "ctrl+n" },
    };
    var map = try kb.buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    const ctrl_n = try kb.parseKeyCombo("ctrl+n");
    try std.testing.expectEqual(Action.new_tab, map.get(ctrl_n).?);
}

test "buildMap: reserved key cannot be overridden, warning emitted" {
    const overrides = [_]UserBinding{
        .{ .action_name = "new_tab", .combo_str = "ctrl+c" },
    };
    var map = try kb.buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    // ctrl+c should still be copy
    const ctrl_c = try kb.parseKeyCombo("ctrl+c");
    try std.testing.expectEqual(Action.copy, map.get(ctrl_c).?);
    try std.testing.expect(map.warnings.items.len > 0);
}

test "buildMap: ctrl+shift+c accepted (not reserved, shift makes it different)" {
    const overrides = [_]UserBinding{
        .{ .action_name = "copy", .combo_str = "ctrl+shift+c" },
    };
    var map = try kb.buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    const csc = try kb.parseKeyCombo("ctrl+shift+c");
    try std.testing.expectEqual(Action.copy, map.get(csc).?);
}

test "buildMap: unbind scroll_page_up with none (D-23)" {
    const overrides = [_]UserBinding{
        .{ .action_name = "scroll_page_up", .combo_str = "none" },
    };
    var map = try kb.buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    const spu = try kb.parseKeyCombo("shift+pageup");
    try std.testing.expect(map.get(spu) == null);
}

test "buildMap: conflict detection warns, last wins (D-25)" {
    const overrides = [_]UserBinding{
        .{ .action_name = "search", .combo_str = "ctrl+shift+t" },
    };
    var map = try kb.buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    // ctrl+shift+t was new_tab, now search
    const cst = try kb.parseKeyCombo("ctrl+shift+t");
    try std.testing.expectEqual(Action.search, map.get(cst).?);
    try std.testing.expect(map.warnings.items.len > 0);
}

test "buildMap: single combo per action" {
    const overrides = [_]UserBinding{
        .{ .action_name = "copy", .combo_str = "ctrl+shift+c" },
    };
    var map = try kb.buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    const csc = try kb.parseKeyCombo("ctrl+shift+c");
    try std.testing.expectEqual(Action.copy, map.get(csc).?);
}

// -------------------------------------------------------
// parseAction tests
// -------------------------------------------------------

test "parseAction: known actions" {
    try std.testing.expectEqual(Action.copy, kb.parseAction("copy").?);
    try std.testing.expectEqual(Action.paste, kb.parseAction("paste").?);
    try std.testing.expectEqual(Action.new_tab, kb.parseAction("new_tab").?);
    try std.testing.expectEqual(Action.none, kb.parseAction("none").?);
}

test "parseAction: unknown action returns null" {
    try std.testing.expect(kb.parseAction("nonexistent") == null);
}

// -------------------------------------------------------
// KeyCombo hash/equality tests
// -------------------------------------------------------

test "KeyCombo hash consistency" {
    const a = try kb.parseKeyCombo("ctrl+c");
    const b = try kb.parseKeyCombo("ctrl+c");
    try std.testing.expect(a.eql(b));
    try std.testing.expectEqual(a.hash(), b.hash());
}

test "KeyCombo different combos not equal" {
    const a = try kb.parseKeyCombo("ctrl+c");
    const b = try kb.parseKeyCombo("ctrl+v");
    try std.testing.expect(!a.eql(b));
}

// -------------------------------------------------------
// formatKeyCombo tests (from keybinding_tui)
// -------------------------------------------------------

test "formatKeyCombo: ctrl+shift+t" {
    const kb_tui = @import("keybinding_tui");
    const combo = try kb.parseKeyCombo("ctrl+shift+t");
    var buf: [64]u8 = undefined;
    const result = kb_tui.formatKeyCombo(combo, &buf);
    try std.testing.expectEqualSlices(u8, "ctrl+shift+t", result);
}

test "formatKeyCombo: shift+pageup" {
    const kb_tui = @import("keybinding_tui");
    const combo = try kb.parseKeyCombo("shift+pageup");
    var buf: [64]u8 = undefined;
    const result = kb_tui.formatKeyCombo(combo, &buf);
    try std.testing.expectEqualSlices(u8, "shift+pageup", result);
}

test "formatKeyCombo: super+c" {
    const kb_tui = @import("keybinding_tui");
    const combo = try kb.parseKeyCombo("super+c");
    var buf: [64]u8 = undefined;
    const result = kb_tui.formatKeyCombo(combo, &buf);
    try std.testing.expectEqualSlices(u8, "super+c", result);
}
