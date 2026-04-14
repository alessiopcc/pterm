/// Layout preset definitions and parser for TOML config.
///
/// Named layout presets allow users to define workspace configurations
/// in TOML with tabs, panes, working directories, and startup commands.
/// The parser converts flat pane lists into binary tree structures for
/// the PaneTree layout system.
///
/// TOML format:
///   [layout.<name>]
///   [[layout.<name>.tab]]
///     [[layout.<name>.tab.pane]]
///     dir = "~/project/api"
///     cmd = "npm run dev"
///     split = "right"
///     ratio = 0.5
const std = @import("std");
const PaneTree = @import("PaneTree.zig");
const PaneNode = PaneTree.PaneNode;
const SplitDirection = PaneTree.SplitDirection;

pub const ParseError = error{
    InvalidSplitDirection,
    MalformedToml,
    OutOfMemory,
};

/// A single pane in a preset definition.
pub const PresetPane = struct {
    dir: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    split: ?SplitDirection = null, // null for the first pane (root)
    ratio: f32 = 0.5,
    shell: ?[]const u8 = null, // per-pane shell override
    shell_args: ?[]const []const u8 = null, // per-pane shell args
};

/// A tab in a preset, containing one or more panes.
pub const PresetTab = struct {
    panes: []const PresetPane,
    /// Whether this tab is an agent tab (pulsing alerts when waiting).
    agent: bool = false,
};

/// A named layout preset with one or more tabs.
pub const LayoutPreset = struct {
    name: []const u8,
    tabs: []const PresetTab,
};

/// Result of building a pane tree from a preset tab.
pub const BuildResult = struct {
    root: *PaneNode,
    pane_count: u32,
};

/// Parse layout presets from raw TOML content.
///
/// Scans for `[layout.<name>]` sections and extracts tab/pane definitions.
/// Layout names are dynamic so we parse manually (same approach as keybindings).
pub fn parsePresets(allocator: std.mem.Allocator, content: []const u8) ParseError![]LayoutPreset {
    var presets = std.ArrayListUnmanaged(LayoutPreset){};
    errdefer {
        for (presets.items) |preset| {
            freePreset(allocator, preset);
        }
        presets.deinit(allocator);
    }

    // Collect all unique layout names first
    var layout_names = std.ArrayListUnmanaged([]const u8){};
    defer layout_names.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 3 or trimmed[0] != '[') continue;

        // Look for [layout.NAME] (not [[...]])
        if (trimmed.len > 1 and trimmed[1] == '[') continue;

        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " ");
        if (!std.mem.startsWith(u8, inner, "layout.")) continue;

        const rest = inner["layout.".len..];
        // Skip sub-tables like layout.work.tab
        if (std.mem.indexOf(u8, rest, ".") != null) continue;

        // Check if name already in list
        var found = false;
        for (layout_names.items) |existing| {
            if (std.mem.eql(u8, existing, rest)) {
                found = true;
                break;
            }
        }
        if (!found) {
            layout_names.append(allocator, rest) catch return error.OutOfMemory;
        }
    }

    // Parse each layout section
    for (layout_names.items) |name| {
        const preset = parseOnePreset(allocator, content, name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSplitDirection => return error.InvalidSplitDirection,
            error.MalformedToml => return error.MalformedToml,
        };
        presets.append(allocator, preset) catch return error.OutOfMemory;
    }

    return presets.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Parse a single layout preset by name from TOML content.
