/// Keybinding system: action vocabulary, key combo parsing, runtime dispatch map,
/// clipboard reservation, and default bindings.
///
/// The KeybindingMap provides O(1) lookup from KeyCombo -> Action for use in
/// Surface key callbacks. Reserved clipboard keys (Ctrl+C/V, Cmd+C/V) are
/// enforced at map build time and cannot be overridden by user config.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Terminal actions that can be bound to key combos.
/// This is the fixed vocabulary of operations.
pub const Action = enum {
    // Reserved actions — not rebindable (handled by hardcoded key paths)
    copy,
    paste,
    increase_font_size,
    decrease_font_size,
    reset_font_size,
    // Rebindable actions
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    split_horizontal,
    split_vertical,
    focus_next_pane,
    focus_prev_pane,
    // Pane management actions
    close_pane,
    focus_pane_up,
    focus_pane_down,
    focus_pane_left,
    focus_pane_right,
    resize_pane_up,
    resize_pane_down,
    resize_pane_left,
    resize_pane_right,
    zoom_pane,
    equalize_panes,
    swap_pane_up,
    swap_pane_down,
    swap_pane_left,
    swap_pane_right,
    rotate_split,
    break_out_pane,
    move_tab_left,
    move_tab_right,
    goto_tab_1,
    goto_tab_2,
    goto_tab_3,
    goto_tab_4,
    goto_tab_5,
    goto_tab_6,
    goto_tab_7,
    goto_tab_8,
    goto_tab_9,
    goto_tab_last,
    open_layout_picker,
    scroll_page_up,
    scroll_page_down,
    scroll_to_top,
    scroll_to_bottom,
    search,
    // Agent monitoring actions
    toggle_agent_tab,
    // Shell switching
    change_shell,
    none,
};

/// Special (non-printable) keys that can appear in key combos.
pub const SpecialKey = enum {
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    tab,
    enter,
    escape,
    backspace,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// Key identifier: either a Unicode codepoint (logical character
/// or a special non-printable key.
pub const KeyId = union(enum) {
    char: u21,
    special: SpecialKey,

    pub fn eql(a: KeyId, b: KeyId) bool {
        return switch (a) {
            .char => |ac| switch (b) {
                .char => |bc| ac == bc,
                .special => false,
            },
            .special => |as_| switch (b) {
                .char => false,
                .special => |bs| as_ == bs,
            },
        };
    }
};

/// Modifier key state.
pub const Modifiers = packed struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn eql(a: Modifiers, b: Modifiers) bool {
        return a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and a.super == b.super;
    }

    pub fn toInt(self: Modifiers) u4 {
        var v: u4 = 0;
        if (self.ctrl) v |= 1;
        if (self.shift) v |= 2;
        if (self.alt) v |= 4;
        if (self.super) v |= 8;
        return v;
    }
};

/// A key combination: a key identifier plus modifier state.
pub const KeyCombo = struct {
    key: KeyId,
    mods: Modifiers,

    pub fn eql(a: KeyCombo, b: KeyCombo) bool {
        return a.key.eql(b.key) and a.mods.eql(b.mods);
    }

    pub fn hash(self: KeyCombo) u64 {
        var h: u64 = 0;
        switch (self.key) {
            .char => |c| {
                h = @as(u64, c) | (1 << 21);
            },
            .special => |s| {
                h = @as(u64, @intFromEnum(s)) | (1 << 22);
            },
        }
        h = h * 31 + @as(u64, self.mods.toInt());
        return h;
    }
};

/// HashMap context for KeyCombo keys.
pub const KeyComboContext = struct {
    pub fn hash(_: KeyComboContext, combo: KeyCombo) u64 {
        return combo.hash();
    }

    pub fn eql(_: KeyComboContext, a: KeyCombo, b: KeyCombo) bool {
        return a.eql(b);
    }
};

