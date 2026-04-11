/// Built-in color themes (D-27): 8 popular themes embedded in binary.
///
/// Each theme defines all color fields including UI chrome per D-28.
/// Theme files are loaded via the TOML import directive; these built-in
/// themes provide immediate access without external files.
const theme = @import("theme");
const ColorPalette = theme.ColorPalette;
const UiColors = theme.UiColors;

/// Number of built-in themes.
pub const theme_count: usize = 8;

/// All theme names in display order.
pub const theme_names: [theme_count][]const u8 = .{
    "default",
    "dracula",
    "solarized-dark",
    "solarized-light",
    "gruvbox-dark",
    "nord",
    "catppuccin-mocha",
    "one-dark",
};

/// Look up a built-in theme by name.
pub fn get(name: []const u8) ?ColorPalette {
    for (theme_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) {
            return all_themes[i];
        }
    }
    return null;
}

/// Return the list of all built-in theme names.
pub fn list() []const []const u8 {
    return &theme_names;
}

const std = @import("std");

// ---------------------------------------------------------------
// Theme definitions
// ---------------------------------------------------------------

/// TermP default (Catppuccin Mocha — matches existing hardcoded palette).
const default_theme = ColorPalette{
    .foreground = "#CDD6F4",
    .background = "#1E1E2E",
    .cursor = "#F5E0DC",
    .cursor_text = "#1E1E2E",
    .selection_bg = "#45475A",
    .selection_fg = "#CDD6F4",
    .normal = .{
        "#45475A", // black
        "#F38BA8", // red
        "#A6E3A1", // green
        "#F9E2AF", // yellow
        "#89B4FA", // blue
        "#F5C2E7", // magenta
        "#94E2D5", // cyan
        "#BAC2DE", // white
    },
    .bright = .{
        "#585B70", // bright black
        "#F38BA8", // bright red
        "#A6E3A1", // bright green
        "#F9E2AF", // bright yellow
        "#89B4FA", // bright blue
        "#F5C2E7", // bright magenta
        "#94E2D5", // bright cyan
        "#A6ADC8", // bright white
    },
    .ui = .{
        .tab_bar_bg = .{ 0x18, 0x18, 0x25 },
        .tab_active = .{ 0x31, 0x32, 0x44 },
        .tab_inactive = .{ 0x1E, 0x1E, 0x2E },
        .pane_border = .{ 0x45, 0x47, 0x5A },
        .status_bar_bg = .{ 0x18, 0x18, 0x25 },
        .agent_alert = .{ 0xF9, 0xE2, 0xAF },
    },
};

/// Dracula (https://draculatheme.com/contribute#color-palette)
const dracula_theme = ColorPalette{
    .foreground = "#F8F8F2",
    .background = "#282A36",
    .cursor = "#F8F8F2",
    .cursor_text = "#282A36",
    .selection_bg = "#44475A",
    .selection_fg = "#F8F8F2",
    .normal = .{
        "#21222C", // black
        "#FF5555", // red
        "#50FA7B", // green
        "#F1FA8C", // yellow
        "#BD93F9", // blue
        "#FF79C6", // magenta
        "#8BE9FD", // cyan
        "#F8F8F2", // white
    },
    .bright = .{
        "#6272A4", // bright black
        "#FF6E6E", // bright red
        "#69FF94", // bright green
        "#FFFFA5", // bright yellow
        "#D6ACFF", // bright blue
        "#FF92DF", // bright magenta
        "#A4FFFF", // bright cyan
        "#FFFFFF", // bright white
    },
    .ui = .{
        .tab_bar_bg = .{ 0x21, 0x22, 0x2C },
        .tab_active = .{ 0x44, 0x47, 0x5A },
        .tab_inactive = .{ 0x28, 0x2A, 0x36 },
        .pane_border = .{ 0x44, 0x47, 0x5A },
        .status_bar_bg = .{ 0x21, 0x22, 0x2C },
        .agent_alert = .{ 0xF1, 0xFA, 0x8C },
    },
};

/// Solarized Dark (https://ethanschoonover.com/solarized/)
const solarized_dark_theme = ColorPalette{
    .foreground = "#839496",
    .background = "#002B36",
    .cursor = "#839496",
    .cursor_text = "#002B36",
    .selection_bg = "#073642",
    .selection_fg = "#93A1A1",
    .normal = .{
        "#073642", // black
        "#DC322F", // red
        "#859900", // green
        "#B58900", // yellow
        "#268BD2", // blue
        "#D33682", // magenta
        "#2AA198", // cyan
        "#EEE8D5", // white
    },
    .bright = .{
        "#002B36", // bright black
        "#CB4B16", // bright red
        "#586E75", // bright green
        "#657B83", // bright yellow
        "#839496", // bright blue
        "#6C71C4", // bright magenta
        "#93A1A1", // bright cyan
        "#FDF6E3", // bright white
    },
    .ui = .{
        .tab_bar_bg = .{ 0x00, 0x22, 0x2B },
        .tab_active = .{ 0x07, 0x36, 0x42 },
        .tab_inactive = .{ 0x00, 0x2B, 0x36 },
        .pane_border = .{ 0x07, 0x36, 0x42 },
        .status_bar_bg = .{ 0x00, 0x22, 0x2B },
        .agent_alert = .{ 0xB5, 0x89, 0x00 },
    },
};