fn parseOnePreset(allocator: std.mem.Allocator, content: []const u8, name: []const u8) ParseError!LayoutPreset {
    var tabs = std.ArrayListUnmanaged(PresetTab){};
    errdefer {
        for (tabs.items) |tab| {
            allocator.free(tab.panes);
        }
        tabs.deinit(allocator);
    }

    var current_panes = std.ArrayListUnmanaged(PresetPane){};
    errdefer current_panes.deinit(allocator);

    // Build expected section headers
    var tab_header_buf: [256]u8 = undefined;
    const tab_header = std.fmt.bufPrint(&tab_header_buf, "layout.{s}.tab", .{name}) catch return error.OutOfMemory;

    var pane_header_buf: [256]u8 = undefined;
    const pane_header = std.fmt.bufPrint(&pane_header_buf, "layout.{s}.tab.pane", .{name}) catch return error.OutOfMemory;

    const State = enum { none, in_tab, in_pane };
    var state: State = .none;
    var current_pane: PresetPane = .{};
    var in_pane = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Check for section headers
        if (trimmed[0] == '[') {
            // Finish current pane if any
            if (in_pane) {
                // Expand ~ in dir
                const expanded_pane = expandPaneDir(allocator, current_pane) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
                current_panes.append(allocator, expanded_pane) catch return error.OutOfMemory;
                current_pane = .{};
                in_pane = false;
            }

            const is_array = trimmed.len > 1 and trimmed[1] == '[';
            if (is_array) {
                // [[layout.NAME.tab.pane]] or [[layout.NAME.tab]]
                const inner_end = std.mem.indexOf(u8, trimmed, "]]") orelse continue;
                const inner = std.mem.trim(u8, trimmed[2..inner_end], " ");

                if (std.mem.eql(u8, inner, pane_header)) {
                    state = .in_pane;
                    in_pane = true;
                    current_pane = .{};
                } else if (std.mem.eql(u8, inner, tab_header)) {
                    // Finish previous tab if panes accumulated
                    if (current_panes.items.len > 0) {
                        const panes_slice = current_panes.toOwnedSlice(allocator) catch return error.OutOfMemory;
                        tabs.append(allocator, .{ .panes = panes_slice }) catch return error.OutOfMemory;
                    }
                    state = .in_tab;
                } else {
                    // Different section, stop parsing this preset
                    if (state != .none) break;
                }
            } else {
                // Single bracket section [layout.something]
                const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " ");
                if (!std.mem.startsWith(u8, inner, "layout.")) {
                    if (state != .none) break; // Left our section
                    continue;
                }
                const rest = inner["layout.".len..];
                if (std.mem.eql(u8, rest, name)) {
                    state = .in_tab;
                } else if (state != .none) {
                    break; // Different layout section
                }
            }
            continue;
        }

        // Parse key = value pairs inside pane section
        if (state == .in_pane and in_pane) {
            const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
            var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");
            // Strip quotes
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }

            if (std.mem.eql(u8, key, "dir")) {
                current_pane.dir = allocator.dupe(u8, value) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, key, "cmd")) {
                current_pane.cmd = allocator.dupe(u8, value) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, key, "split")) {
                current_pane.split = parseSplitDirection(value) orelse return error.InvalidSplitDirection;
            } else if (std.mem.eql(u8, key, "ratio")) {
                current_pane.ratio = std.fmt.parseFloat(f32, value) catch 0.5;
            } else if (std.mem.eql(u8, key, "shell")) {
                current_pane.shell = allocator.dupe(u8, value) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, key, "shell_args")) {
                // Parse TOML inline array: ["--login", "--norc"]
                // Re-read the raw value (before quote stripping) for array parsing
                const raw_value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");
                current_pane.shell_args = parseInlineStringArray(allocator, raw_value) catch return error.OutOfMemory;
            }
        }
    }

    // Finish last pane and tab
    if (in_pane) {
        const expanded_pane = expandPaneDir(allocator, current_pane) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        current_panes.append(allocator, expanded_pane) catch return error.OutOfMemory;
    }
    if (current_panes.items.len > 0) {
        const panes_slice = current_panes.toOwnedSlice(allocator) catch return error.OutOfMemory;
        tabs.append(allocator, .{ .panes = panes_slice }) catch return error.OutOfMemory;
    }

    const name_duped = allocator.dupe(u8, name) catch return error.OutOfMemory;
    const tabs_slice = tabs.toOwnedSlice(allocator) catch return error.OutOfMemory;

    return .{
        .name = name_duped,
        .tabs = tabs_slice,
    };
}