/// Runtime keybinding lookup map: KeyCombo -> Action.
pub const KeybindingMap = struct {
    map: std.HashMapUnmanaged(KeyCombo, Action, KeyComboContext, 80),
    allocator: Allocator,
    warnings: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: Allocator) KeybindingMap {
        return .{
            .map = .{},
            .allocator = allocator,
            .warnings = .{},
        };
    }

    pub fn deinit(self: *KeybindingMap) void {
        self.map.deinit(self.allocator);
        for (self.warnings.items) |w| {
            self.allocator.free(w);
        }
        self.warnings.deinit(self.allocator);
    }

    pub fn put(self: *KeybindingMap, combo: KeyCombo, action: Action) !void {
        try self.map.put(self.allocator, combo, action);
    }

    pub fn get(self: *const KeybindingMap, combo: KeyCombo) ?Action {
        return self.map.get(combo);
    }

    pub fn contains(self: *const KeybindingMap, combo: KeyCombo) bool {
        return self.map.contains(combo);
    }

    pub fn remove(self: *KeybindingMap, combo: KeyCombo) void {
        _ = self.map.remove(combo);
    }

    pub fn addWarning(self: *KeybindingMap, msg: []const u8) !void {
        const owned = try self.allocator.dupe(u8, msg);
        try self.warnings.append(self.allocator, owned);
    }

    pub fn count(self: *const KeybindingMap) u32 {
        return self.map.count();
    }

    /// Remove all entries whose value matches the given action.
    pub fn removeByAction(self: *KeybindingMap, action: Action) void {
        // Collect keys to remove (cannot mutate during iteration)
        var to_remove: [64]KeyCombo = undefined;
        var remove_count: usize = 0;

        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == action and remove_count < to_remove.len) {
                to_remove[remove_count] = entry.key_ptr.*;
                remove_count += 1;
            }
        }

        for (to_remove[0..remove_count]) |combo| {
            _ = self.map.remove(combo);
        }
    }
};

/// Error type for key combo parsing.
pub const ParseError = error{
    InvalidKeyCombo,
    EmptyKeyName,
    UnknownModifier,
    UnknownKeyName,
    OutOfMemory,
};

/// Parse a key combo string like "ctrl+c", "ctrl+shift+t", "shift+pageup".
/// Returns error.InvalidKeyCombo for invalid input.
pub fn parseKeyCombo(combo_str: []const u8) ParseError!KeyCombo {
    if (combo_str.len == 0) return ParseError.InvalidKeyCombo;

    var mods = Modifiers{};
    var key_part: ?[]const u8 = null;

    // Split on '+' and process each part
    var start: usize = 0;
    var parts_count: usize = 0;
    var parts: [8][]const u8 = undefined;

    for (combo_str, 0..) |c, i| {
        if (c == '+') {
            if (i > start) {
                if (parts_count >= parts.len) return ParseError.InvalidKeyCombo;
                parts[parts_count] = combo_str[start..i];
                parts_count += 1;
            }
            start = i + 1;
        }
    }
    // Last part
    if (start < combo_str.len) {
        if (parts_count >= parts.len) return ParseError.InvalidKeyCombo;
        parts[parts_count] = combo_str[start..];
        parts_count += 1;
    }

    if (parts_count == 0) return ParseError.InvalidKeyCombo;

    // All parts except last are modifiers, last is the key
    for (parts[0 .. parts_count - 1]) |part| {
        const lower = toLowerBuf(part);
        const mod_str = lower[0..part.len];

        if (strEql(mod_str, "ctrl") or strEql(mod_str, "control")) {
            mods.ctrl = true;
        } else if (strEql(mod_str, "shift")) {
            mods.shift = true;
        } else if (strEql(mod_str, "alt") or strEql(mod_str, "option") or strEql(mod_str, "opt")) {
            mods.alt = true;
        } else if (strEql(mod_str, "super") or strEql(mod_str, "cmd") or strEql(mod_str, "command") or strEql(mod_str, "meta")) {
            mods.super = true;
        } else {
            return ParseError.InvalidKeyCombo;
        }
    }

    key_part = parts[parts_count - 1];
    const key_str = key_part orelse return ParseError.InvalidKeyCombo;

    if (key_str.len == 0) return ParseError.InvalidKeyCombo;

    // Try to match as special key
    const lower_key = toLowerBuf(key_str);
    const lk = lower_key[0..key_str.len];

    if (matchSpecialKey(lk)) |special| {
        return KeyCombo{ .key = .{ .special = special }, .mods = mods };
    }

    // Single character key (logical)
    if (key_str.len == 1) {
        const ch = key_str[0];
        // Accept printable ASCII as logical keys
        if (ch >= 0x20 and ch <= 0x7E) {
            // Normalize to lowercase for consistent matching
            const normalized: u21 = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            return KeyCombo{ .key = .{ .char = normalized }, .mods = mods };
        }
    }

    return ParseError.InvalidKeyCombo;
}

