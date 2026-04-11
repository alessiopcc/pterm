/// Build a RenderState snapshot from the terminal for GPU rendering.
///
/// Two-phase approach to minimize mutex hold time:
///   Phase 1 (under mutex): copy cell data from terminal into flat arrays
///   Phase 2 (no mutex): shape text via HarfBuzz, resolve glyphs, build CellInstances
///
/// Phase 2 uses dirty-row caching with a persistent allocator (page_allocator).
/// The frame arena resets every frame, so only per-frame output buffers use it.
/// Row cache survives across frames to avoid reshaping unchanged rows.
const std = @import("std");
const renderer_types = @import("renderer_types");
const font_types = @import("font_types");
const terminal_mod = @import("terminal");
const cell_mod = @import("cell");
const ghostty_vt = @import("ghostty-vt");
const shaper_mod = @import("shaper");

const CellInstance = renderer_types.CellInstance;
const CellFlags = renderer_types.CellFlags;
const RenderState = renderer_types.RenderState;
const CursorState = renderer_types.CursorState;
const Color = renderer_types.Color;
const palette = renderer_types.palette;
const FontGrid = @import("fontgrid").FontGrid;
const FontMetrics = font_types.FontMetrics;
const TermPTerminal = terminal_mod.TermPTerminal;
const Shaper = shaper_mod.Shaper;
const ShapedGlyph = shaper_mod.ShapedGlyph;

/// Intermediate cell data copied from terminal under mutex.
const CellSnapshot = struct {
    grapheme: [cell_mod.MAX_GRAPHEME_CODEPOINTS]u21,
    grapheme_len: u8,
    style_id: u16,
    fg: Color,
    bg: Color,
    inverse: bool,
    wide: bool,
    wide_spacer: bool,
};

/// Per-row cache entry for dirty-row tracking.
const CachedRow = struct {
    hash: u64,
    text_cells: []CellInstance,
    bg_cells: []CellInstance,
};

/// Persistent row cache — uses page_allocator, NOT the frame arena.
/// The frame arena resets every frame; cached data must outlive it.
const cache_alloc = std.heap.page_allocator;
var row_cache: ?[]CachedRow = null;
var cached_cols: u16 = 0;
var cached_rows: u16 = 0;
var cached_cursor_row: u16 = std.math.maxInt(u16);

/// Phase 1: Copy cell data from terminal. Call while holding the mutex.
pub fn snapshotCells(
    allocator: std.mem.Allocator,
    terminal: *const TermPTerminal,
) !struct {
    cells: []CellSnapshot,
    cols: u16,
    rows: u16,
    cursor_col: u16,
    cursor_row: u16,
} {
    const screens = @constCast(terminal).getScreens();
    const screen = screens.active;

    const cols: u16 = @intCast(screen.pages.cols);
    const rows: u16 = @intCast(screen.pages.rows);
    const total: usize = @as(usize, cols) * @as(usize, rows);

    const cells = try allocator.alloc(CellSnapshot, total);

    var i: usize = 0;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const empty_grapheme = [_]u21{0} ** cell_mod.MAX_GRAPHEME_CODEPOINTS;

            const pin = screen.pages.pin(.{ .active = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse {
                cells[i] = .{
                    .grapheme = empty_grapheme,
                    .grapheme_len = 0,
                    .style_id = 0,
                    .fg = palette.default_fg,
                    .bg = palette.default_bg,
                    .inverse = false,
                    .wide = false,
                    .wide_spacer = false,
                };
                i += 1;
                continue;
            };

            const rac = pin.rowAndCell();
            const cell = rac.cell;

            var fg = palette.default_fg;
            var bg = palette.default_bg;
            var inverse = false;

            if (cell.style_id != 0) {
                const style = pin.style(cell);
                fg = resolveColor(style.fg_color, palette.default_fg);
                bg = resolveColor(style.bg_color, palette.default_bg);
                inverse = style.flags.inverse;
            }

            // Collect full grapheme cluster
            var grapheme_buf: [cell_mod.MAX_GRAPHEME_CODEPOINTS]u21 = empty_grapheme;
            const extra_cps = if (cell.hasGrapheme()) pin.grapheme(cell) else null;
            const grapheme_len = cell_mod.getGraphemeCodepoints(cell.*, extra_cps, &grapheme_buf);

            cells[i] = .{
                .grapheme = grapheme_buf,
                .grapheme_len = grapheme_len,
                .style_id = @intCast(cell.style_id),
                .fg = fg,
                .bg = bg,
                .inverse = inverse,
                .wide = cell.wide == .wide,
                .wide_spacer = cell.wide == .spacer_tail,
            };
            i += 1;
        }
    }

    const cursor_pos = @constCast(terminal).getCursorPos();

    return .{
        .cells = cells,
        .cols = cols,
        .rows = rows,
        .cursor_col = @intCast(cursor_pos.col),
        .cursor_row = @intCast(cursor_pos.row),
    };
}

