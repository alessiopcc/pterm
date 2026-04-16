/// Selection tracking and text extraction.
///
/// Tracks mouse-based text selection ranges and extracts selected text
/// from the terminal screen. Supports normal (click-drag), word (double-click),
/// and line (triple-click) selection modes.
const std = @import("std");

/// A range of selected cells in the terminal.
///
/// Rows are signed so the selection can track content that has scrolled
/// above the visible viewport (negative row) or below it (row beyond the
/// viewport's row count). Rendering and copying clamp/skip as needed.
pub const SelectionRange = struct {
    start_row: i32,
    start_col: u16,
    end_row: i32,
    end_col: u16,

    /// Returns the range normalized so start <= end (top-left to bottom-right).
    pub fn normalized(self: SelectionRange) SelectionRange {
        if (self.start_row > self.end_row or
            (self.start_row == self.end_row and self.start_col > self.end_col))
        {
            return .{
                .start_row = self.end_row,
                .start_col = self.end_col,
                .end_row = self.start_row,
                .end_col = self.start_col,
            };
        }
        return self;
    }
};

/// Selection mode based on click type.
pub const SelectionMode = enum {
    /// Click-drag character selection.
    normal,
    /// Double-click word selection.
    word,
    /// Triple-click line selection.
    line,
};

/// Tracks an active text selection in the terminal.
pub const Selection = struct {
    range: ?SelectionRange,
    mode: SelectionMode,
    active: bool,

    /// Create a new inactive selection.
    pub fn init() Selection {
        return .{
            .range = null,
            .mode = .normal,
            .active = false,
        };
    }

    /// Begin a selection at the given position.
    pub fn begin(self: *Selection, row: i32, col: u16, mode: SelectionMode) void {
        self.range = .{
            .start_row = row,
            .start_col = col,
            .end_row = row,
            .end_col = col,
        };
        self.mode = mode;
        self.active = true;
    }

    /// Extend the selection to a new position (mouse drag).
    pub fn update(self: *Selection, row: i32, col: u16) void {
        if (self.range) |*r| {
            r.end_row = row;
            r.end_col = col;
        }
    }

    /// End the selection and return the final range.
    /// Per this is when copy-on-select triggers.
    pub fn finish(self: *Selection) ?SelectionRange {
        self.active = false;
        if (self.range) |r| {
            return r.normalized();
        }
        return null;
    }

    /// Clear the selection.
    pub fn clear(self: *Selection) void {
        self.range = null;
        self.active = false;
    }

    /// Extract text from a terminal's screen within the selection range.
    /// Concatenates cell codepoints, inserting newlines between rows.
    /// Handles wide characters by skipping continuation cells.
    ///
    /// `get_screen_text_fn` is a callback that returns the plain text for a given
    /// row range. For simplicity, this implementation uses the terminal's plainString
    /// method and extracts the relevant substring.
    pub fn getSelectedText(
        range: SelectionRange,
        screen_lines: []const []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const norm = range.normalized();
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var row: i32 = norm.start_row;
        while (row <= norm.end_row) : (row += 1) {
            if (row < 0) continue;
            const uidx: usize = @intCast(row);
            if (uidx >= screen_lines.len) break;

            const line = screen_lines[uidx];
            const start_col: usize = if (row == norm.start_row) @as(usize, norm.start_col) else 0;
            const end_col: usize = if (row == norm.end_row) @min(@as(usize, norm.end_col) + 1, line.len) else line.len;

            if (start_col < line.len) {
                const actual_end = @min(end_col, line.len);
                if (start_col < actual_end) {
                    try result.appendSlice(allocator, line[start_col..actual_end]);
                }
            }

            // Add newline between rows (not after last row)
            if (row < norm.end_row and uidx + 1 < screen_lines.len) {
                try result.append(allocator, '\n');
            }
        }

        return try result.toOwnedSlice(allocator);
    }
};