/// Check if an action is reserved (not rebindable).
/// Copy, paste, and zoom are handled by hardcoded key paths.
pub fn isReservedAction(action: Action) bool {
    return switch (action) {
        .copy, .paste, .increase_font_size, .decrease_font_size, .reset_font_size => true,
        else => false,
    };
}

/// Check if a key combo is a reserved clipboard key.
/// Ctrl+C / Super+C for smart copy.
/// Ctrl+V / Super+V for paste.
pub fn isReservedClipboardKey(combo: KeyCombo) bool {
    const is_cv = switch (combo.key) {
        .char => |c| c == 'c' or c == 'v',
        .special => false,
    };
    if (!is_cv) return false;

    const ctrl_only = combo.mods.ctrl and !combo.mods.shift and !combo.mods.alt and !combo.mods.super;
    const super_only = combo.mods.super and !combo.mods.shift and !combo.mods.alt and !combo.mods.ctrl;
    return ctrl_only or super_only;
}

/// Default keybinding definitions.
const DefaultBinding = struct {
    action: Action,
    combo_str: []const u8,
};

pub fn defaultBindings() []const DefaultBinding {
    return &[_]DefaultBinding{
        .{ .action = .paste, .combo_str = "ctrl+v" },
        .{ .action = .new_tab, .combo_str = "ctrl+shift+t" },
        .{ .action = .close_tab, .combo_str = "ctrl+shift+w" },
        .{ .action = .next_tab, .combo_str = "ctrl+tab" },
        .{ .action = .prev_tab, .combo_str = "ctrl+shift+tab" },
        .{ .action = .split_horizontal, .combo_str = "ctrl+shift+h" },
        .{ .action = .split_vertical, .combo_str = "ctrl+shift+v" },
        .{ .action = .focus_next_pane, .combo_str = "ctrl+shift+]" },
        .{ .action = .focus_prev_pane, .combo_str = "ctrl+shift+[" },
        .{ .action = .increase_font_size, .combo_str = "ctrl+=" },
        .{ .action = .decrease_font_size, .combo_str = "ctrl+-" },
        .{ .action = .reset_font_size, .combo_str = "ctrl+0" },
        .{ .action = .scroll_page_up, .combo_str = "shift+pageup" },
        .{ .action = .scroll_page_down, .combo_str = "shift+pagedown" },
        .{ .action = .scroll_to_top, .combo_str = "ctrl+shift+home" },
        .{ .action = .scroll_to_bottom, .combo_str = "ctrl+shift+end" },
        .{ .action = .search, .combo_str = "ctrl+shift+f" },
        // Pane/tab management bindings
        .{ .action = .close_pane, .combo_str = "ctrl+shift+x" },
        .{ .action = .focus_pane_up, .combo_str = "ctrl+shift+up" },
        .{ .action = .focus_pane_down, .combo_str = "ctrl+shift+down" },
        .{ .action = .focus_pane_left, .combo_str = "ctrl+shift+left" },
        .{ .action = .focus_pane_right, .combo_str = "ctrl+shift+right" },
        .{ .action = .resize_pane_up, .combo_str = "ctrl+alt+up" },
        .{ .action = .resize_pane_down, .combo_str = "ctrl+alt+down" },
        .{ .action = .resize_pane_left, .combo_str = "ctrl+alt+left" },
        .{ .action = .resize_pane_right, .combo_str = "ctrl+alt+right" },
        .{ .action = .zoom_pane, .combo_str = "ctrl+shift+z" },
        .{ .action = .equalize_panes, .combo_str = "ctrl+shift+e" },
        .{ .action = .rotate_split, .combo_str = "ctrl+shift+r" },
        .{ .action = .break_out_pane, .combo_str = "ctrl+shift+b" },
        .{ .action = .move_tab_left, .combo_str = "ctrl+shift+pageup" },
        .{ .action = .move_tab_right, .combo_str = "ctrl+shift+pagedown" },
        .{ .action = .swap_pane_up, .combo_str = "ctrl+alt+shift+up" },
        .{ .action = .swap_pane_down, .combo_str = "ctrl+alt+shift+down" },
        .{ .action = .swap_pane_left, .combo_str = "ctrl+alt+shift+left" },
        .{ .action = .swap_pane_right, .combo_str = "ctrl+alt+shift+right" },
        .{ .action = .goto_tab_1, .combo_str = "alt+1" },
        .{ .action = .goto_tab_2, .combo_str = "alt+2" },
        .{ .action = .goto_tab_3, .combo_str = "alt+3" },
        .{ .action = .goto_tab_4, .combo_str = "alt+4" },
        .{ .action = .goto_tab_5, .combo_str = "alt+5" },
        .{ .action = .goto_tab_6, .combo_str = "alt+6" },
        .{ .action = .goto_tab_7, .combo_str = "alt+7" },
        .{ .action = .goto_tab_8, .combo_str = "alt+8" },
        .{ .action = .goto_tab_9, .combo_str = "alt+9" },
        .{ .action = .goto_tab_last, .combo_str = "alt+0" },
        .{ .action = .open_layout_picker, .combo_str = "ctrl+shift+l" },
        // Agent monitoring bindings
        .{ .action = .toggle_agent_tab, .combo_str = "ctrl+shift+a" },
        // Shell switching
        .{ .action = .change_shell, .combo_str = "ctrl+shift+s" },
    };
}