/// Phase 2: Build CellInstance arrays from snapshot. Call WITHOUT the mutex.
/// Shapes text through HarfBuzz for ligature support, with dirty-row caching.
pub fn buildFromSnapshot(
    allocator: std.mem.Allocator,
    snap: anytype,
    font_grid: *FontGrid,
    viewport_width: u32,
    viewport_height: u32,
) !RenderState {
    const cols = snap.cols;
    const rows = snap.rows;
    const metrics = font_grid.getMetrics();
    const total: usize = @as(usize, cols) * @as(usize, rows);

    // Invalidate row cache on grid resize.
    const need_new_cache = row_cache == null or cached_cols != cols or cached_rows != rows;
    if (need_new_cache) {
        invalidateRowCache();
        row_cache = try cache_alloc.alloc(CachedRow, rows);
        cached_cols = cols;
        cached_rows = rows;
        cached_cursor_row = std.math.maxInt(u16);
        for (row_cache.?) |*entry| {
            entry.* = .{ .hash = 0, .text_cells = &.{}, .bg_cells = &.{} };
        }
    }

    const cache = row_cache.?;
    const shaper = font_grid.getShaper();

    // Per-frame output buffers (frame arena — reset is fine).
    var text_cells = try allocator.alloc(CellInstance, total * 2);
    var text_count: usize = 0;
    var bg_cells = try allocator.alloc(CellInstance, total);
    var bg_count: usize = 0;

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const row_start = @as(usize, row) * @as(usize, cols);
        const row_cells = snap.cells[row_start .. row_start + cols];
        const row_hash = computeRowHash(row_cells);

        const cursor_on = snap.cursor_row == row;
        const cursor_was = cached_cursor_row == row;
        const can_reuse = (cache[row].hash == row_hash and row_hash != 0) and !cursor_on and !cursor_was;

        if (can_reuse) {
            for (cache[row].text_cells) |ci| {
                text_cells[text_count] = ci;
                text_count += 1;
            }
            for (cache[row].bg_cells) |ci| {
                bg_cells[bg_count] = ci;
                bg_count += 1;
            }
        } else {
            const t_start = text_count;
            const b_start = bg_count;

            shapeRowInto(row_cells, row, cols, snap.cursor_col, cursor_on, font_grid, shaper, &metrics, text_cells, &text_count, bg_cells, &bg_count);

            // Persist this row's output in the cache (persistent allocator).
            const new_text = @constCast(cache_alloc.dupe(CellInstance, text_cells[t_start..text_count]) catch &.{});
            const new_bg = @constCast(cache_alloc.dupe(CellInstance, bg_cells[b_start..bg_count]) catch &.{});
            if (cache[row].text_cells.len > 0) cache_alloc.free(cache[row].text_cells);
            if (cache[row].bg_cells.len > 0) cache_alloc.free(cache[row].bg_cells);
            cache[row] = .{ .hash = row_hash, .text_cells = new_text, .bg_cells = new_bg };
        }
    }

    cached_cursor_row = snap.cursor_row;

    return RenderState{
        .cells = text_cells[0..text_count],
        .bg_cells = bg_cells[0..bg_count],
        .cursor = CursorState{
            .col = snap.cursor_col,
            .row = snap.cursor_row,
            .style = .block,
            .visible = true,
            .color = palette.cursor_color.toU32(),
        },
        .grid_cols = cols,
        .grid_rows = rows,
        .cell_width = metrics.cell_width,
        .cell_height = metrics.cell_height,
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .grid_padding = 4.0,
    };
}