/// Parse a TOML inline string array like ["--login", "--norc"].
/// Returns null if the array is empty or malformed.
fn parseInlineStringArray(allocator: std.mem.Allocator, value: []const u8) !?[]const []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[') return null;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return null;
    const inner = std.mem.trim(u8, trimmed[1..close], " \t");
    if (inner.len == 0) return null;

    var items = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, inner, ',');
    while (iter.next()) |part| {
        var s = std.mem.trim(u8, part, " \t");
        // Strip quotes
        if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            s = s[1 .. s.len - 1];
        }
        if (s.len > 0) {
            try items.append(allocator, try allocator.dupe(u8, s));
        }
    }
    if (items.items.len == 0) return null;
    return try items.toOwnedSlice(allocator);
}

/// Parse a split direction string.
/// "right" or "horizontal" -> .vertical (side by side)
/// "bottom" or "vertical" -> .horizontal (stacked)
/// "left" -> .vertical, "top" -> .horizontal
fn parseSplitDirection(value: []const u8) ?SplitDirection {
    if (std.mem.eql(u8, value, "right") or std.mem.eql(u8, value, "horizontal")) {
        return .vertical; // side by side = vertical split
    }
    if (std.mem.eql(u8, value, "bottom") or std.mem.eql(u8, value, "vertical")) {
        return .horizontal; // stacked = horizontal split
    }
    if (std.mem.eql(u8, value, "left")) return .vertical;
    if (std.mem.eql(u8, value, "top")) return .horizontal;
    return null;
}

/// Build a PaneNode binary tree from a flat list of PresetPanes.
/// First pane becomes root leaf. Subsequent panes split from the last leaf.
pub fn buildTree(allocator: std.mem.Allocator, panes: []const PresetPane, start_pane_id: u32) !BuildResult {
    if (panes.len == 0) {
        // Create a single empty leaf
        const root = try PaneTree.createLeaf(allocator, start_pane_id, null);
        return .{ .root = root, .pane_count = 1 };
    }

    // First pane is the root leaf
    const root = try PaneTree.createLeaf(allocator, start_pane_id, null);
    var current_leaf = root;
    var pane_count: u32 = 1;

    // Each subsequent pane splits the current leaf
    for (panes[1..]) |pane| {
        const direction = pane.split orelse .vertical; // default to right split
        const ratio = pane.ratio;

        // Create new branch: current leaf becomes first child, new pane is second
        const new_leaf = try PaneTree.createLeaf(allocator, start_pane_id + pane_count, null);
        const old_id = current_leaf.leaf.pane_id;
        const old_parent = current_leaf.leaf.parent;

        const first_leaf = try PaneTree.createLeaf(allocator, old_id, null);

        // Convert current_leaf in-place to branch
        current_leaf.* = .{ .branch = .{
            .direction = direction,
            .ratio = ratio,
            .first = first_leaf,
            .second = new_leaf,
            .parent = old_parent,
        } };

        first_leaf.leaf.parent = current_leaf;
        new_leaf.leaf.parent = current_leaf;

        current_leaf = new_leaf;
        pane_count += 1;
    }

    return .{ .root = root, .pane_count = pane_count };
}

/// Expand ~ prefix in a pane's dir path to user home directory.
fn expandPaneDir(allocator: std.mem.Allocator, pane: PresetPane) !PresetPane {
    var result = pane;
    if (pane.dir) |dir| {
        if (dir.len > 0 and dir[0] == '~') {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch
                std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
                return result; // can't expand, keep as-is
            defer allocator.free(home);
            const rest = if (dir.len > 1) dir[1..] else "";
            const expanded = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, rest }) catch return error.OutOfMemory;
            // Free the original dir (was duped)
            allocator.free(dir);
            result.dir = expanded;
        }
    }
    return result;
}