/// Parse an action name string to Action enum.
pub fn parseAction(name: []const u8) ?Action {
    const fields = @typeInfo(Action).@"enum".fields;
    inline for (fields) |field| {
        if (strEql(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

/// Format an Action as its string name.
pub fn actionName(action: Action) []const u8 {
    return @tagName(action);
}

/// Build a keybinding map from defaults + optional user overrides.
///
/// User overrides are provided as a slice of (action_name, combo_str) pairs.
/// One combo per action. Last definition wins.
///
/// Rules:
///   - Reserved clipboard keys cannot be overridden
///   - combo_str = "none" unbinds the action
///   - Conflicts warn, last definition wins
pub fn buildMap(
    allocator: Allocator,
    overrides: ?[]const UserBinding,
) !KeybindingMap {
    var map = KeybindingMap.init(allocator);
    errdefer map.deinit();

    // 1. Load defaults
    for (defaultBindings()) |binding| {
        const combo = parseKeyCombo(binding.combo_str) catch continue;
        try map.put(combo, binding.action);
    }

    // 2. Apply user overrides
    if (overrides) |user_bindings| {
        for (user_bindings) |ub| {
            const action = parseAction(ub.action_name) orelse {
                try map.addWarning("unknown action in keybinding config");
                continue;
            };

            if (action == .none) continue;
            if (isReservedAction(action)) {
                try map.addWarning("cannot rebind reserved action");
                continue;
            }

            // "none" as combo value means unbind
            if (strEql(ub.combo_str, "none")) {
                map.removeByAction(action);
                continue;
            }

            const combo = parseKeyCombo(ub.combo_str) catch {
                try map.addWarning("invalid key combo in keybinding config");
                continue;
            };

            // reserved clipboard keys
            if (isReservedClipboardKey(combo)) {
                try map.addWarning("cannot rebind reserved clipboard key");
                continue;
            }

            // Remove old binding for this action, then add new one (1:1)
            map.removeByAction(action);

            // conflict detection (combo already bound to different action)
            if (map.get(combo)) |existing| {
                if (existing != action) {
                    try map.addWarning("keybinding conflict: combo already bound to different action");
                }
            }

            try map.put(combo, action);
        }
    }

    return map;
}

/// User binding entry for buildMap. One combo per action.
pub const UserBinding = struct {
    action_name: []const u8,
    combo_str: []const u8,
};

// -- Internal helpers --

fn toLowerBuf(s: []const u8) [64]u8 {
    var buf: [64]u8 = [_]u8{0} ** 64;
    const len = @min(s.len, 64);
    for (s[0..len], 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf;
}

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn matchSpecialKey(name: []const u8) ?SpecialKey {
    const map = [_]struct { n: []const u8, k: SpecialKey }{
        .{ .n = "insert", .k = .insert },
        .{ .n = "ins", .k = .insert },
        .{ .n = "delete", .k = .delete },
        .{ .n = "del", .k = .delete },
        .{ .n = "home", .k = .home },
        .{ .n = "end", .k = .end },
        .{ .n = "pageup", .k = .page_up },
        .{ .n = "page_up", .k = .page_up },
        .{ .n = "pgup", .k = .page_up },
        .{ .n = "pagedown", .k = .page_down },
        .{ .n = "page_down", .k = .page_down },
        .{ .n = "pgdn", .k = .page_down },
        .{ .n = "up", .k = .up },
        .{ .n = "down", .k = .down },
        .{ .n = "left", .k = .left },
        .{ .n = "right", .k = .right },
        .{ .n = "tab", .k = .tab },
        .{ .n = "enter", .k = .enter },
        .{ .n = "return", .k = .enter },
        .{ .n = "escape", .k = .escape },
        .{ .n = "esc", .k = .escape },
        .{ .n = "backspace", .k = .backspace },
        .{ .n = "bs", .k = .backspace },
        .{ .n = "f1", .k = .f1 },
        .{ .n = "f2", .k = .f2 },
        .{ .n = "f3", .k = .f3 },
        .{ .n = "f4", .k = .f4 },
        .{ .n = "f5", .k = .f5 },
        .{ .n = "f6", .k = .f6 },
        .{ .n = "f7", .k = .f7 },
        .{ .n = "f8", .k = .f8 },
        .{ .n = "f9", .k = .f9 },
        .{ .n = "f10", .k = .f10 },
        .{ .n = "f11", .k = .f11 },
        .{ .n = "f12", .k = .f12 },
    };

    for (map) |entry| {
        if (strEql(name, entry.n)) return entry.k;
    }
    return null;
}

// -------------------------------------------------------
// Inline Tests
// -------------------------------------------------------

test "parseKeyCombo: ctrl+c" {
    const combo = try parseKeyCombo("ctrl+c");
    try std.testing.expect(combo.key.eql(.{ .char = 'c' }));
    try std.testing.expect(combo.mods.ctrl);
    try std.testing.expect(!combo.mods.shift);
}

test "parseKeyCombo: ctrl+shift+t" {
    const combo = try parseKeyCombo("ctrl+shift+t");
    try std.testing.expect(combo.key.eql(.{ .char = 't' }));
    try std.testing.expect(combo.mods.ctrl);
    try std.testing.expect(combo.mods.shift);
}

test "parseKeyCombo: shift+insert" {
    const combo = try parseKeyCombo("shift+insert");
    try std.testing.expect(combo.key.eql(.{ .special = .insert }));
    try std.testing.expect(combo.mods.shift);
}

test "parseKeyCombo: ctrl+=" {
    const combo = try parseKeyCombo("ctrl+=");
    try std.testing.expect(combo.key.eql(.{ .char = '=' }));
    try std.testing.expect(combo.mods.ctrl);
}

test "parseKeyCombo: shift+pageup" {
    const combo = try parseKeyCombo("shift+pageup");
    try std.testing.expect(combo.key.eql(.{ .special = .page_up }));
    try std.testing.expect(combo.mods.shift);
}

test "parseKeyCombo: super+c" {
    const combo = try parseKeyCombo("super+c");
    try std.testing.expect(combo.key.eql(.{ .char = 'c' }));
    try std.testing.expect(combo.mods.super);
}

test "parseKeyCombo: invalid returns error" {
    try std.testing.expectError(ParseError.InvalidKeyCombo, parseKeyCombo("invalid"));
}

test "isReservedClipboardKey: ctrl+c IS reserved" {
    const combo = try parseKeyCombo("ctrl+c");
    try std.testing.expect(isReservedClipboardKey(combo));
}

test "isReservedClipboardKey: ctrl+v IS reserved (paste)" {
    const combo = try parseKeyCombo("ctrl+v");
    try std.testing.expect(isReservedClipboardKey(combo));
}

test "isReservedClipboardKey: super+c IS reserved" {
    const combo = try parseKeyCombo("super+c");
    try std.testing.expect(isReservedClipboardKey(combo));
}

test "isReservedClipboardKey: ctrl+shift+t is NOT reserved" {
    const combo = try parseKeyCombo("ctrl+shift+t");
    try std.testing.expect(!isReservedClipboardKey(combo));
}

test "defaultBindings contains expected actions" {
    const defaults = defaultBindings();
    var found_paste = false;
    var found_new_tab = false;
    var found_scroll_up = false;
    var found_increase_font = false;
    for (defaults) |b| {
        if (b.action == .paste) found_paste = true;
        if (b.action == .new_tab) found_new_tab = true;
        if (b.action == .scroll_page_up) found_scroll_up = true;
        if (b.action == .increase_font_size) found_increase_font = true;
    }
    try std.testing.expect(found_paste);
    try std.testing.expect(found_new_tab);
    try std.testing.expect(found_scroll_up);
    try std.testing.expect(found_increase_font);
}

test "buildMap: default map has paste on ctrl+v" {
    var map = try buildMap(std.testing.allocator, null);
    defer map.deinit();
    const combo = try parseKeyCombo("ctrl+v");
    try std.testing.expectEqual(Action.paste, map.get(combo).?);
}

test "buildMap: user override replaces default" {
    const overrides = [_]UserBinding{
        .{ .action_name = "new_tab", .combo_str = "ctrl+n" },
    };
    var map = try buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    // ctrl+n should now be new_tab
    const combo_n = try parseKeyCombo("ctrl+n");
    try std.testing.expectEqual(Action.new_tab, map.get(combo_n).?);
}

test "buildMap: reserved key override emits warning" {
    // Trying to bind ctrl+v to new_tab should be rejected (paste is reserved)
    const overrides = [_]UserBinding{
        .{ .action_name = "new_tab", .combo_str = "ctrl+v" },
    };
    var map = try buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    // ctrl+v should still be paste (reserved), not new_tab
    const combo = try parseKeyCombo("ctrl+v");
    try std.testing.expectEqual(Action.paste, map.get(combo).?);

    // Should have a warning
    try std.testing.expect(map.warnings.items.len > 0);
}

test "buildMap: unbind via none" {
    const overrides = [_]UserBinding{
        .{ .action_name = "scroll_page_up", .combo_str = "none" },
    };
    var map = try buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    // shift+pageup should no longer be bound
    const combo = try parseKeyCombo("shift+pageup");
    try std.testing.expect(map.get(combo) == null);
}

test "buildMap: conflict detection warns" {
    // Bind two actions to same combo
    const overrides = [_]UserBinding{
        .{ .action_name = "search", .combo_str = "ctrl+shift+t" },
    };
    var map = try buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    // ctrl+shift+t was default new_tab, now overridden to search (with warning)
    const combo = try parseKeyCombo("ctrl+shift+t");
    try std.testing.expectEqual(Action.search, map.get(combo).?);
    try std.testing.expect(map.warnings.items.len > 0);
}

test "buildMap: user cannot rebind reserved copy action" {
    const overrides = [_]UserBinding{
        .{ .action_name = "copy", .combo_str = "ctrl+shift+c" },
    };
    var map = try buildMap(std.testing.allocator, &overrides);
    defer map.deinit();

    // copy is reserved — override should be rejected
    const combo = try parseKeyCombo("ctrl+shift+c");
    try std.testing.expect(map.get(combo) == null);

    // ctrl+c should NOT be mapped (passes to terminal)
    const old = try parseKeyCombo("ctrl+c");
    try std.testing.expect(map.get(old) == null);
}

test "KeyCombo hash and equality" {
    const a = try parseKeyCombo("ctrl+c");
    const b = try parseKeyCombo("ctrl+c");
    try std.testing.expect(a.eql(b));
    try std.testing.expectEqual(a.hash(), b.hash());

    const c = try parseKeyCombo("ctrl+v");
    try std.testing.expect(!a.eql(c));
}