/// Shape a single row into CellInstances, appending to the output buffers.
fn shapeRowInto(
    row_cells: []const CellSnapshot,
    row: u16,
    cols: u16,
    cursor_col: u16,
    cursor_on_row: bool,
    font_grid: *FontGrid,
    shaper: *Shaper,
    metrics: *const FontMetrics,
    text_buf: []CellInstance,
    text_count: *usize,
    bg_buf: []CellInstance,
    bg_count: *usize,
) void {
    var run_start: u16 = 0;
    while (run_start < cols) {
        const cell0 = row_cells[run_start];

        // Wide spacer: emit WIDE_CONTINUATION flag.
        if (cell0.wide_spacer) {
            emitBg(cell0, run_start, row, bg_buf, bg_count);
            text_buf[text_count.*] = CellInstance{
                .grid_col = run_start, .grid_row = row,
                .atlas_x = 0, .atlas_y = 0, .atlas_w = 0, .atlas_h = 0,
                .bearing_x = 0, .bearing_y = 0,
                .fg_color = 0, .bg_color = 0,
                .flags = CellFlags.WIDE_CONTINUATION,
            };
            text_count.* += 1;
            run_start += 1;
            continue;
        }

        // Skip empty cells.
        if (cell0.grapheme_len == 0 or cell0.grapheme[0] == 0) {
            emitBg(cell0, run_start, row, bg_buf, bg_count);
            run_start += 1;
            continue;
        }

        // Find run end: contiguous cells with same style, breaking at wide chars,
        // cursor, spacers, empty cells, and style changes.
        var run_end: u16 = run_start + 1;
        if (!cell0.wide) {
            while (run_end < cols) {
                const nc = row_cells[run_end];
                if (nc.wide_spacer or nc.grapheme_len == 0 or nc.grapheme[0] == 0 or nc.wide) break;
                if (nc.fg.toU32() != cell0.fg.toU32() or
                    nc.bg.toU32() != cell0.bg.toU32() or
                    nc.inverse != cell0.inverse or
                    nc.style_id != cell0.style_id) break;
                if (cursor_on_row and run_end == cursor_col) break;
                run_end += 1;
            }
        }

        // Emit backgrounds for all cells in the run.
        for (run_start..run_end) |ci| {
            emitBg(row_cells[ci], @intCast(ci), row, bg_buf, bg_count);
        }

        // Resolve fg/bg for the run.
        var fg = cell0.fg;
        var bg = cell0.bg;
        if (cell0.inverse) {
            const tmp = fg;
            fg = bg;
            bg = tmp;
        }

        // Collect ALL grapheme codepoints for the run (not just base).
        var run_cps: [1024]u21 = undefined;
        var cp_len: usize = 0;
        var cell_cp_offsets: [512]u16 = undefined;
        for (run_start..run_end) |ci| {
            const c = row_cells[ci];
            cell_cp_offsets[ci - run_start] = @intCast(cp_len);
            if (c.grapheme_len > 0 and !c.wide_spacer) {
                for (0..c.grapheme_len) |gi| {
                    if (cp_len < run_cps.len) {
                        run_cps[cp_len] = c.grapheme[gi];
                        cp_len += 1;
                    }
                }
            }
        }

        if (cp_len == 0) {
            run_start = run_end;
            continue;
        }

        // Detect emoji in the run.
        const is_emoji = cell_mod.isEmojiCodepoint(cell0.grapheme[0]);
        const emoji_idx = font_grid.getEmojiFontIndex();

        // Try HarfBuzz shaping.
        const shaped = shaper.shape(run_cps[0..cp_len]) catch null;
        if (shaped) |glyphs| {
            defer shaper.allocator.free(glyphs);

            for (glyphs) |glyph| {
                // Reverse-lookup: find which cell owns this cluster.
                var glyph_col: u16 = run_start;
                const run_len = run_end - run_start;
                for (0..run_len) |ci| {
                    if (cell_cp_offsets[ci] <= glyph.cluster) {
                        glyph_col = run_start + @as(u16, @intCast(ci));
                    }
                }

                var flags: u16 = 0;
                if (cell0.wide) flags |= CellFlags.WIDE_CHAR;
                const use_color = is_emoji and emoji_idx != null;
                if (use_color) flags |= CellFlags.COLOR_GLYPH;
                if (glyph.num_chars > 1) flags |= CellFlags.LIGATURE_HEAD;

                const font_idx: u8 = if (use_color) emoji_idx.? else 0;
                const glyph_result = font_grid.getGlyphByID(font_idx, glyph.glyph_id, use_color) catch {
                    // Fallback: try codepoint-based lookup.
                    const cp = if (glyph.cluster < cp_len) run_cps[glyph.cluster] else cell0.grapheme[0];
                    const fallback = font_grid.getGlyph(cp) catch continue;
                    const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - fallback.bearing_y;
                    text_buf[text_count.*] = CellInstance{
                        .grid_col = glyph_col, .grid_row = row,
                        .atlas_x = fallback.region.x, .atlas_y = fallback.region.y,
                        .atlas_w = fallback.region.w, .atlas_h = fallback.region.h,
                        .bearing_x = @intCast(std.math.clamp(fallback.bearing_x, -32768, 32767)),
                        .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                        .fg_color = fg.toU32(), .bg_color = bg.toU32(),
                        .flags = flags,
                    };
                    text_count.* += 1;
                    continue;
                };

                const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - glyph_result.bearing_y;
                text_buf[text_count.*] = CellInstance{
                    .grid_col = glyph_col, .grid_row = row,
                    .atlas_x = glyph_result.region.x, .atlas_y = glyph_result.region.y,
                    .atlas_w = glyph_result.region.w, .atlas_h = glyph_result.region.h,
                    .bearing_x = @intCast(std.math.clamp(glyph_result.bearing_x, -32768, 32767)),
                    .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                    .fg_color = fg.toU32(), .bg_color = bg.toU32(),
                    .flags = flags,
                };
                text_count.* += 1;

                // Emit LIGATURE_CONTINUATION for columns covered by multi-char glyph.
                if (glyph.num_chars > 1) {
                    var cont: u16 = 1;
                    while (cont < glyph.num_chars and glyph_col + cont < run_end) : (cont += 1) {
                        text_buf[text_count.*] = CellInstance{
                            .grid_col = glyph_col + cont, .grid_row = row,
                            .atlas_x = 0, .atlas_y = 0, .atlas_w = 0, .atlas_h = 0,
                            .bearing_x = 0, .bearing_y = 0,
                            .fg_color = 0, .bg_color = 0,
                            .flags = CellFlags.LIGATURE_CONTINUATION,
                        };
                        text_count.* += 1;
                    }
                }
            }
        } else {
            // Shaping failed — fallback to per-codepoint rendering.
            for (run_start..run_end) |ci| {
                const c = row_cells[ci];
                if (c.grapheme_len > 0 and c.grapheme[0] > 0 and c.grapheme[0] != ' ' and !c.wide_spacer) {
                    var flags: u16 = 0;
                    if (c.wide) flags |= CellFlags.WIDE_CHAR;
                    if (cell_mod.isEmojiCodepoint(c.grapheme[0])) flags |= CellFlags.COLOR_GLYPH;

                    const gr = font_grid.getGlyph(c.grapheme[0]) catch continue;
                    const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - gr.bearing_y;
                    text_buf[text_count.*] = CellInstance{
                        .grid_col = @intCast(ci), .grid_row = row,
                        .atlas_x = gr.region.x, .atlas_y = gr.region.y,
                        .atlas_w = gr.region.w, .atlas_h = gr.region.h,
                        .bearing_x = @intCast(std.math.clamp(gr.bearing_x, -32768, 32767)),
                        .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                        .fg_color = fg.toU32(), .bg_color = bg.toU32(),
                        .flags = flags,
                    };
                    text_count.* += 1;
                }
            }
        }

        run_start = run_end;
    }
}

