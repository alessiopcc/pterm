/// Per-pane search state for scrollback search (CORE-08).
///
/// Manages the lifecycle of a search session within a single pane:
///   - Open/close with scroll position save/restore
///   - Query buffer with addChar/deleteChar
///   - Match list with navigation and wrap-around
///   - Query persists between open/close within same pane
const std = @import("std");

pub const SearchState = struct {
    /// Saved viewport state for restore on search close.
    /// Mirrors ghostty-vt PageList.Viewport to avoid direct dependency.
    pub const SavedViewport = union(enum) {
        active, // Viewport was following active area (bottom)
        top, // Viewport was at top of scrollback
        row: u32, // Viewport was at specific row offset from top
    };

    pub const Match = struct {
        line_index: u32,
        col_start: u16,
        col_end: u16,
        in_scrollback: bool,
    };

    is_open: bool = false,
    query: [256]u8 = [_]u8{0} ** 256,
    query_len: u16 = 0,
    matches: std.ArrayListUnmanaged(Match) = .{},
    current_match: u32 = 0,
    total_matches: u32 = 0,
    scrollback_offset: u32 = 0,
    saved_viewport: SavedViewport = .active,
    query_dirty: bool = false,
    last_input_ns: i128 = 0,

    /// Open search overlay, saving the current viewport state.
    /// Does NOT clear query -- persists between open/close.
    pub fn open(self: *SearchState, current_viewport: SavedViewport) void {
        self.is_open = true;
        self.saved_viewport = current_viewport;
    }

    /// Close search overlay. Does NOT clear query.
    pub fn close(self: *SearchState) void {
        self.is_open = false;
    }

    /// Return saved viewport state for restore after search close.
    pub fn getSavedViewport(self: *const SearchState) SavedViewport {
        return self.saved_viewport;
    }

    /// Append a character to the query buffer.
    /// Silently ignores if buffer is full (256 bytes, per T-06-01).
    pub fn addChar(self: *SearchState, c: u8) void {
        if (self.query_len < 256) {
            self.query[self.query_len] = c;
            self.query_len += 1;
            self.query_dirty = true;
            self.last_input_ns = std.time.nanoTimestamp();
        }
    }

    /// Remove the last character from the query buffer.
    pub fn deleteChar(self: *SearchState) void {
        if (self.query_len > 0) {
            self.query_len -= 1;
            self.query[self.query_len] = 0;
            self.query_dirty = true;
            self.last_input_ns = std.time.nanoTimestamp();
        }
    }

    /// Return the current query as a slice.
    pub fn getQuery(self: *const SearchState) []const u8 {
        return self.query[0..self.query_len];
    }

    /// Navigate to the next match, wrapping from last to first.
    pub fn navigateNext(self: *SearchState) void {
        if (self.total_matches == 0) return;
        if (self.current_match + 1 >= self.total_matches) {
            self.current_match = 0;
        } else {
            self.current_match += 1;
        }
    }

    /// Navigate to the previous match, wrapping from first to last.
    pub fn navigatePrev(self: *SearchState) void {
        if (self.total_matches == 0) return;
        if (self.current_match == 0) {
            self.current_match = self.total_matches - 1;
        } else {
            self.current_match -= 1;
        }
    }

    /// Clear all matches and reset counters.
    pub fn clearMatches(self: *SearchState, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
        self.matches = .{};
        self.total_matches = 0;
        self.current_match = 0;
    }

    /// Replace match list with new results.
    pub fn updateMatches(self: *SearchState, allocator: std.mem.Allocator, new_matches: []const Match) void {
        self.clearMatches(allocator);
        self.matches.appendSlice(allocator, new_matches) catch return;
        self.total_matches = @intCast(new_matches.len);
        self.current_match = 0;
    }

    /// Return the currently selected match, or null if no matches.
    pub fn currentMatchInfo(self: *const SearchState) ?Match {
        if (self.total_matches == 0) return null;
        if (self.current_match >= self.matches.items.len) return null;
        return self.matches.items[self.current_match];
    }

    /// Free match list resources.
    pub fn deinit(self: *SearchState, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
        self.matches = .{};
        self.total_matches = 0;
    }
};

// -------------------------------------------------------
// Tests
// -------------------------------------------------------