/// Solarized Light (https://ethanschoonover.com/solarized/)
const solarized_light_theme = ColorPalette{
    .foreground = "#657B83",
    .background = "#FDF6E3",
    .cursor = "#657B83",
    .cursor_text = "#FDF6E3",
    .selection_bg = "#EEE8D5",
    .selection_fg = "#586E75",
    .normal = .{
        "#073642", // black
        "#DC322F", // red
        "#859900", // green
        "#B58900", // yellow
        "#268BD2", // blue
        "#D33682", // magenta
        "#2AA198", // cyan
        "#EEE8D5", // white
    },
    .bright = .{
        "#002B36", // bright black
        "#CB4B16", // bright red
        "#586E75", // bright green
        "#657B83", // bright yellow
        "#839496", // bright blue
        "#6C71C4", // bright magenta
        "#93A1A1", // bright cyan
        "#FDF6E3", // bright white
    },
    .ui = .{
        .tab_bar_bg = .{ 0xEE, 0xE8, 0xD5 },
        .tab_active = .{ 0xFD, 0xF6, 0xE3 },
        .tab_inactive = .{ 0xEE, 0xE8, 0xD5 },
        .pane_border = .{ 0x93, 0xA1, 0xA1 },
        .status_bar_bg = .{ 0xEE, 0xE8, 0xD5 },
        .agent_alert = .{ 0xCB, 0x4B, 0x16 },
    },
};

/// Gruvbox Dark (https://github.com/morhetz/gruvbox)
const gruvbox_dark_theme = ColorPalette{
    .foreground = "#EBDBB2",
    .background = "#282828",
    .cursor = "#EBDBB2",
    .cursor_text = "#282828",
    .selection_bg = "#504945",
    .selection_fg = "#EBDBB2",
    .normal = .{
        "#282828", // black
        "#CC241D", // red
        "#98971A", // green
        "#D79921", // yellow
        "#458588", // blue
        "#B16286", // magenta
        "#689D6A", // cyan
        "#A89984", // white
    },
    .bright = .{
        "#928374", // bright black
        "#FB4934", // bright red
        "#B8BB26", // bright green
        "#FABD2F", // bright yellow
        "#83A598", // bright blue
        "#D3869B", // bright magenta
        "#8EC07C", // bright cyan
        "#EBDBB2", // bright white
    },
    .ui = .{
        .tab_bar_bg = .{ 0x1D, 0x20, 0x21 },
        .tab_active = .{ 0x3C, 0x38, 0x36 },
        .tab_inactive = .{ 0x28, 0x28, 0x28 },
        .pane_border = .{ 0x50, 0x49, 0x45 },
        .status_bar_bg = .{ 0x1D, 0x20, 0x21 },
        .agent_alert = .{ 0xFA, 0xBD, 0x2F },
    },
};

/// Nord (https://www.nordtheme.com/docs/colors-and-palettes)
const nord_theme = ColorPalette{
    .foreground = "#D8DEE9",
    .background = "#2E3440",
    .cursor = "#D8DEE9",
    .cursor_text = "#2E3440",
    .selection_bg = "#434C5E",
    .selection_fg = "#D8DEE9",
    .normal = .{
        "#3B4252", // black
        "#BF616A", // red
        "#A3BE8C", // green
        "#EBCB8B", // yellow
        "#81A1C1", // blue
        "#B48EAD", // magenta
        "#88C0D0", // cyan
        "#E5E9F0", // white
    },
    .bright = .{
        "#4C566A", // bright black
        "#BF616A", // bright red
        "#A3BE8C", // bright green
        "#EBCB8B", // bright yellow
        "#81A1C1", // bright blue
        "#B48EAD", // bright magenta
        "#8FBCBB", // bright cyan
        "#ECEFF4", // bright white
    },
    .ui = .{
        .tab_bar_bg = .{ 0x29, 0x2E, 0x39 },
        .tab_active = .{ 0x3B, 0x42, 0x52 },
        .tab_inactive = .{ 0x2E, 0x34, 0x40 },
        .pane_border = .{ 0x43, 0x4C, 0x5E },
        .status_bar_bg = .{ 0x29, 0x2E, 0x39 },
        .agent_alert = .{ 0xEB, 0xCB, 0x8B },
    },
};

/// Catppuccin Mocha (identical to default — provided as explicit theme name).
const catppuccin_mocha_theme = default_theme;

/// One Dark (https://github.com/one-dark/vscode-one-dark-theme)
const one_dark_theme = ColorPalette{
    .foreground = "#ABB2BF",
    .background = "#282C34",
    .cursor = "#528BFF",
    .cursor_text = "#282C34",
    .selection_bg = "#3E4451",
    .selection_fg = "#ABB2BF",
    .normal = .{
        "#3F4451", // black
        "#E06C75", // red
        "#98C379", // green
        "#E5C07B", // yellow
        "#61AFEF", // blue
        "#C678DD", // magenta
        "#56B6C2", // cyan
        "#ABB2BF", // white
    },
    .bright = .{
        "#4F5666", // bright black
        "#BE5046", // bright red
        "#98C379", // bright green
        "#D19A66", // bright yellow
        "#61AFEF", // bright blue
        "#C678DD", // bright magenta
        "#56B6C2", // bright cyan
        "#FFFFFF", // bright white
    },
    .ui = .{
        .tab_bar_bg = .{ 0x21, 0x25, 0x2B },
        .tab_active = .{ 0x2C, 0x31, 0x3C },
        .tab_inactive = .{ 0x28, 0x2C, 0x34 },
        .pane_border = .{ 0x3E, 0x44, 0x51 },
        .status_bar_bg = .{ 0x21, 0x25, 0x2B },
        .agent_alert = .{ 0xE5, 0xC0, 0x7B },
    },
};

/// All themes in display order (matches theme_names).
const all_themes = [theme_count]ColorPalette{
    default_theme,
    dracula_theme,
    solarized_dark_theme,
    solarized_light_theme,
    gruvbox_dark_theme,
    nord_theme,
    catppuccin_mocha_theme,
    one_dark_theme,
};
