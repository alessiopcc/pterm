/// Minimal hardcoded config (TOML config in Config.zig).
///
/// Provides default terminal configuration values. All fields have sensible
/// defaults that match the UI-SPEC contract.
pub const Config = struct {
    font_family: ?[]const u8 = null, // null = platform default
    font_size_pt: f32 = 13.0,
    cols: u16 = 160,
    rows: u16 = 48,
    grid_padding: f32 = 4.0,
    scrollback_lines: u32 = 10_000,
    window_title: [:0]const u8 = "PTerm",
};