/// Format a parse error into a user-friendly message.
/// Per UI-SPEC copywriting: Layout "{name}": {detail}. Check TOML syntax.
pub fn formatError(
    name: []const u8,
    detail: []const u8,
    buf: []u8,
) []const u8 {
    return std.fmt.bufPrint(buf, "Layout \"{s}\": {s}. Check TOML syntax.", .{ name, detail }) catch
        "Layout parse error. Check TOML syntax.";
}

/// Free a LayoutPreset's allocated memory.
pub fn freePreset(allocator: std.mem.Allocator, preset: LayoutPreset) void {
    allocator.free(preset.name);
    for (preset.tabs) |tab| {
        for (tab.panes) |pane| {
            if (pane.dir) |d| allocator.free(d);
            if (pane.cmd) |c| allocator.free(c);
            if (pane.shell) |s| allocator.free(s);
            if (pane.shell_args) |sa| {
                for (sa) |arg| allocator.free(arg);
                allocator.free(sa);
            }
        }
        allocator.free(tab.panes);
    }
    allocator.free(preset.tabs);
}

/// Free a slice of LayoutPresets.
pub fn freePresets(allocator: std.mem.Allocator, presets: []LayoutPreset) void {
    for (presets) |preset| {
        freePreset(allocator, preset);
    }
    allocator.free(presets);
}

// -------------------------------------------------------
// Tests
// -------------------------------------------------------

test "parsePresets: empty content returns empty" {
    const alloc = std.testing.allocator;
    const presets = try parsePresets(alloc, "");
    defer alloc.free(presets);
    try std.testing.expectEqual(@as(usize, 0), presets.len);
}

test "parsePresets: single preset with 2 tabs and 3 panes" {
    const alloc = std.testing.allocator;
    const toml =
        \\[layout.work]
        \\[[layout.work.tab]]
        \\  [[layout.work.tab.pane]]
        \\  dir = "/home/user/api"
        \\  cmd = "npm run dev"
        \\
        \\  [[layout.work.tab.pane]]
        \\  dir = "/home/user/api"
        \\  split = "right"
        \\  ratio = 0.5
        \\
        \\[[layout.work.tab]]
        \\  [[layout.work.tab.pane]]
        \\  dir = "/home/user/web"
        \\  cmd = "npm start"
    ;

    const presets = try parsePresets(alloc, toml);
    defer {
        for (presets) |p| freePreset(alloc, p);
        alloc.free(presets);
    }

    try std.testing.expectEqual(@as(usize, 1), presets.len);
    try std.testing.expect(std.mem.eql(u8, "work", presets[0].name));
    try std.testing.expectEqual(@as(usize, 2), presets[0].tabs.len);

    // First tab has 2 panes
    try std.testing.expectEqual(@as(usize, 2), presets[0].tabs[0].panes.len);
    try std.testing.expect(presets[0].tabs[0].panes[0].dir != null);
    try std.testing.expect(std.mem.eql(u8, "/home/user/api", presets[0].tabs[0].panes[0].dir.?));
    try std.testing.expect(std.mem.eql(u8, "npm run dev", presets[0].tabs[0].panes[0].cmd.?));
    try std.testing.expect(presets[0].tabs[0].panes[0].split == null); // first pane has no split
    try std.testing.expectEqual(SplitDirection.vertical, presets[0].tabs[0].panes[1].split.?);
    try std.testing.expectEqual(@as(f32, 0.5), presets[0].tabs[0].panes[1].ratio);

    // Second tab has 1 pane
    try std.testing.expectEqual(@as(usize, 1), presets[0].tabs[1].panes.len);
    try std.testing.expect(std.mem.eql(u8, "/home/user/web", presets[0].tabs[1].panes[0].dir.?));
}