/// Emit a background CellInstance for non-default backgrounds.
fn emitBg(cell: CellSnapshot, col: u16, row: u16, buf: []CellInstance, count: *usize) void {
    var bg = cell.bg;
    if (cell.inverse) {
        bg = cell.fg;
    }
    if (!bg.eql(palette.default_bg)) {
        var fg = cell.fg;
        if (cell.inverse) fg = cell.bg;
        buf[count.*] = CellInstance{
            .grid_col = col,
            .grid_row = row,
            .atlas_x = 0,
            .atlas_y = 0,
            .atlas_w = 0,
            .atlas_h = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .fg_color = fg.toU32(),
            .bg_color = bg.toU32(),
            .flags = 0,
        };
        count.* += 1;
    }
}

/// Compute a hash of a row's cell content for dirty detection.
fn computeRowHash(row_cells: []const CellSnapshot) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (row_cells) |cell| {
        for (0..cell.grapheme_len) |gi| {
            hasher.update(std.mem.asBytes(&cell.grapheme[gi]));
        }
        hasher.update(std.mem.asBytes(&cell.grapheme_len));
        hasher.update(std.mem.asBytes(&cell.style_id));
        hasher.update(std.mem.asBytes(&cell.fg));
        hasher.update(std.mem.asBytes(&cell.bg));
        const wb: u8 = @as(u8, @intFromBool(cell.wide)) | (@as(u8, @intFromBool(cell.wide_spacer)) << 1);
        hasher.update(&.{wb});
    }
    return hasher.final();
}

/// Invalidate and free the entire row cache.
fn invalidateRowCache() void {
    if (row_cache) |cache| {
        for (cache) |*entry| {
            if (entry.text_cells.len > 0) cache_alloc.free(entry.text_cells);
            if (entry.bg_cells.len > 0) cache_alloc.free(entry.bg_cells);
        }
        cache_alloc.free(cache);
        row_cache = null;
    }
}

/// Legacy single-call API (kept for compatibility).
pub fn buildRenderState(
    allocator: std.mem.Allocator,
    terminal: *const TermPTerminal,
    font_grid: *FontGrid,
    viewport_width: u32,
    viewport_height: u32,
) !RenderState {
    const snap = try snapshotCells(allocator, terminal);
    return buildFromSnapshot(allocator, snap, font_grid, viewport_width, viewport_height);
}

fn resolveColor(vt_color: anytype, default: Color) Color {
    return switch (vt_color) {
        .none => default,
        .rgb => |rgb| Color{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
        .palette => |idx| palette.resolve256(idx),
    };
}
