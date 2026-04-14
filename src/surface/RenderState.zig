/// Build a RenderState snapshot from the terminal for GPU rendering.
///
/// Two-phase approach to minimize mutex hold time:
///   Pass 1 (under mutex): copy cell data from terminal into flat arrays
///   Pass 2 (no mutex): shape text via HarfBuzz, resolve glyphs, build CellInstances
///
/// Pass 2 uses dirty-row caching with a persistent allocator (page_allocator).
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
const theme_mod = @import("theme");
const RendererPalette = theme_mod.RendererPalette;
const FontGrid = @import("fontgrid").FontGrid;
const FontMetrics = font_types.FontMetrics;
const PTermTerminal = terminal_mod.PTermTerminal;
const Shaper = shaper_mod.Shaper;
const ShapedGlyph = shaper_mod.ShapedGlyph;
const dwrite_emoji = @import("dwrite_emoji");

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
    block_cells: []CellInstance,
};

/// Persistent allocator for row cache data (NOT the frame arena).
const cache_alloc = std.heap.page_allocator;

/// Per-pane row cache. Each pane keeps its own cache so switching between
/// panes during rendering doesn't thrash a shared global cache.
pub const RowCache = struct {
    rows: ?[]CachedRow = null,
    cols: u16 = 0,
    row_count: u16 = 0,
    cursor_row: u16 = std.math.maxInt(u16),

    pub fn invalidate(self: *RowCache) void {
        if (self.rows) |cache| {
            for (cache) |*entry| {
                if (entry.text_cells.len > 0) cache_alloc.free(entry.text_cells);
                if (entry.bg_cells.len > 0) cache_alloc.free(entry.bg_cells);
                if (entry.block_cells.len > 0) cache_alloc.free(entry.block_cells);
            }
            cache_alloc.free(cache);
            self.rows = null;
        }
    }
};

/// Pass 1: Copy cell data from terminal. Call while holding the mutex.
/// Accepts an optional RendererPalette for config-driven default colors.
/// If pal is null, falls back to the compile-time palette.
pub fn snapshotCells(
    allocator: std.mem.Allocator,
    terminal: *const PTermTerminal,
    pal: ?*const RendererPalette,
    scroll_offset: u32,
) !struct {
    cells: []CellSnapshot,
    cols: u16,
    rows: u16,
    cursor_col: u16,
    cursor_row: u16,
    cursor_visible: bool,
    in_scrollback: bool,
} {
    const screens = @constCast(terminal).getScreens();
    const screen = screens.active;

    const cols: u16 = @intCast(screen.pages.cols);
    const rows: u16 = @intCast(screen.pages.rows);
    const total: usize = @as(usize, cols) * @as(usize, rows);

    // Compute screen-coordinate base row for scrollback viewport
    const total_rows = screen.pages.total_rows;
    const active_rows = screen.pages.rows;
    const history_rows: u32 = if (total_rows > active_rows) @intCast(total_rows - active_rows) else 0;
    const clamped_offset = @min(scroll_offset, history_rows);
    // Base row in screen coordinates: history_rows - offset is where the viewport starts
    const viewport_base: u32 = history_rows - clamped_offset;

    // Use config-driven palette if provided, else compile-time defaults
    const default_fg = if (pal) |p| p.default_fg else palette.default_fg;
    const default_bg = if (pal) |p| p.default_bg else palette.default_bg;

    const cells = try allocator.alloc(CellSnapshot, total);

    var i: usize = 0;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const empty_grapheme = [_]u21{0} ** cell_mod.MAX_GRAPHEME_CODEPOINTS;

            // When scrolled back, use screen coordinates; otherwise use active
            const pin = if (clamped_offset > 0)
                screen.pages.pin(.{ .screen = .{
                    .x = @intCast(col),
                    .y = @intCast(viewport_base + row),
                } })
            else
                screen.pages.pin(.{ .active = .{
                    .x = @intCast(col),
                    .y = @intCast(row),
                } });

            const pin_val = pin orelse {
                cells[i] = .{
                    .grapheme = empty_grapheme,
                    .grapheme_len = 0,
                    .style_id = 0,
                    .fg = default_fg,
                    .bg = default_bg,
                    .inverse = false,
                    .wide = false,
                    .wide_spacer = false,
                };
                i += 1;
                continue;
            };

            const rac = pin_val.rowAndCell();
            const cell = rac.cell;

            var fg = default_fg;
            var bg = default_bg;
            var inverse = false;

            if (cell.style_id != 0) {
                const style = pin_val.style(cell);
                fg = resolveColor(style.fg_color, default_fg, pal);
                bg = resolveColor(style.bg_color, default_bg, pal);
                inverse = style.flags.inverse;
            }

            // Get base codepoint directly from ghostty-vt cell.
            const cp = cell.codepoint();
            var grapheme_buf: [cell_mod.MAX_GRAPHEME_CODEPOINTS]u21 = empty_grapheme;
            var grapheme_len: u8 = 0;
            if (cp > 0) {
                grapheme_buf[0] = cp;
                grapheme_len = 1;
                // Extract extra grapheme codepoints from ghostty-vt
                if (cell.hasGrapheme()) {
                    if (pin_val.grapheme(cell)) |extra_cps| {
                        for (extra_cps) |ecp| {
                            if (grapheme_len >= cell_mod.MAX_GRAPHEME_CODEPOINTS) break;
                            grapheme_buf[grapheme_len] = ecp;
                            grapheme_len += 1;
                        }
                    }
                }
            }

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
    const cursor_vis = @constCast(terminal).isCursorVisible();

    return .{
        .cells = cells,
        .cols = cols,
        .rows = rows,
        .cursor_col = @intCast(cursor_pos.col),
        .cursor_row = @intCast(cursor_pos.row),
        .cursor_visible = cursor_vis,
        .in_scrollback = clamped_offset > 0,
    };
}