test "SearchState: open saves viewport and sets is_open" {
    var state = SearchState{};
    try std.testing.expect(!state.is_open);

    state.open(.{ .row = 42 });
    try std.testing.expect(state.is_open);
    try std.testing.expectEqual(SearchState.SavedViewport{ .row = 42 }, state.saved_viewport);
}

test "SearchState: getSavedViewport returns saved state" {
    var state = SearchState{};
    state.open(.active);
    try std.testing.expectEqual(SearchState.SavedViewport.active, state.getSavedViewport());

    state.open(.top);
    try std.testing.expectEqual(SearchState.SavedViewport.top, state.getSavedViewport());

    state.open(.{ .row = 100 });
    try std.testing.expectEqual(SearchState.SavedViewport{ .row = 100 }, state.getSavedViewport());
}

test "SearchState: close sets is_open=false" {
    var state = SearchState{};
    state.open(.active);
    try std.testing.expect(state.is_open);

    state.close();
    try std.testing.expect(!state.is_open);
}

test "SearchState: query persists between open/close" {
    var state = SearchState{};
    state.open(.active);
    state.addChar('h');
    state.addChar('i');
    state.close();

    // Query persists after close
    try std.testing.expectEqualStrings("hi", state.getQuery());

    // Re-open: query still there
    state.open(.{ .row = 10 });
    try std.testing.expectEqualStrings("hi", state.getQuery());
}

test "SearchState: addChar appends, deleteChar removes" {
    var state = SearchState{};
    state.addChar('a');
    state.addChar('b');
    state.addChar('c');
    try std.testing.expectEqualStrings("abc", state.getQuery());

    state.deleteChar();
    try std.testing.expectEqualStrings("ab", state.getQuery());

    state.deleteChar();
    state.deleteChar();
    try std.testing.expectEqualStrings("", state.getQuery());

    // deleteChar on empty does nothing
    state.deleteChar();
    try std.testing.expectEqual(@as(u16, 0), state.query_len);
}

test "SearchState: navigateNext wraps from last to first" {
    var state = SearchState{};
    state.total_matches = 3;
    state.current_match = 0;

    state.navigateNext();
    try std.testing.expectEqual(@as(u32, 1), state.current_match);
    state.navigateNext();
    try std.testing.expectEqual(@as(u32, 2), state.current_match);
    // Wrap around
    state.navigateNext();
    try std.testing.expectEqual(@as(u32, 0), state.current_match);
}

test "SearchState: navigatePrev wraps from first to last" {
    var state = SearchState{};
    state.total_matches = 3;
    state.current_match = 0;

    // Wrap around to last
    state.navigatePrev();
    try std.testing.expectEqual(@as(u32, 2), state.current_match);
    state.navigatePrev();
    try std.testing.expectEqual(@as(u32, 1), state.current_match);
    state.navigatePrev();
    try std.testing.expectEqual(@as(u32, 0), state.current_match);
}

test "SearchState: navigate with zero matches does nothing" {
    var state = SearchState{};
    state.total_matches = 0;
    state.navigateNext();
    try std.testing.expectEqual(@as(u32, 0), state.current_match);
    state.navigatePrev();
    try std.testing.expectEqual(@as(u32, 0), state.current_match);
}

test "SearchState: updateMatches replaces match list" {
    const allocator = std.testing.allocator;
    var state = SearchState{};
    defer state.deinit(allocator);

    const matches = [_]SearchState.Match{
        .{ .line_index = 0, .col_start = 5, .col_end = 9, .in_scrollback = true },
        .{ .line_index = 3, .col_start = 0, .col_end = 4, .in_scrollback = false },
    };
    state.updateMatches(allocator, &matches);
    try std.testing.expectEqual(@as(u32, 2), state.total_matches);
    try std.testing.expectEqual(@as(u32, 0), state.current_match);

    const info = state.currentMatchInfo();
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u32, 0), info.?.line_index);
    try std.testing.expectEqual(@as(u16, 5), info.?.col_start);
}

test "SearchState: setQuery via addChar triggers re-search pattern" {
    var state = SearchState{};
    state.addChar('t');
    state.addChar('e');
    state.addChar('s');
    state.addChar('t');
    try std.testing.expectEqualStrings("test", state.getQuery());
    try std.testing.expectEqual(@as(u16, 4), state.query_len);
}