test "parsePresets: multiple presets" {
    const alloc = std.testing.allocator;
    const toml =
        \\[layout.dev]
        \\[[layout.dev.tab]]
        \\  [[layout.dev.tab.pane]]
        \\  dir = "/tmp/dev"
        \\
        \\[layout.prod]
        \\[[layout.prod.tab]]
        \\  [[layout.prod.tab.pane]]
        \\  dir = "/tmp/prod"
    ;

    const presets = try parsePresets(alloc, toml);
    defer {
        for (presets) |p| freePreset(alloc, p);
        alloc.free(presets);
    }

    try std.testing.expectEqual(@as(usize, 2), presets.len);
    try std.testing.expect(std.mem.eql(u8, "dev", presets[0].name));
    try std.testing.expect(std.mem.eql(u8, "prod", presets[1].name));
}

test "parsePresets: missing dir/cmd uses defaults" {
    const alloc = std.testing.allocator;
    const toml =
        \\[layout.minimal]
        \\[[layout.minimal.tab]]
        \\  [[layout.minimal.tab.pane]]
        \\
        \\  [[layout.minimal.tab.pane]]
        \\  split = "bottom"
    ;

    const presets = try parsePresets(alloc, toml);
    defer {
        for (presets) |p| freePreset(alloc, p);
        alloc.free(presets);
    }

    try std.testing.expectEqual(@as(usize, 1), presets.len);
    try std.testing.expectEqual(@as(usize, 2), presets[0].tabs[0].panes.len);
    try std.testing.expect(presets[0].tabs[0].panes[0].dir == null);
    try std.testing.expect(presets[0].tabs[0].panes[0].cmd == null);
    try std.testing.expectEqual(SplitDirection.horizontal, presets[0].tabs[0].panes[1].split.?);
}

test "parsePresets: invalid split direction returns error" {
    const alloc = std.testing.allocator;
    const toml =
        \\[layout.bad]
        \\[[layout.bad.tab]]
        \\  [[layout.bad.tab.pane]]
        \\  split = "diagonal"
    ;

    const result = parsePresets(alloc, toml);
    try std.testing.expectError(error.InvalidSplitDirection, result);
}

test "buildTree: 3 panes produces correct tree" {
    const alloc = std.testing.allocator;
    const panes = [_]PresetPane{
        .{ .dir = null, .cmd = null, .split = null, .ratio = 0.5 },
        .{ .dir = null, .cmd = null, .split = .vertical, .ratio = 0.5 },
        .{ .dir = null, .cmd = null, .split = .horizontal, .ratio = 0.6 },
    };

    const result = try buildTree(alloc, &panes, 10);
    defer PaneTree.destroyNode(alloc, result.root);

    try std.testing.expectEqual(@as(u32, 3), result.pane_count);

    // Root should be a branch (first pane split by second)
    try std.testing.expect(result.root.* == .branch);
    const root_branch = result.root.branch;
    try std.testing.expectEqual(SplitDirection.vertical, root_branch.direction);

    // First child is leaf with pane_id 10
    try std.testing.expect(root_branch.first.* == .leaf);
    try std.testing.expectEqual(@as(u32, 10), root_branch.first.leaf.pane_id);

    // Second child is a branch (second pane split by third)
    try std.testing.expect(root_branch.second.* == .branch);
    const inner_branch = root_branch.second.branch;
    try std.testing.expectEqual(SplitDirection.horizontal, inner_branch.direction);
    try std.testing.expectEqual(@as(f32, 0.6), inner_branch.ratio);

    // Inner branch has two leaves: pane 11 and pane 12
    try std.testing.expectEqual(@as(u32, 11), inner_branch.first.leaf.pane_id);
    try std.testing.expectEqual(@as(u32, 12), inner_branch.second.leaf.pane_id);
}

test "buildTree: single pane returns single leaf" {
    const alloc = std.testing.allocator;
    const panes = [_]PresetPane{
        .{ .dir = null, .cmd = null, .split = null, .ratio = 0.5 },
    };

    const result = try buildTree(alloc, &panes, 0);
    defer PaneTree.destroyNode(alloc, result.root);

    try std.testing.expectEqual(@as(u32, 1), result.pane_count);
    try std.testing.expect(result.root.* == .leaf);
    try std.testing.expectEqual(@as(u32, 0), result.root.leaf.pane_id);
}