/// Pass 2: Build CellInstance arrays from snapshot. Call WITHOUT the mutex.
/// Shapes text through HarfBuzz for ligature support, with dirty-row caching.
/// Accepts an optional RendererPalette for config-driven cursor and background colors.
pub fn buildFromSnapshot(
    allocator: std.mem.Allocator,
    snap: anytype,
    font_grid: *FontGrid,
    viewport_width: u32,
    viewport_height: u32,
    pal: ?*const RendererPalette,
    pane_cache: ?*RowCache,
) !RenderState {
    const cols = snap.cols;
    const rows = snap.rows;
    const metrics = font_grid.getMetrics();
    const total: usize = @as(usize, cols) * @as(usize, rows);

    // Per-pane row cache: invalidate on grid resize.
    if (pane_cache) |rc| {
        const need_new = rc.rows == null or rc.cols != cols or rc.row_count != rows;
        if (need_new) {
            rc.invalidate();
            rc.rows = try cache_alloc.alloc(CachedRow, rows);
            rc.cols = cols;
            rc.row_count = rows;
            rc.cursor_row = std.math.maxInt(u16);
            for (rc.rows.?) |*entry| {
                entry.* = .{ .hash = 0, .text_cells = &.{}, .bg_cells = &.{}, .block_cells = &.{} };
            }
        }
    }

    const cache = if (pane_cache) |rc| rc.rows else null;
    const prev_cursor = if (pane_cache) |rc| rc.cursor_row else std.math.maxInt(u16);
    const shaper = font_grid.getShaper();

    // Per-frame output buffers (frame arena — reset is fine).
    var text_cells = try allocator.alloc(CellInstance, total * 2);
    var text_count: usize = 0;
    var bg_cells = try allocator.alloc(CellInstance, total);
    var bg_count: usize = 0;
    var block_cells = try allocator.alloc(CellInstance, total);
    var block_count: usize = 0;

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const row_start = @as(usize, row) * @as(usize, cols);
        const row_cells = snap.cells[row_start .. row_start + cols];
        const row_hash = computeRowHash(row_cells);

        const cursor_on = snap.cursor_row == row;
        const cursor_was = prev_cursor == row;
        const can_reuse = cache != null and (cache.?[row].hash == row_hash and row_hash != 0) and !cursor_on and !cursor_was;

        if (can_reuse) {
            for (cache.?[row].text_cells) |ci| {
                text_cells[text_count] = ci;
                text_count += 1;
            }
            for (cache.?[row].bg_cells) |ci| {
                bg_cells[bg_count] = ci;
                bg_count += 1;
            }
            for (cache.?[row].block_cells) |ci| {
                block_cells[block_count] = ci;
                block_count += 1;
            }
        } else {
            const t_start = text_count;
            const b_start = bg_count;
            const blk_start = block_count;

            shapeRowInto(row_cells, row, cols, snap.cursor_col, cursor_on, font_grid, shaper, &metrics, text_cells, &text_count, bg_cells, &bg_count, block_cells, &block_count);

            // Persist this row's output in the per-pane cache (persistent allocator).
            if (cache) |c| {
                const new_text = @constCast(cache_alloc.dupe(CellInstance, text_cells[t_start..text_count]) catch &.{});
                const new_bg = @constCast(cache_alloc.dupe(CellInstance, bg_cells[b_start..bg_count]) catch &.{});
                const new_block = @constCast(cache_alloc.dupe(CellInstance, block_cells[blk_start..block_count]) catch &.{});
                if (c[row].text_cells.len > 0) cache_alloc.free(c[row].text_cells);
                if (c[row].bg_cells.len > 0) cache_alloc.free(c[row].bg_cells);
                if (c[row].block_cells.len > 0) cache_alloc.free(c[row].block_cells);
                c[row] = .{ .hash = row_hash, .text_cells = new_text, .bg_cells = new_bg, .block_cells = new_block };
            }
        }
    }

    if (pane_cache) |rc| rc.cursor_row = snap.cursor_row;

    return RenderState{
        .cells = text_cells[0..text_count],
        .bg_cells = bg_cells[0..bg_count],
        .block_cells = block_cells[0..block_count],
        .cursor = CursorState{
            .col = snap.cursor_col,
            .row = snap.cursor_row,
            .style = .block,
            .visible = true,
            .color = if (pal) |p| p.cursor_color.toU32() else palette.cursor_color.toU32(),
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
    block_buf: []CellInstance,
    block_count: *usize,
) void {
    var run_start: u16 = 0;
    while (run_start < cols) {
        const cell0 = row_cells[run_start];

        // Wide spacer: emit WIDE_CONTINUATION flag.
        if (cell0.wide_spacer) {
            emitBg(cell0, run_start, row, bg_buf, bg_count);
            text_buf[text_count.*] = CellInstance{
                .grid_col = run_start,
                .grid_row = row,
                .atlas_x = 0,
                .atlas_y = 0,
                .atlas_w = 0,
                .atlas_h = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .fg_color = 0,
                .bg_color = 0,
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
        // cursor, spacers, empty cells, style changes, and block/text boundaries.
        const cell0_is_block = preferPrimaryFont(cell0.grapheme[0]) and cell0.grapheme[0] < 0xE0A0;
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
                // Break at block/text boundaries so block routing doesn't
                // swallow regular text that shares the same style.
                const nc_is_block = preferPrimaryFont(nc.grapheme[0]) and nc.grapheme[0] < 0xE0A0;
                if (nc_is_block != cell0_is_block) break;
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

        // Detect if this run contains emoji or wide (CJK) chars.
        // Emoji/CJK can't use HarfBuzz glyph IDs from the primary font — they need
        // codepoint-based fallback through the full font chain.
        const first_cp = cell0.grapheme[0];
        const is_emoji = cell_mod.isEmojiCodepoint(first_cp);
        const is_wide_run = cell0.wide;

        // Route block-drawing codepoints to block pass (D-04).
        // Box Drawing, Block Elements, and Braille are diverted from the
        // text pass for GPU procedural rendering. Powerline symbols
        // (U+E0A0-E0D4) stay in the text pass — they need full-cell
        // fg+bg rendering that fonts handle better.
        if (preferPrimaryFont(first_cp) and first_cp < 0xE0A0 and !is_emoji and !is_wide_run) {
            // Emit backgrounds for block cells (same as text and emoji paths).
            for (run_start..run_end) |ci| {
                emitBg(row_cells[ci], @intCast(ci), row, bg_buf, bg_count);
            }
            for (run_start..run_end) |ci| {
                const c = row_cells[ci];
                if (c.grapheme_len == 0 or c.grapheme[0] == 0) continue;
                // Block pass only supports BMP codepoints (atlas_x is u16).
                if (c.grapheme[0] > 0xFFFF) continue;
                const cp: u16 = @intCast(c.grapheme[0]);
                block_buf[block_count.*] = CellInstance{
                    .grid_col = @intCast(ci),
                    .grid_row = row,
                    .atlas_x = cp, // codepoint for shader
                    .atlas_y = 0,
                    .atlas_w = 0,
                    .atlas_h = 0,
                    .bearing_x = 0,
                    .bearing_y = 0,
                    .fg_color = fg.toU32(),
                    .bg_color = bg.toU32(),
                    .flags = 0,
                };
                block_count.* += 1;
            }
            run_start = run_end;
            continue;
        }

        if (is_emoji or is_wide_run) {
            // Renderer-level emoji sequence detection.
            // Without grapheme cluster mode (2027), multi-codepoint emoji are
            // spread across separate cells. We scan ahead from the current
            // position to find adjacent cells that form a logical emoji sequence
            // (flags, ZWJ families, skin-tone modifiers) and combine their
            // codepoints for HarfBuzz shaping.
            var emoji_shaped = false;
            if (is_emoji) {
                // Scan ahead past run_end to find the full emoji sequence.
                // This looks beyond the current style-based run because emoji
                // sequences span multiple cells that may differ in style_id.
                var seq_cps: [32]u21 = undefined;
                var seq_len: usize = 0;
                var seq_end: u16 = run_start; // column past the last consumed cell
                var scan: u16 = run_start;

                while (scan < cols and seq_len < seq_cps.len) {
                    const sc = row_cells[scan];
                    if (sc.wide_spacer) {
                        scan += 1;
                        continue;
                    }
                    if (sc.grapheme_len == 0 or sc.grapheme[0] == 0) break;

                    const scp = sc.grapheme[0];

                    if (seq_len == 0) {
                        // First cell — always include.
                        for (0..sc.grapheme_len) |gi| {
                            if (seq_len < seq_cps.len) {
                                seq_cps[seq_len] = sc.grapheme[gi];
                                seq_len += 1;
                            }
                        }
                        seq_end = scan + 1;
                        // Skip spacer_tail if wide.
                        if (sc.wide and scan + 1 < cols and row_cells[scan + 1].wide_spacer) {
                            seq_end = scan + 2;
                        }
                        scan = seq_end;
                        continue;
                    }

                    // Check if this cell continues the emoji sequence:
                    // - Regional indicator following another regional indicator (flags)
                    // - Emoji following a ZWJ (ZWJ sequence continuation)
                    // - Fitzpatrick modifier (U+1F3FB-U+1F3FF) following emoji (skin-tone)
                    // - Variation selector (already appended as grapheme, but check anyway)
                    const prev_ends_with_zwj = seq_len > 0 and seq_cps[seq_len - 1] == 0x200D;
                    const is_regional = scp >= 0x1F1E0 and scp <= 0x1F1FF;
                    const prev_is_regional = seq_cps[0] >= 0x1F1E0 and seq_cps[0] <= 0x1F1FF;
                    const is_skin_tone = scp >= 0x1F3FB and scp <= 0x1F3FF;

                    const continues = prev_ends_with_zwj or
                        (is_regional and prev_is_regional and seq_len <= 2) or
                        is_skin_tone;

                    if (!continues) break;

                    for (0..sc.grapheme_len) |gi| {
                        if (seq_len < seq_cps.len) {
                            seq_cps[seq_len] = sc.grapheme[gi];
                            seq_len += 1;
                        }
                    }
                    seq_end = scan + 1;
                    if (sc.wide and scan + 1 < cols and row_cells[scan + 1].wide_spacer) {
                        seq_end = scan + 2;
                    }
                    scan = seq_end;
                }

                // If we found a multi-codepoint sequence, shape it.
                if (seq_len > 1) {
                    const emoji_shaper_opt = font_grid.getEmojiShaper();
                    const emoji_idx_opt = font_grid.getEmojiFontIndex();
                    if (emoji_shaper_opt) |emoji_shaper| {
                        if (emoji_idx_opt) |emoji_idx| {
                            const shaped = emoji_shaper.shapeEmoji(seq_cps[0..seq_len]) catch null;
                            if (shaped) |glyphs| {
                                defer emoji_shaper.allocator.free(glyphs);

                                if (glyphs.len == 1 and glyphs[0].glyph_id != 0) {
                                    emoji_shaped = true;

                                    // Emit backgrounds for all cells in the emoji sequence.
                                    var bg_col: u16 = run_start;
                                    while (bg_col < seq_end) : (bg_col += 1) {
                                        if (bg_col < cols) {
                                            emitBg(row_cells[bg_col], bg_col, row, bg_buf, bg_count);
                                        }
                                    }

                                    // Render composed glyph at run_start position.
                                    const glyph = glyphs[0];

                                    const glyph_result = font_grid.getGlyphByID(emoji_idx, glyph.glyph_id, true) catch blk: {
                                        const fallback_cp = first_cp;
                                        break :blk font_grid.getGlyph(fallback_cp) catch {
                                            // Complete fallback failure — skip to per-codepoint path.
                                            run_start = seq_end;
                                            continue;
                                        };
                                    };

                                    const glyph_flags: u16 = CellFlags.WIDE_CHAR |
                                        if (glyph_result.is_color) CellFlags.COLOR_GLYPH else @as(u16, 0);

                                    const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - glyph_result.bearing_y;
                                    text_buf[text_count.*] = CellInstance{
                                        .grid_col = run_start,
                                        .grid_row = row,
                                        .atlas_x = glyph_result.region.x,
                                        .atlas_y = glyph_result.region.y,
                                        .atlas_w = glyph_result.region.w,
                                        .atlas_h = glyph_result.region.h,
                                        .bearing_x = @intCast(std.math.clamp(glyph_result.bearing_x, -32768, 32767)),
                                        .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                                        .fg_color = fg.toU32(),
                                        .bg_color = bg.toU32(),
                                        .flags = glyph_flags,
                                    };
                                    text_count.* += 1;

                                    // Emit WIDE_CONTINUATION for remaining columns.
                                    var cont_col: u16 = run_start + 1;
                                    while (cont_col < seq_end) : (cont_col += 1) {
                                        text_buf[text_count.*] = CellInstance{
                                            .grid_col = cont_col,
                                            .grid_row = row,
                                            .atlas_x = 0,
                                            .atlas_y = 0,
                                            .atlas_w = 0,
                                            .atlas_h = 0,
                                            .bearing_x = 0,
                                            .bearing_y = 0,
                                            .fg_color = 0,
                                            .bg_color = 0,
                                            .flags = CellFlags.WIDE_CONTINUATION,
                                        };
                                        text_count.* += 1;
                                    }

                                    // Skip past the entire emoji sequence.
                                    run_start = seq_end;
                                    continue;
                                }
                            }
                        }
                    }
                }

                // DirectWrite fallback (Windows): when HarfBuzz can't compose,
                // use DirectWrite which has built-in emoji composition.
                if (!emoji_shaped and seq_len > 1) {
                    if (dwrite_emoji.render(font_grid.allocator, seq_cps[0..seq_len], metrics.cell_height)) |bitmap| {
                        defer font_grid.allocator.free(bitmap.data);

                        if (bitmap.width > 0 and bitmap.height > 0) {
                            // Insert into color atlas with a synthetic key.
                            const atlas_key = font_types.GlyphKey{
                                .font_index = 255, // synthetic font index for DWrite emoji
                                .glyph_id = seq_cps[0], // use first codepoint as key discriminator
                                .size_px = @intFromFloat(@round(metrics.cell_height)),
                                .is_glyph_index = true,
                            };
                            const cached = font_grid.getAtlasMut().insertColor(atlas_key, bitmap) catch null;
                            if (cached) |entry| {
                                emoji_shaped = true;

                                // Emit backgrounds for all cells in the emoji sequence.
                                var bg_col: u16 = run_start;
                                while (bg_col < seq_end) : (bg_col += 1) {
                                    if (bg_col < cols) {
                                        emitBg(row_cells[bg_col], bg_col, row, bg_buf, bg_count);
                                    }
                                }

                                const glyph_flags: u16 = CellFlags.COLOR_GLYPH | CellFlags.WIDE_CHAR;
                                const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - entry.bearing_y;
                                text_buf[text_count.*] = CellInstance{
                                    .grid_col = run_start,
                                    .grid_row = row,
                                    .atlas_x = entry.region.x,
                                    .atlas_y = entry.region.y,
                                    .atlas_w = entry.region.w,
                                    .atlas_h = entry.region.h,
                                    .bearing_x = @intCast(std.math.clamp(entry.bearing_x, -32768, 32767)),
                                    .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                                    .fg_color = fg.toU32(),
                                    .bg_color = bg.toU32(),
                                    .flags = glyph_flags,
                                };
                                text_count.* += 1;

                                // Emit WIDE_CONTINUATION for remaining columns.
                                var cont_col: u16 = run_start + 1;
                                while (cont_col < seq_end) : (cont_col += 1) {
                                    text_buf[text_count.*] = CellInstance{
                                        .grid_col = cont_col,
                                        .grid_row = row,
                                        .atlas_x = 0,
                                        .atlas_y = 0,
                                        .atlas_w = 0,
                                        .atlas_h = 0,
                                        .bearing_x = 0,
                                        .bearing_y = 0,
                                        .fg_color = 0,
                                        .bg_color = 0,
                                        .flags = CellFlags.WIDE_CONTINUATION,
                                    };
                                    text_count.* += 1;
                                }

                                run_start = seq_end;
                                continue;
                            }
                        }
                    }
                }
            }

            // Single-codepoint emoji/CJK fallback: per-codepoint rendering through font chain.
            if (!emoji_shaped) {
                for (run_start..run_end) |ci| {
                    const c = row_cells[ci];
                    if (c.grapheme_len == 0 or c.grapheme[0] == 0 or c.wide_spacer) continue;
                    const cp = c.grapheme[0];
                    if (cp == ' ') continue;

                    var per_cp_flags: u16 = 0;
                    if (c.wide) per_cp_flags |= CellFlags.WIDE_CHAR;
                    if (cell_mod.isEmojiCodepoint(cp)) per_cp_flags |= CellFlags.COLOR_GLYPH;

                    // For non-ASCII, try fallback fonts first (symbol fonts have
                    // better coverage for Dingbats, arrows, etc. than coding fonts).
                    // Exception: box-drawing and block elements must use the primary
                    // font for correct cell grid alignment.
                    const gr = if (cp > 0x7F and !preferPrimaryFont(cp))
                        (font_grid.getGlyphFromFallbacks(cp) catch
                            (font_grid.getGlyph(cp) catch continue))
                    else
                        font_grid.getGlyph(cp) catch continue;
                    const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - gr.bearing_y;
                    text_buf[text_count.*] = CellInstance{
                        .grid_col = @intCast(ci),
                        .grid_row = row,
                        .atlas_x = gr.region.x,
                        .atlas_y = gr.region.y,
                        .atlas_w = gr.region.w,
                        .atlas_h = gr.region.h,
                        .bearing_x = @intCast(std.math.clamp(gr.bearing_x, -32768, 32767)),
                        .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                        .fg_color = fg.toU32(),
                        .bg_color = bg.toU32(),
                        .flags = per_cp_flags,
                    };
                    text_count.* += 1;
                }
            }
        } else {
            // Normal text: HarfBuzz shaping for ligatures.
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
                    if (glyph.num_chars > 1) flags |= CellFlags.LIGATURE_HEAD;

                    // For non-ASCII codepoints, try the full fallback chain first.
                    // Symbol/fallback fonts often have better glyphs for special
                    // characters (Dingbats, Nerd Font icons, etc.) than the primary
                    // coding font whose cmap entry may be a placeholder.
                    const cp = if (glyph.cluster < cp_len) run_cps[glyph.cluster] else first_cp;
                    const glyph_result = if (cp > 0x7F and !preferPrimaryFont(cp))
                        (font_grid.getGlyphFromFallbacks(cp) catch
                            (font_grid.getGlyphByID(0, glyph.glyph_id, false) catch continue))
                    else
                        font_grid.getGlyphByID(0, glyph.glyph_id, false) catch {
                            const fallback = font_grid.getGlyph(cp) catch continue;
                            const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - fallback.bearing_y;
                            text_buf[text_count.*] = CellInstance{
                                .grid_col = glyph_col,
                                .grid_row = row,
                                .atlas_x = fallback.region.x,
                                .atlas_y = fallback.region.y,
                                .atlas_w = fallback.region.w,
                                .atlas_h = fallback.region.h,
                                .bearing_x = @intCast(std.math.clamp(fallback.bearing_x, -32768, 32767)),
                                .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                                .fg_color = fg.toU32(),
                                .bg_color = bg.toU32(),
                                .flags = flags,
                            };
                            text_count.* += 1;
                            continue;
                        };

                    const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - glyph_result.bearing_y;
                    text_buf[text_count.*] = CellInstance{
                        .grid_col = glyph_col,
                        .grid_row = row,
                        .atlas_x = glyph_result.region.x,
                        .atlas_y = glyph_result.region.y,
                        .atlas_w = glyph_result.region.w,
                        .atlas_h = glyph_result.region.h,
                        .bearing_x = @intCast(std.math.clamp(glyph_result.bearing_x, -32768, 32767)),
                        .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                        .fg_color = fg.toU32(),
                        .bg_color = bg.toU32(),
                        .flags = flags,
                    };
                    text_count.* += 1;

                    // Emit LIGATURE_CONTINUATION for columns covered by multi-char glyph.
                    if (glyph.num_chars > 1) {
                        var cont: u16 = 1;
                        while (cont < glyph.num_chars and glyph_col + cont < run_end) : (cont += 1) {
                            text_buf[text_count.*] = CellInstance{
                                .grid_col = glyph_col + cont,
                                .grid_row = row,
                                .atlas_x = 0,
                                .atlas_y = 0,
                                .atlas_w = 0,
                                .atlas_h = 0,
                                .bearing_x = 0,
                                .bearing_y = 0,
                                .fg_color = 0,
                                .bg_color = 0,
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
                        const gr = font_grid.getGlyph(c.grapheme[0]) catch continue;
                        const sby: i32 = @as(i32, @intFromFloat(metrics.ascender)) - gr.bearing_y;
                        text_buf[text_count.*] = CellInstance{
                            .grid_col = @intCast(ci),
                            .grid_row = row,
                            .atlas_x = gr.region.x,
                            .atlas_y = gr.region.y,
                            .atlas_w = gr.region.w,
                            .atlas_h = gr.region.h,
                            .bearing_x = @intCast(std.math.clamp(gr.bearing_x, -32768, 32767)),
                            .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
                            .fg_color = fg.toU32(),
                            .bg_color = bg.toU32(),
                            .flags = 0,
                        };
                        text_count.* += 1;
                    }
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
    // Compare against the default bg that was used during snapshot
    // (already resolved from config palette in snapshotCells)
    if (!bg.eql(palette.default_bg) and bg.a > 0) {
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

/// Highlight search matches in cell instances by overriding background colors.
/// Iterates bg_cells and overrides backgrounds for cells within match ranges.
/// Keeps search highlighting decoupled from the snapshot pipeline.
pub fn highlightSearchMatches(
    rs: *RenderState,
    matches: []const SearchMatch,
    current_match_idx: u32,
    match_color: Color,
    current_color: Color,
) void {
    for (matches, 0..) |m, mi| {
        const is_current = @as(u32, @intCast(mi)) == current_match_idx;
        const highlight = if (is_current) current_color else match_color;

        // Override bg_cells within the match range
        for (rs.bg_cells) |*cell| {
            if (cell.grid_row == @as(u16, @intCast(m.line_index))) {
                if (cell.grid_col >= m.col_start and cell.grid_col < m.col_end) {
                    cell.bg_color = highlight.toU32();
                }
            }
        }
    }
}

/// Search match position (imported type for highlightSearchMatches).
pub const SearchMatch = struct {
    line_index: u32,
    col_start: u16,
    col_end: u16,
    in_scrollback: bool,
};

/// Legacy single-call API (kept for compatibility).
/// Accepts optional RendererPalette for config-driven colors.
pub fn buildRenderState(
    allocator: std.mem.Allocator,
    terminal: *const PTermTerminal,
    font_grid: *FontGrid,
    viewport_width: u32,
    viewport_height: u32,
    pal: ?*const RendererPalette,
) !RenderState {
    const snap = try snapshotCells(allocator, terminal, pal, 0);
    return buildFromSnapshot(allocator, snap, font_grid, viewport_width, viewport_height, pal, null);
}

fn resolveColor(vt_color: anytype, default: Color, pal: ?*const RendererPalette) Color {
    return switch (vt_color) {
        .none => default,
        .rgb => |rgb| Color{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
        .palette => |idx| if (pal) |p| p.resolve256(idx) else palette.resolve256(idx),
    };
}

/// Returns true for codepoints that should use the primary (monospace) font
/// rather than fallback symbol fonts. Box-drawing and block elements must
/// come from the primary font for correct cell grid alignment.
fn preferPrimaryFont(cp: u21) bool {
    // Box Drawing (U+2500-U+257F)
    if (cp >= 0x2500 and cp <= 0x257F) return true;
    // Block Elements (U+2580-U+259F)
    if (cp >= 0x2580 and cp <= 0x259F) return true;
    // Braille Patterns (U+2800-U+28FF)
    if (cp >= 0x2800 and cp <= 0x28FF) return true;
    // Powerline symbols (U+E0A0-U+E0D4) — should match primary font metrics
    if (cp >= 0xE0A0 and cp <= 0xE0D4) return true;
    return false;
}
