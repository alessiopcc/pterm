/// Re-export and extend ghostty-vt Cell type for PTerm use.
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

/// Maximum number of codepoints in a grapheme cluster we support.
/// Covers skin-tone emoji (4-5 cps), ZWJ sequences (up to 7), and most
/// combining character runs.
pub const MAX_GRAPHEME_CODEPOINTS = 8;

/// Collect all codepoints for this cell's grapheme cluster into `out`.
/// The first codepoint comes from cell.codepoint(); extra codepoints
/// come from `extra_cps` (obtained via pin.grapheme(cell)).
/// Returns the number of codepoints written (0 if empty cell).
pub fn getGraphemeCodepoints(
    cell: Cell,
    extra_cps: ?[]u21,
    out: *[MAX_GRAPHEME_CODEPOINTS]u21,
) u8 {
    const cp0 = cell.codepoint();
    if (cp0 == 0) return 0;

    out[0] = cp0;
    var len: u8 = 1;

    if (extra_cps) |extras| {
        for (extras) |cp| {
            if (len >= MAX_GRAPHEME_CODEPOINTS) break;
            out[len] = cp;
            len += 1;
        }
    }

    return len;
}

/// Returns true if `cp` is in a Unicode emoji presentation range.
/// This is a heuristic covering the major emoji blocks (Unicode 16.0).
/// False positives are harmless -- they just trigger a color atlas lookup
/// that falls back to grayscale.
pub fn isEmojiCodepoint(cp: u21) bool {
    // ZWJ and variation selectors (critical for sequences)
    if (cp == 0x200D) return true; // ZWJ
    if (cp >= 0xFE00 and cp <= 0xFE0F) return true; // variation selectors

    // Major emoji blocks (covers ~95% of emoji)
    if (cp >= 0x1F300 and cp <= 0x1FAFF) return true;

    // Regional indicator symbols (flags)
    if (cp >= 0x1F1E0 and cp <= 0x1F1FF) return true;

    // Miscellaneous symbols
    if (cp >= 0x2600 and cp <= 0x26FF) return true;

    // Dingbats
    if (cp >= 0x2700 and cp <= 0x27BF) return true;

    // Watch, hourglass, media controls
    if (cp >= 0x231A and cp <= 0x231B) return true;
    if (cp >= 0x23E9 and cp <= 0x23F3) return true;
    if (cp >= 0x23F8 and cp <= 0x23FA) return true;

    // Geometric shapes with emoji presentation
    if (cp >= 0x25AA and cp <= 0x25AB) return true;
    if (cp == 0x25B6 or cp == 0x25C0) return true;
    if (cp >= 0x25FB and cp <= 0x25FE) return true;

    // Specific commonly-used emoji codepoints
    if (cp == 0x2702 or cp == 0x2705) return true;
    if (cp >= 0x2708 and cp <= 0x270D) return true;
    if (cp == 0x270F) return true;
    if (cp == 0x267F or cp == 0x2693 or cp == 0x26A1) return true;

    return false;
}
