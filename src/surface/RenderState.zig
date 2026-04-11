/// Build a RenderState snapshot from the terminal front buffer for GPU rendering.
///
/// This is the critical data transformation bridge: it reads ghostty-vt screen
/// cells and produces CellInstance arrays that the OpenGL backend consumes via
/// instanced rendering.
///
/// Thread safety: Called on the render thread after TermIO.swap()/getSnapshot().
/// The terminal pointer is stable until the next swap() call.
const std = @import("std");
const renderer_types = @import("renderer_types");
const font_types = @import("font_types");
const terminal_mod = @import("terminal");
const cell_mod = @import("cell");
const ghostty_vt = @import("ghostty-vt");

const CellInstance = renderer_types.CellInstance;
const RenderState = renderer_types.RenderState;
const CursorState = renderer_types.CursorState;
const Color = renderer_types.Color;
const palette = renderer_types.palette;
const FontGrid = @import("fontgrid").FontGrid;
const FontMetrics = font_types.FontMetrics;
const TermPTerminal = terminal_mod.TermPTerminal;

/// Build a RenderState from the terminal snapshot for the GPU renderer.
///
/// Iterates all visible cells, resolves colors via the palette, looks up glyphs
/// in the font grid, and assembles CellInstance arrays for text and background passes.
/// The caller owns the returned slices (use an arena allocator per frame).
pub fn buildRenderState(
    allocator: std.mem.Allocator,
    terminal: *const TermPTerminal,
    font_grid: *FontGrid,
    viewport_width: u32,
    viewport_height: u32,
) !RenderState {
    const screens = @constCast(terminal).getScreens();
    const screen = screens.active;

    const cols: u16 = @intCast(screen.pages.cols);
    const rows: u16 = @intCast(screen.pages.rows);

    const metrics = font_grid.getMetrics();

    // Pre-allocate with capacity for worst case (every cell has text + bg)
    const total_cells: usize = @as(usize, cols) * @as(usize, rows);
    var text_cells_buf = try allocator.alloc(CellInstance, total_cells);
    errdefer allocator.free(text_cells_buf);
    var text_count: usize = 0;

    var bg_cells_buf = try allocator.alloc(CellInstance, total_cells);
    errdefer allocator.free(bg_cells_buf);
    var bg_count: usize = 0;

    // Iterate visible rows and columns
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const pin = screen.pages.pin(.{ .active = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse continue;

            const rac = pin.rowAndCell();
            const cell = rac.cell;
            const cp = cell.codepoint();

            // Resolve cell colors
            var fg_color = palette.default_fg;
            var bg_color = palette.default_bg;

            if (cell.style_id != 0) {
                const style = pin.style(cell);
                fg_color = resolveColor(style.fg_color, palette.default_fg);
                bg_color = resolveColor(style.bg_color, palette.default_bg);

                // Handle reverse video (SGR 7)
                if (style.flags.inverse) {
                    const tmp = fg_color;
                    fg_color = bg_color;
                    bg_color = tmp;
                }
            }

            // Background cell (only if different from default)
            if (!bg_color.eql(palette.default_bg)) {
                if (bg_count < bg_cells_buf.len) {
                    bg_cells_buf[bg_count] = CellInstance{
                        .grid_col = col,
                        .grid_row = row,
                        .atlas_x = 0,
                        .atlas_y = 0,
                        .atlas_w = 0,
                        .atlas_h = 0,
                        .bearing_x = 0,
                        .bearing_y = 0,
                        .fg_color = fg_color.toU32(),
                        .bg_color = bg_color.toU32(),
                        .flags = 0,
                    };
                    bg_count += 1;
                }
            }

            // Text cell (only if non-empty codepoint)
            if (cp > 0 and cp != ' ') {
                const glyph_result = font_grid.getGlyph(cp) catch continue;
                if (text_count < text_cells_buf.len) {
                    // Convert FreeType bearing to screen-space offset within the cell.
                    // FreeType bearing_y = distance from baseline to glyph top (positive = up).
                    // Screen Y goes down, so: screen_y = ascender - bearing_y
                    // This places the glyph correctly relative to the baseline.
                    const screen_bearing_y: i32 = @as(i32, @intFromFloat(metrics.ascender)) - glyph_result.bearing_y;

                    text_cells_buf[text_count] = CellInstance{
                        .grid_col = col,
                        .grid_row = row,
                        .atlas_x = glyph_result.region.x,
                        .atlas_y = glyph_result.region.y,
                        .atlas_w = glyph_result.region.w,
                        .atlas_h = glyph_result.region.h,
                        .bearing_x = @intCast(std.math.clamp(glyph_result.bearing_x, -32768, 32767)),
                        .bearing_y = @intCast(std.math.clamp(screen_bearing_y, -32768, 32767)),
                        .fg_color = fg_color.toU32(),
                        .bg_color = bg_color.toU32(),
                        .flags = 0,
                    };
                    text_count += 1;
                }
            }
        }
    }

    // Build cursor state
    const cursor_pos = @constCast(terminal).getCursorPos();
    const cursor = CursorState{
        .col = @intCast(cursor_pos.col),
        .row = @intCast(cursor_pos.row),
        .style = .block,
        .visible = true,
        .color = palette.cursor_color.toU32(),
    };

    return RenderState{
        .cells = text_cells_buf[0..text_count],
        .bg_cells = bg_cells_buf[0..bg_count],
        .cursor = cursor,
        .grid_cols = cols,
        .grid_rows = rows,
        .cell_width = metrics.cell_width,
        .cell_height = metrics.cell_height,
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .grid_padding = 4.0,
    };
}

/// Resolve a ghostty-vt color to our Color type.
fn resolveColor(vt_color: anytype, default: Color) Color {
    return switch (vt_color) {
        .none => default,
        .rgb => |rgb| Color{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
        .palette => |idx| palette.resolve256(idx),
    };
}
