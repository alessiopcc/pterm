/// Re-export and extend ghostty-vt Cell type for TermP use.
const ghostty_vt = @import("ghostty-vt");

pub const Cell = ghostty_vt.Cell;
pub const Style = ghostty_vt.Style;

/// Returns true if the cell is a wide character (CJK double-width).
pub fn isWideChar(cell: Cell) bool {
    return cell.wide == .wide;
}

/// Returns true if cell has a non-default style (style_id != 0).
pub fn hasStyle(cell: Cell) bool {
    return cell.style_id != 0;
}

/// Returns the codepoint stored in this cell, or 0 if empty.
pub fn codepoint(cell: Cell) u21 {
    return cell.codepoint();
}