test "buildTree: empty panes returns single leaf" {
    const alloc = std.testing.allocator;
    const panes = [_]PresetPane{};

    const result = try buildTree(alloc, &panes, 5);
    defer PaneTree.destroyNode(alloc, result.root);

    try std.testing.expectEqual(@as(u32, 1), result.pane_count);
    try std.testing.expect(result.root.* == .leaf);
    try std.testing.expectEqual(@as(u32, 5), result.root.leaf.pane_id);
}

test "parseSplitDirection: all valid directions" {
    try std.testing.expectEqual(SplitDirection.vertical, parseSplitDirection("right").?);
    try std.testing.expectEqual(SplitDirection.vertical, parseSplitDirection("horizontal").?);
    try std.testing.expectEqual(SplitDirection.horizontal, parseSplitDirection("bottom").?);
    try std.testing.expectEqual(SplitDirection.horizontal, parseSplitDirection("vertical").?);
    try std.testing.expectEqual(SplitDirection.vertical, parseSplitDirection("left").?);
    try std.testing.expectEqual(SplitDirection.horizontal, parseSplitDirection("top").?);
    try std.testing.expect(parseSplitDirection("diagonal") == null);
}

test "formatError produces correct message" {
    var buf: [256]u8 = undefined;
    const msg = formatError("work", "unknown split direction", &buf);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Layout \"work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Check TOML syntax") != null);
}

test "parsePresets: pane with shell and shell_args" {
    const alloc = std.testing.allocator;
    const toml =
        \\[layout.mixed]
        \\[[layout.mixed.tab]]
        \\  [[layout.mixed.tab.pane]]
        \\  dir = "/tmp"
        \\  shell = "bash"
        \\  shell_args = ["--login", "--norc"]
        \\
        \\  [[layout.mixed.tab.pane]]
        \\  split = "right"
        \\  shell = "fish"
    ;
    const presets = try parsePresets(alloc, toml);
    defer {
        for (presets) |p| freePreset(alloc, p);
        alloc.free(presets);
    }
    try std.testing.expectEqual(@as(usize, 1), presets.len);
    const panes = presets[0].tabs[0].panes;
    try std.testing.expectEqual(@as(usize, 2), panes.len);
    // First pane has shell and shell_args
    try std.testing.expect(std.mem.eql(u8, "bash", panes[0].shell.?));
    try std.testing.expect(panes[0].shell_args != null);
    try std.testing.expectEqual(@as(usize, 2), panes[0].shell_args.?.len);
    try std.testing.expect(std.mem.eql(u8, "--login", panes[0].shell_args.?[0]));
    try std.testing.expect(std.mem.eql(u8, "--norc", panes[0].shell_args.?[1]));
    // Second pane has shell but no shell_args
    try std.testing.expect(std.mem.eql(u8, "fish", panes[1].shell.?));
    try std.testing.expect(panes[1].shell_args == null);
}

test "parseInlineStringArray: valid array" {
    const alloc = std.testing.allocator;
    const result = try parseInlineStringArray(alloc, "[\"--login\", \"--norc\"]");
    try std.testing.expect(result != null);
    defer {
        for (result.?) |item| alloc.free(item);
        alloc.free(result.?);
    }
    try std.testing.expectEqual(@as(usize, 2), result.?.len);
    try std.testing.expect(std.mem.eql(u8, "--login", result.?[0]));
    try std.testing.expect(std.mem.eql(u8, "--norc", result.?[1]));
}

test "parseInlineStringArray: empty array returns null" {
    const alloc = std.testing.allocator;
    const result = try parseInlineStringArray(alloc, "[]");
    try std.testing.expect(result == null);
}

test "parseInlineStringArray: non-array returns null" {
    const alloc = std.testing.allocator;
    const result = try parseInlineStringArray(alloc, "not an array");
    try std.testing.expect(result == null);
}
