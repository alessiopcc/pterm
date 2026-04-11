/// Render thread: GL context, frame loop, draw callbacks, visual effects.
const std = @import("std");
const app_mod = @import("App.zig");
const App = app_mod.App;
const PaneData = app_mod.PaneData;
const gl = @import("gl");
const renderer_types = @import("renderer_types");
const render_state = @import("render_state");
const layout_mod = @import("layout");
const layout_types = @import("layout_types");
const opengl_backend_mod = @import("opengl_backend");
const font_types = @import("font_types");
const fontgrid_mod = @import("fontgrid");
const window_mod = @import("window");
const search_mod = @import("search");
const status_bar_mod = @import("status_bar_renderer");
const bell_state_mod = @import("bell_state");
const system_beep = @import("system_beep");
const actions = @import("actions.zig");

const OpenGLBackend = opengl_backend_mod.OpenGLBackend;
const FontGrid = fontgrid_mod.FontGrid;
const Window = window_mod.Window;
const RendererRect = layout_types.Rect;
const Rect = layout_mod.Rect.Rect;
const PaneTree = layout_mod.PaneTree;
const PaneNode = PaneTree.PaneNode;
const tree_ops = layout_mod.tree_ops;
const TabBarRenderer = layout_mod.TabBarRenderer.TabBarRenderer;
const Compositor = layout_mod.Compositor;
const StatusBarRenderer = status_bar_mod.StatusBarRenderer;
const SearchOverlay = search_mod.SearchOverlay.SearchOverlay;
const SearchColors = search_mod.SearchOverlay.SearchColors;
const RendererPalette = @import("theme").RendererPalette;
const BellState = bell_state_mod.BellState;
const AgentState = @import("agent_state").AgentState;
const glfw = @import("zglfw");

pub fn renderThreadMain(self: *App) void {
    // Acquire GL context
    self.window.makeContextCurrent();

    if (!self.gl_procs.init(glfw.getProcAddress)) {
        std.log.err("Failed to initialize OpenGL procedure table", .{});
        return;
    }
    gl.makeProcTableCurrent(&self.gl_procs);

    // Initialize OpenGL backend
    var backend = OpenGLBackend.init() catch |err| {
        std.log.err("Failed to initialize OpenGL backend: {}", .{err});
        return;
    };

    // Initial viewport setup
    {
        const fb = self.window.getFramebufferSize();
        backend.resize(fb.width, fb.height);
    }

    // Upload initial atlas
    {
        const atlas = self.font_grid.getAtlas();
        backend.uploadAtlas(atlas.getPixels(), atlas.getSize());
        self.font_grid.getAtlasMut().clearDirty();
        backend.uploadColorAtlas(atlas.getColorPixels(), atlas.getColorSize());
        self.font_grid.getAtlasMut().clearColorDirty();
    }

    // Initial terminal resize — use per-pane bounds
    actions.resizeAllPanes(self);

    const perf_log = if (self.perf_logging)
        std.fs.cwd().createFile("pterm_perf.log", .{}) catch null
    else
        null;

    const min_frame_ns: i128 = 16_000_000;
    var last_frame_ns: i128 = 0;

    while (!self.should_quit.load(.acquire)) {
        if (self.frame_requested.swap(false, .acq_rel)) {
            const now = std.time.nanoTimestamp();
            if (now - last_frame_ns < min_frame_ns) {
                self.frame_requested.store(true, .release);
                std.Thread.sleep(1_000_000);
                continue;
            }
            last_frame_ns = now;

            // Handle pending font size change
            if (self.pending_font_change.swap(false, .acq_rel)) {
                const new_size_fp = self.new_font_size.load(.acquire);
                const new_size: f32 = @as(f32, @floatFromInt(new_size_fp)) / 100.0;
                self.font_grid.setSize(new_size) catch {};

                const fb2 = self.window.getFramebufferSize();
                backend.resize(@intCast(fb2.width), @intCast(fb2.height));

                actions.resizeAllPanes(self);
            }

            // Handle pending resize
            if (self.pending_resize.swap(false, .acq_rel)) {
                const w = self.new_fb_width.load(.acquire);
                const h = self.new_fb_height.load(.acquire);
                backend.resize(w, h);
                actions.resizeAllPanes(self);
            }

            // Render frame: clear, tab bar, panes, borders
            const fb = self.window.getFramebufferSize();
            if (fb.width == 0 or fb.height == 0) {
                // Window is minimized — skip rendering to avoid GL errors
                // Re-request frame so we redraw once the window is restored
                self.frame_requested.store(true, .release);
                self.window.swapBuffers();
                _ = self.frame_arena.reset(.retain_capacity);
                std.Thread.sleep(16_000_000); // Sleep 16ms to avoid busy-loop while minimized
                continue;
            }
            const metrics = self.font_grid.getMetrics();
            const tab_bar_height = TabBarRenderer.computeHeight(metrics.cell_height);

            // Clear full window
            const bg = self.renderer_palette.default_bg;
            gl.ClearColor(
                @as(gl.float, @floatFromInt(bg.r)) / 255.0,
                @as(gl.float, @floatFromInt(bg.g)) / 255.0,
                @as(gl.float, @floatFromInt(bg.b)) / 255.0,
                1.0,
            );
            gl.Viewport(0, 0, @intCast(fb.width), @intCast(fb.height));
            gl.Disable(gl.SCISSOR_TEST);
            gl.Clear(gl.COLOR_BUFFER_BIT);

            // Update tab titles periodically (forced on pane/tab create/close)
            if (self.frame_count % 60 == 0 or self.frame_count <= 1) {
                self.updateTabTitles();
            }

            // Render tab bar
            var tab_bar_ctx = TabBarRenderCtx{
                .backend = &backend,
                .font_grid = self.font_grid,
            };
            // Upload icon texture on first frame
            if (backend.icon_size == 0) {
                const icon_data = @import("icon");
                const img = icon_data.images[1]; // 32x32
                const sz: u32 = @intCast(img.width);
                const byte_count = sz * @as(u32, @intCast(img.height)) * 4;
                backend.uploadIcon(img.pixels[0..byte_count], sz);
            }

            // Build per-tab bell badge and agent badge flags for TabBarRenderer
            var bell_badges_buf: [64]bool = [_]bool{false} ** 64;
            var agent_badges_buf: [64]bool = [_]bool{false} ** 64;
            var agent_tab_buf: [64]bool = [_]bool{false} ** 64;
            const tab_count = self.tab_manager.tabCount();
            const badge_count = @min(tab_count, 64);
            {
                self.pane_mutex.lock();
                defer self.pane_mutex.unlock();
                for (self.tab_manager.tabs.items, 0..) |tab, ti| {
                    if (ti >= 64) break;
                    // Check if any pane in this tab has show_badge or agent state
                    const leaf_infos = tree_ops.collectLeafInfos(tab.root, self.frame_arena.allocator()) catch &.{};
                    for (leaf_infos) |info| {
                        if (self.pane_data.getPtr(info.pane_id)) |pd_ptr| {
                            if (pd_ptr.*.bell_state.show_badge) {
                                bell_badges_buf[ti] = true;
                            }
                            // Agent waiting badge
                            if (pd_ptr.*.agent_state.show_badge) {
                                agent_badges_buf[ti] = true;
                            }
                            // Agent tab icon
                            if (pd_ptr.*.agent_state.is_agent_tab.load(.acquire)) {
                                agent_tab_buf[ti] = true;
                            }
                        }
                    }
                }
            }

            TabBarRenderer.render(
                &self.tab_manager,
                .{
                    .tab_bar_bg = self.renderer_palette.ui_tab_bar_bg.toU32(),
                    .tab_active = self.renderer_palette.ui_tab_active.toU32(),
                    .tab_inactive = self.renderer_palette.ui_tab_inactive.toU32(),
                    .fg_color = self.renderer_palette.default_fg.toU32(),
                    .agent_alert = self.renderer_palette.ui_agent_alert.toU32(),
                    .pane_border = self.renderer_palette.ui_pane_border_active.toU32(),
                    .cell_width = metrics.cell_width,
                    .cell_height = metrics.cell_height,
                    .hovered_control = self.hovered_control,
                    .bell_badge_color = self.renderer_palette.ui_bell_badge.toU32(),
                    .tab_bell_badges = bell_badges_buf[0..badge_count],
                    .tab_agent_badges = agent_badges_buf[0..badge_count],
                    .tab_is_agent = agent_tab_buf[0..badge_count],
                },
                fb.width,
                drawFilledRectCallback,
                drawTextCallback,
                drawIconCallback,
                @ptrCast(&tab_bar_ctx),
            );

            // Render panes in active tab
            const status_bar_height: u32 = if (self.config.status_bar.visible)
                StatusBarRenderer.statusBarHeight(metrics.cell_height)
            else
                0;

            if (self.tab_manager.getActiveTab()) |active_tab| {
                const content_y: i32 = @intCast(tab_bar_height);
                const total_chrome = tab_bar_height + status_bar_height;
                const content_h: u32 = if (fb.height > total_chrome) fb.height - total_chrome else 0;
                const available = Rect{
                    .x = 0,
                    .y = content_y,
                    .w = fb.width,
                    .h = content_h,
                };

                // Fill content area with default bg to cover cell-grid rounding gaps
                backend.drawFilledRect(RendererRect{
                    .x = 0,
                    .y = content_y,
                    .w = fb.width,
                    .h = content_h,
                }, self.renderer_palette.default_bg);

                tree_ops.computeBounds(active_tab.root, available, metrics.cell_width, metrics.cell_height, 1);

                // Render each pane (single tree walk, no re-lookup per leaf)
                const leaf_infos = tree_ops.collectLeafInfos(active_tab.root, std.heap.page_allocator) catch &.{};
                defer if (leaf_infos.len > 0) std.heap.page_allocator.free(leaf_infos);

                self.pane_mutex.lock();
                for (leaf_infos) |info| {
                    if (self.pane_data.get(info.pane_id)) |pd| {
                        {
                            const bounds = info.bounds;
                            if (bounds.w == 0 or bounds.h == 0) continue;

                            // Debounced search: run after 150ms of no input
                            if (pd.search_state.is_open and pd.search_state.query_dirty) {
                                const search_now = std.time.nanoTimestamp();
                                const elapsed_ms = @divFloor(search_now - pd.search_state.last_input_ns, 1_000_000);
                                if (elapsed_ms >= 150) {
                                    pd.search_state.query_dirty = false;
                                    actions.runSearchForPane(pd);
                                } else {
                                    self.requestFrame(); // keep rendering until debounce fires
                                }
                            }

                            // Debounced agent scan — check flag set by observer callback
                            // Skip scan while resize suppress is active (PTY redraws produce false matches)
                            if (pd.suppress_agent_output.load(.acquire)) {
                                pd.needs_agent_scan.store(false, .release);
                            } else if (pd.needs_agent_scan.load(.acquire)) {
                                pd.needs_agent_scan.store(false, .release);
                                if (self.agent_detector) |*detector| {
                                    // Extract last N visible lines from terminal for pattern scan
                                    const scan_snap = pd.termio.lockTerminal();
                                    var line_buf: [20][256]u8 = undefined;
                                    var lines: [20][]const u8 = undefined;
                                    const n_lines = extractVisibleLines(scan_snap, &line_buf, &lines, detector.scan_lines);
                                    pd.termio.unlockTerminal();
                                    if (detector.scanLines(lines[0..n_lines])) {
                                        pd.agent_state.triggerWaiting();
                                    }
                                }
                            }
                            // Idle detection check (skip during resize suppress)
                            if (!pd.suppress_agent_output.load(.acquire) and pd.idle_tracker.isIdle(std.time.nanoTimestamp())) {
                                pd.agent_state.triggerWaiting();
                            }

                            // Snapshot under mutex
                            const snapshot = pd.termio.lockTerminal();
                            const snap = render_state.snapshotCells(
                                self.frame_arena.allocator(),
                                snapshot,
                                &self.renderer_palette,
                                pd.scroll_offset,
                            ) catch {
                                pd.termio.unlockTerminal();
                                continue;
                            };
                            pd.termio.unlockTerminal();

                            // Build render state (per-pane row cache)
                            var rs = render_state.buildFromSnapshot(
                                self.frame_arena.allocator(),
                                snap,
                                self.font_grid,
                                bounds.w,
                                bounds.h,
                                &self.renderer_palette,
                                &pd.row_cache,
                            ) catch continue;

                            // Cursor visibility — hide when scrolled into history
                            const is_focused = info.pane_id == active_tab.focused_pane_id;
                            const blink_vis = if (self.config.cursor.blink) self.cursor_visible else true;
                            rs.cursor.visible = blink_vis and self.focused and is_focused and pd.scroll_offset == 0;
                            // Apply configured cursor style
                            rs.cursor.style = switch (self.config.cursor.style) {
                                .block => .block,
                                .hollow => .hollow,
                                .bar => .ibeam,
                                .underline => .underline,
                            };
                            rs.cell_width = metrics.cell_width;
                            rs.cell_height = metrics.cell_height;

                            // Upload atlas if dirty
                            if (self.font_grid.getAtlas().isDirty()) {
                                const atlas = self.font_grid.getAtlas();
                                backend.uploadAtlas(atlas.getPixels(), atlas.getSize());
                                self.font_grid.getAtlasMut().clearDirty();
                            }
                            if (self.font_grid.getAtlas().isColorDirty()) {
                                const atlas = self.font_grid.getAtlas();
                                backend.uploadColorAtlas(atlas.getColorPixels(), atlas.getColorSize());
                                self.font_grid.getAtlasMut().clearColorDirty();
                            }

                            // URL detection on visible viewport
                            if (self.config.url.enabled) {
                                // Extract visible lines as u21 codepoint slices for URL scanning
                                const url_rows = snap.rows;
                                const url_cols = snap.cols;
                                const url_lines = self.frame_arena.allocator().alloc([]const u21, url_rows) catch null;
                                if (url_lines) |url_line_slices| {
                                    const url_mod = @import("url");
                                    const UrlDetector = url_mod.UrlDetector;
                                    for (0..url_rows) |r| {
                                        const row_start = r * @as(usize, url_cols);
                                        const row_cps = self.frame_arena.allocator().alloc(u21, url_cols) catch {
                                            url_line_slices[r] = &.{};
                                            continue;
                                        };
                                        for (0..url_cols) |c| {
                                            const cell_snap = snap.cells[row_start + c];
                                            row_cps[c] = if (cell_snap.grapheme_len > 0) cell_snap.grapheme[0] else ' ';
                                        }
                                        url_line_slices[r] = row_cps;
                                    }
                                    const detected = UrlDetector.detectUrls(url_line_slices, 0, self.frame_arena.allocator()) catch &.{};
                                    pd.url_state.updateDetected(detected, self.frame_arena.allocator());
                                    // NOTE: detected_allocator is frame arena, freed each frame -- ok because
                                    // updateDetected is called every frame when url.enabled=true.
                                    // Override allocator to null so deinit doesn't double-free arena memory.
                                    pd.url_state.detected_allocator = null;
                                }
                            }

                            // Draw pane — slightly dimmed background for unfocused panes
                            const pane_bg = if (is_focused)
                                self.renderer_palette.default_bg
                            else blk: {
                                const dbg = self.renderer_palette.default_bg;
                                // Darken by ~25% for unfocused
                                break :blk renderer_types.Color{
                                    .r = dbg.r -| (dbg.r / 4),
                                    .g = dbg.g -| (dbg.g / 4),
                                    .b = dbg.b -| (dbg.b / 4),
                                };
                            };
                            backend.drawFrameInRect(&rs, pane_bg, toRendererRect(bounds));

                            // Draw search match highlight rectangles (semi-transparent over text)
                            if (pd.search_state.is_open and pd.search_state.total_matches > 0) {
                                const current_idx = pd.search_state.current_match;
                                const sb_off = pd.search_state.scrollback_offset;
                                const cw: u32 = @intFromFloat(metrics.cell_width);
                                const ch: u32 = @intFromFloat(metrics.cell_height);
                                const pad: i32 = @intFromFloat(rs.grid_padding);
                                for (pd.search_state.matches.items, 0..) |m, mi| {
                                    if (m.in_scrollback) continue;
                                    if (m.line_index < sb_off) continue;
                                    const vis_row: u32 = m.line_index - sb_off;
                                    const is_current = @as(u32, @intCast(mi)) == current_idx;
                                    const hl = renderer_types.Color{
                                        .r = if (is_current) 0xF3 else 0xF9,
                                        .g = if (is_current) 0x8B else 0xE2,
                                        .b = if (is_current) 0xA8 else 0xAF,
                                        .a = 90,
                                    };
                                    var mcol: u16 = m.col_start;
                                    while (mcol < m.col_end) : (mcol += 1) {
                                        backend.drawFilledRectAlpha(RendererRect{
                                            .x = bounds.x + pad + @as(i32, @intCast(@as(u32, mcol) * cw)),
                                            .y = bounds.y + pad + @as(i32, @intCast(vis_row * ch)),
                                            .w = cw,
                                            .h = ch,
                                        }, hl);
                                    }
                                }
                            }

                            // Selection highlight rendering
                            if (pd.surface.selection.range) |sel_range| {
                                const norm = sel_range.normalized();
                                const sel_cw: u32 = @intFromFloat(metrics.cell_width);
                                const sel_ch: u32 = @intFromFloat(metrics.cell_height);
                                const sel_pad: i32 = @intFromFloat(rs.grid_padding);
                                const sel_color = renderer_types.Color{ .r = 0x45, .g = 0x47, .b = 0x5a, .a = 120 };
                                var sel_row: u32 = norm.start_row;
                                while (sel_row <= norm.end_row) : (sel_row += 1) {
                                    const sc: u16 = if (sel_row == norm.start_row) norm.start_col else 0;
                                    const ec: u16 = if (sel_row == norm.end_row) norm.end_col + 1 else rs.grid_cols;
                                    var sel_col: u16 = sc;
                                    while (sel_col < ec) : (sel_col += 1) {
                                        backend.drawFilledRectAlpha(RendererRect{
                                            .x = bounds.x + sel_pad + @as(i32, @intCast(@as(u32, sel_col) * sel_cw)),
                                            .y = bounds.y + sel_pad + @as(i32, @intCast(sel_row * sel_ch)),
                                            .w = sel_cw,
                                            .h = sel_ch,
                                        }, sel_color);
                                    }
                                }
                            }

                            // URL hover underline rendering
                            if (pd.url_state.hovered_url) |hurl| {
                                const url_color = self.renderer_palette.ui_url_hover;
                                const cw_u: u32 = @intFromFloat(metrics.cell_width);
                                const ch_u: u32 = @intFromFloat(metrics.cell_height);
                                var ucol: u16 = hurl.col_start;
                                while (ucol < hurl.col_end) : (ucol += 1) {
                                    backend.drawFilledRect(RendererRect{
                                        .x = bounds.x + @as(i32, @intCast(@as(u32, ucol) * cw_u)),
                                        .y = bounds.y + @as(i32, @intCast((@as(u32, hurl.row) + 1) * ch_u)) - 1,
                                        .w = cw_u,
                                        .h = 1,
                                    }, url_color);
                                }
                            }

                            // Bell flash overlay + sound + window attention
                            // Never flash the active pane — only background panes
                            if (!is_focused) {
                                processBellForPane(self, pd, toRendererRect(bounds), &backend);
                            } else {
                                // Still consume the trigger so it doesn't fire later
                                _ = pd.bell_state.consumeTrigger();
                            }

                            // Agent flash overlay (150ms flash on waiting entry)
                            if (!is_focused) {
                                processAgentFlashForPane(self, pd, toRendererRect(bounds), &backend);
                            }

                            // Search overlay rendering
                            if (pd.search_state.is_open and is_focused) {
                                const search_metrics = SearchOverlay.computeMetrics(
                                    @intCast(bounds.x),
                                    @intCast(bounds.y),
                                    bounds.w,
                                    metrics.cell_width,
                                    metrics.cell_height,
                                );
                                var search_ctx = SearchRenderCtx{
                                    .backend = &backend,
                                    .font_grid = self.font_grid,
                                };
                                SearchOverlay.render(
                                    &pd.search_state,
                                    search_metrics,
                                    .{
                                        .bar_bg = self.renderer_palette.ui_search_bar_bg.toU32(),
                                        .fg = self.renderer_palette.default_fg.toU32(),
                                        .no_match = self.renderer_palette.ui_search_current_match.toU32(),
                                        .cursor_color = self.renderer_palette.ui_pane_border_active.toU32(),
                                    },
                                    searchDrawRect,
                                    searchDrawText,
                                    @ptrCast(&search_ctx),
                                );
                            }
                        }
                    }
                }
                // Render pane borders (after all panes, full viewport, no scissor)
                backend.setFullViewport();
                renderPaneBorders(active_tab.root, active_tab.focused_pane_id, &backend, &self.renderer_palette, &self.pane_data);
                self.pane_mutex.unlock();

                // Re-draw tab bar bottom separator on top of pane content
                // (pane background clear can bleed into the separator line)
                {
                    const sep_color = self.renderer_palette.ui_pane_border_active;
                    const sep_r = sep_color.r;
                    const sep_g = sep_color.g;
                    const sep_b = sep_color.b;
                    const lighter = renderer_types.Color{
                        .r = sep_r +| 30,
                        .g = sep_g +| 30,
                        .b = sep_b +| 30,
                    };
                    backend.drawFilledRect(RendererRect{
                        .x = 0,
                        .y = @as(i32, @intCast(tab_bar_height)) - 1,
                        .w = fb.width,
                        .h = 1,
                    }, lighter);
                }

                // Render status bar at window bottom
                if (self.config.status_bar.visible and status_bar_height > 0) {
                    backend.setFullViewport();

                    // Build PaneStatusInfo array for current tab
                    var pane_infos: [32]status_bar_mod.PaneStatusInfo = undefined;
                    var pane_count: usize = 0;
                    var bg_waiting: u32 = 0;
                    {
                        self.pane_mutex.lock();
                        defer self.pane_mutex.unlock();
                        const current_leaf_infos = tree_ops.collectLeafInfos(active_tab.root, self.frame_arena.allocator()) catch &.{};
                        for (current_leaf_infos) |li| {
                            if (pane_count >= 32) break;
                            if (self.pane_data.get(li.pane_id)) |lpd| {
                                pane_infos[pane_count] = .{
                                    .pane_number = @intCast(pane_count + 1),
                                    .state = lpd.agent_state.state.load(.acquire),
                                    .is_focused = li.pane_id == active_tab.focused_pane_id,
                                };
                                pane_count += 1;
                            }
                        }

                        // Count waiting panes in background (non-active) tabs
                        for (self.tab_manager.tabs.items, 0..) |bg_tab, bti| {
                            if (bti == self.tab_manager.active_idx) continue;
                            const bg_leaves = tree_ops.collectLeafInfos(bg_tab.root, self.frame_arena.allocator()) catch &.{};
                            for (bg_leaves) |bli| {
                                if (self.pane_data.get(bli.pane_id)) |bpd| {
                                    if (bpd.agent_state.state.load(.acquire) == .waiting) {
                                        bg_waiting += 1;
                                    }
                                }
                            }
                        }
                    }

                    const sb_y_offset: u32 = if (fb.height > status_bar_height) fb.height - status_bar_height else 0;
                    const sb_config = status_bar_mod.StatusBarConfig{
                        .bg_color = self.renderer_palette.ui_tab_bar_bg.toU32(),
                        .border_color = self.renderer_palette.ui_pane_border.toU32(),
                        .idle_color = lightenColorU32(self.renderer_palette.ui_tab_bar_bg.toU32(), 30),
                        .working_color = self.renderer_palette.ansi_normal[2].toU32(),
                        .waiting_color = self.renderer_palette.ui_agent_alert.toU32(),
                        .focused_bg_color = lightenColorU32(self.renderer_palette.ui_tab_bar_bg.toU32(), 15),
                    };

                    var sb_render_ctx = TabBarRenderCtx{
                        .backend = &backend,
                        .font_grid = self.font_grid,
                    };
                    StatusBarRenderer.render(
                        pane_infos[0..pane_count],
                        sb_config,
                        fb.width,
                        sb_y_offset,
                        metrics.cell_height,
                        bg_waiting,
                        statusBarDrawRect,
                        statusBarDrawText,
                        @ptrCast(&sb_render_ctx),
                    );
                }
            }

            // Render preset picker overlay if visible
            if (self.preset_picker.visible) {
                var name_ptrs: [64][]const u8 = undefined;
                const name_count = @min(self.config.layouts.len, 64);
                for (0..name_count) |i| {
                    name_ptrs[i] = self.config.layouts[i].name;
                }
                var pp_render_ctx = TabBarRenderCtx{
                    .backend = &backend,
                    .font_grid = self.font_grid,
                };
                self.preset_picker.render(
                    name_ptrs[0..name_count],
                    metrics.cell_width,
                    metrics.cell_height,
                    fb.width,
                    fb.height,
                    .{
                        .bg = self.renderer_palette.ui_tab_bar_bg.toU32(),
                        .border = self.renderer_palette.ui_pane_border.toU32(),
                        .selected = self.renderer_palette.ui_tab_active.toU32(),
                        .fg = self.renderer_palette.default_fg.toU32(),
                        .overlay_bg = 0x00000080, // Semi-transparent black
                    },
                    shellPickerDrawRectCallback,
                    drawTextCallback,
                    @ptrCast(&pp_render_ctx),
                );
            }

            // Render shell picker overlay if visible
            if (self.shell_picker.visible) {
                const shell_count = self.shell_picker.shell_count;
                var sp_render_ctx = TabBarRenderCtx{
                    .backend = &backend,
                    .font_grid = self.font_grid,
                };
                self.shell_picker.render(
                    self.available_shell_display_slices[0..shell_count],
                    metrics.cell_width,
                    metrics.cell_height,
                    fb.width,
                    fb.height,
                    .{
                        .bg = 0x2A2A3AFF, // Dark blue-grey, opaque
                        .border = self.renderer_palette.ui_pane_border.toU32(),
                        .selected = 0x45475AFF, // Visible selection highlight
                        .fg = self.renderer_palette.default_fg.toU32(),
                        .overlay_bg = 0x000000C0, // Dark overlay backdrop
                        .active_marker = self.renderer_palette.ui_agent_alert.toU32(),
                    },
                    shellPickerDrawRectCallback,
                    drawTextCallback,
                    @ptrCast(&sp_render_ctx),
                );
            }

            // Restore full viewport
            backend.setFullViewport();

            // Draw 1px window border (frameless window needs visible edge)
            {
                const border_color = self.renderer_palette.ui_pane_border;
                const w = fb.width;
                const h = fb.height;
                // Top edge
                backend.drawFilledRect(RendererRect{ .x = 0, .y = 0, .w = w, .h = 1 }, border_color);
                // Bottom edge
                backend.drawFilledRect(RendererRect{ .x = 0, .y = @as(i32, @intCast(h)) - 1, .w = w, .h = 1 }, border_color);
                // Left edge
                backend.drawFilledRect(RendererRect{ .x = 0, .y = 0, .w = 1, .h = h }, border_color);
                // Right edge
                backend.drawFilledRect(RendererRect{ .x = @as(i32, @intCast(w)) - 1, .y = 0, .w = 1, .h = h }, border_color);
            }

            // Cursor blink
            updateCursorBlink(self);

            // Diagnostics
            self.frame_count += 1;

            // Decrement activity suppression cooldown
            const sup = self.suppress_activity_frames.load(.acquire);
            if (sup > 0) self.suppress_activity_frames.store(sup - 1, .release);
            if (perf_log) |f| {
                if (self.frame_count == 1 or self.frame_count % 60 == 0) {
                    const diag = backend.getDiagnostics();
                    var pbuf: [128]u8 = undefined;
                    const pline = std.fmt.bufPrint(&pbuf, "frame={d} frame_time={d}us draws={d}\n", .{
                        self.frame_count, diag.frame_time_us, diag.draw_calls,
                    }) catch "";
                    if (pline.len > 0) _ = f.write(pline) catch 0;
                }
            }

            self.window.swapBuffers();
            _ = self.frame_arena.reset(.retain_capacity);
        } else {
            std.Thread.sleep(1_000_000);
        }
    }

    // Cleanup
    if (perf_log) |f| f.close();
    backend.deinit();
    gl.makeProcTableCurrent(null);
    Window.detachContext();
}

// -- Render helper callbacks --

fn drawIconCallback(px_x: i32, px_y: i32, size: u32, ctx: *anyopaque) void {
    const rc: *TabBarRenderCtx = @ptrCast(@alignCast(ctx));
    rc.backend.drawIcon(px_x, px_y, size);
}

fn drawFilledRectCallback(rect: Rect, color: Compositor.ColorU32, ctx: *anyopaque) void {
    const rc: *TabBarRenderCtx = @ptrCast(@alignCast(ctx));
    const c = renderer_types.Color.fromU32(color);
    rc.backend.drawFilledRect(toRendererRect(rect), c);
}

fn shellPickerDrawRectCallback(x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void {
    const rc: *TabBarRenderCtx = @ptrCast(@alignCast(ctx));
    const c = renderer_types.Color.fromU32(color);
    rc.backend.drawFilledRect(.{ .x = x, .y = y, .w = w, .h = h }, c);
}

pub const TabBarRenderCtx = struct {
    backend: *OpenGLBackend,
    font_grid: *FontGrid,
};

fn drawTextCallback(text: []const u8, px_x: i32, px_y: i32, color: Compositor.ColorU32, ctx: *anyopaque) void {
    const rc: *TabBarRenderCtx = @ptrCast(@alignCast(ctx));
    const backend = rc.backend;
    const font_grid = rc.font_grid;
    const metrics = font_grid.getMetrics();

    // Build CellInstance array for each byte in the string
    var instances: [128]renderer_types.CellInstance = undefined;
    var count: usize = 0;

    const ascender: i32 = @intFromFloat(metrics.ascender);
    for (text) |byte| {
        if (count >= 128) break;
        const glyph = font_grid.getGlyph(@as(u21, byte)) catch continue;

        // Compute vertical offset: same as pane rendering (ascender - bearing_y)
        const sby: i32 = ascender - glyph.bearing_y;
        instances[count] = .{
            .grid_col = @intCast(count),
            .grid_row = 0,
            .atlas_x = glyph.region.x,
            .atlas_y = glyph.region.y,
            .atlas_w = glyph.region.w,
            .atlas_h = glyph.region.h,
            .bearing_x = @intCast(glyph.bearing_x),
            .bearing_y = @intCast(std.math.clamp(sby, -32768, 32767)),
            .fg_color = color,
            .bg_color = 0,
            .flags = 0,
        };
        count += 1;
    }

    if (count == 0) return;

    // Upload atlas if dirty (glyph lookup may have rasterized new glyphs)
    if (font_grid.getAtlas().isDirty()) {
        const atlas = font_grid.getAtlas();
        backend.uploadAtlas(atlas.getPixels(), atlas.getSize());
        font_grid.getAtlasMut().clearDirty();
    }

    // Set up text shader with pixel-based grid offset
    // Use setFullViewport to get correct projection, then override grid offset
    backend.setFullViewport();

    backend.text_program.use();
    backend.text_program.setUniformMat4("uProjection", backend.projection);
    backend.text_program.setUniformVec2("uCellSize", metrics.cell_width, metrics.cell_height);
    backend.text_program.setUniformVec2("uGridOffset", @floatFromInt(px_x), @floatFromInt(px_y));
    backend.text_program.setUniformFloat("uTextScale", 0.75);
    backend.text_program.setUniformVec2("uAtlasSize", @floatFromInt(backend.atlas_size), @floatFromInt(backend.atlas_size));
    backend.text_program.setUniformVec2("uColorAtlasSize", @floatFromInt(backend.color_atlas_size), @floatFromInt(backend.color_atlas_size));

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    gl.ActiveTexture(gl.TEXTURE0);
    gl.BindTexture(gl.TEXTURE_2D, backend.atlas_texture);
    backend.text_program.setUniformInt("uAtlasTexture", 0);

    gl.ActiveTexture(gl.TEXTURE1);
    gl.BindTexture(gl.TEXTURE_2D, backend.color_atlas_texture);
    backend.text_program.setUniformInt("uColorAtlasTexture", 1);

    gl.BindVertexArray(backend.quad_vao);
    gl.BindBuffer(gl.ARRAY_BUFFER, backend.text_instance_vbo);
    gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(count * @sizeOf(renderer_types.CellInstance)), @ptrCast(&instances));
    OpenGLBackend.setupInstanceAttributes(backend.text_instance_vbo);
    gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(count));
    gl.BindVertexArray(0);
}

// -- Search overlay render callbacks --

const SearchRenderCtx = struct {
    backend: *OpenGLBackend,
    font_grid: *FontGrid,
};

fn searchDrawRect(x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void {
    const rc: *SearchRenderCtx = @ptrCast(@alignCast(ctx));
    const c = renderer_types.Color.fromU32(color);
    rc.backend.drawFilledRect(.{ .x = x, .y = y, .w = w, .h = h }, c);
}

fn searchDrawText(text: []const u8, px_x: i32, px_y: i32, color: u32, ctx: *anyopaque) void {
    const rc: *SearchRenderCtx = @ptrCast(@alignCast(ctx));
    // Reuse the same glyph text rendering as tab bar
    drawTextCallback(text, px_x, px_y, color, @ptrCast(rc));
}

// -- Status bar render callbacks --

fn statusBarDrawRect(x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void {
    const rc: *TabBarRenderCtx = @ptrCast(@alignCast(ctx));
    const c = renderer_types.Color.fromU32(color);
    rc.backend.drawFilledRect(.{ .x = x, .y = y, .w = w, .h = h }, c);
}

fn statusBarDrawText(text: []const u8, px_x: i32, px_y: i32, color: u32, scale: f32, ctx: *anyopaque) void {
    _ = scale; // Scale is handled by StatusBarRenderer; we use the same glyph renderer
    const rc: *TabBarRenderCtx = @ptrCast(@alignCast(ctx));
    // Reuse the same glyph text rendering as tab bar
    drawTextCallback(text, px_x, px_y, color, @ptrCast(rc));
}

/// Lighten a packed RGBA u32 color by a percentage (0-100).
pub fn lightenColorU32(color: u32, percent: u32) u32 {
    const r = @as(u8, @truncate((color >> 24) & 0xFF));
    const g = @as(u8, @truncate((color >> 16) & 0xFF));
    const b_ch = @as(u8, @truncate((color >> 8) & 0xFF));
    const a = @as(u8, @truncate(color & 0xFF));
    const nr: u8 = @intCast(@min(255, @as(u16, r) + @as(u16, @intCast(((@as(u32, 255 - r) * percent) / 100)))));
    const ng: u8 = @intCast(@min(255, @as(u16, g) + @as(u16, @intCast(((@as(u32, 255 - g) * percent) / 100)))));
    const nb: u8 = @intCast(@min(255, @as(u16, b_ch) + @as(u16, @intCast(((@as(u32, 255 - b_ch) * percent) / 100)))));
    return (@as(u32, nr) << 24) | (@as(u32, ng) << 16) | (@as(u32, nb) << 8) | @as(u32, a);
}

pub fn renderPaneBorders(node: *PaneNode, focused_id: u32, backend: *OpenGLBackend, pal: *const RendererPalette, pane_data_map: *const std.AutoHashMapUnmanaged(u32, *PaneData)) void {
    switch (node.*) {
        .branch => |b| {
            // Use the FULL parent bounds so the border line spans the entire split
            const parent_bounds = getNodeBounds(node);
            const first_bounds = getNodeBounds(b.first);

            // Use active border color if focused pane is adjacent
            const focus_in_first = tree_ops.findLeaf(b.first, focused_id) != null;
            const focus_in_second = tree_ops.findLeaf(b.second, focused_id) != null;

            // Check if any adjacent pane is in waiting state for agent_alert border
            var has_waiting = false;
            {
                const subtrees = [_]*PaneNode{ b.first, b.second };
                for (subtrees) |subtree| {
                    const leaves = tree_ops.collectLeaves(subtree, std.heap.page_allocator) catch &[_]u32{};
                    defer if (leaves.len > 0) std.heap.page_allocator.free(leaves);
                    for (leaves) |pid| {
                        if (pane_data_map.get(pid)) |pd| {
                            if (pd.agent_state.state.load(.acquire) == .waiting) {
                                has_waiting = true;
                                break;
                            }
                        }
                    }
                    if (has_waiting) break;
                }
            }

            const border_color = if (has_waiting)
                pal.ui_agent_alert
            else if (focus_in_first or focus_in_second)
                pal.ui_pane_border_active
            else
                pal.ui_pane_border;

            switch (b.direction) {
                .vertical => {
                    // Vertical split: draw a full-height vertical line at the split point
                    const border_x = first_bounds.x + @as(i32, @intCast(first_bounds.w));
                    backend.drawFilledRect(RendererRect{
                        .x = border_x,
                        .y = parent_bounds.y,
                        .w = 1,
                        .h = parent_bounds.h,
                    }, border_color);
                },
                .horizontal => {
                    // Horizontal split: draw a full-width horizontal line at the split point
                    const border_y = first_bounds.y + @as(i32, @intCast(first_bounds.h));
                    backend.drawFilledRect(RendererRect{
                        .x = parent_bounds.x,
                        .y = border_y,
                        .w = parent_bounds.w,
                        .h = 1,
                    }, border_color);
                },
            }

            renderPaneBorders(b.first, focused_id, backend, pal, pane_data_map);
            renderPaneBorders(b.second, focused_id, backend, pal, pane_data_map);
        },
        .leaf => {},
    }
}

pub fn getNodeBounds(node: *PaneNode) Rect {
    switch (node.*) {
        .leaf => |l| return l.bounds,
        .branch => |b| {
            const fb = getNodeBounds(b.first);
            const sb = getNodeBounds(b.second);
            const min_x = @min(fb.x, sb.x);
            const min_y = @min(fb.y, sb.y);
            const max_x = @max(fb.x + @as(i32, @intCast(fb.w)), sb.x + @as(i32, @intCast(sb.w)));
            const max_y = @max(fb.y + @as(i32, @intCast(fb.h)), sb.y + @as(i32, @intCast(sb.h)));
            return .{
                .x = min_x,
                .y = min_y,
                .w = @intCast(max_x - min_x),
                .h = @intCast(max_y - min_y),
            };
        },
    }
}

pub fn updateCursorBlink(self: *App) void {
    if (!self.focused or !self.config.cursor.blink) {
        self.cursor_visible = true;
        return;
    }
    const now = std.time.nanoTimestamp();
    const elapsed = now - self.cursor_blink_timer;
    const blink_interval: i128 = 530_000_000;
    if (elapsed >= blink_interval) {
        self.cursor_visible = !self.cursor_visible;
        self.cursor_blink_timer = now;
        self.requestFrame();
    }
}

/// Convert a layout Rect to renderer layout_types Rect.
pub fn toRendererRect(rect: Rect) RendererRect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

/// Process bell state for a pane during render: consume trigger, draw flash, play sound.
pub fn processBellForPane(self: *App, pd: *PaneData, bounds: RendererRect, backend: *OpenGLBackend) void {
    const mode = self.config.bell.mode;
    const wants_visual = (mode == .visual or mode == .both);
    const wants_sound = (mode == .sound or mode == .both);

    // Consume trigger from read thread (atomic)
    if (pd.bell_state.consumeTrigger()) {
        // Window attention when not focused (D-31)
        if (!self.focused) {
            self.window.handle.requestAttention();
        }
        // Sound (D-32)
        if (wants_sound) {
            system_beep.beep();
        }
    }

    // Update and render flash overlay (D-27: 120ms amber 15% alpha)
    if (wants_visual) {
        pd.bell_state.updateFlash();
        if (pd.bell_state.flash_active) {
            const flash_color = renderer_types.Color{
                .r = self.renderer_palette.ui_bell_flash.r,
                .g = self.renderer_palette.ui_bell_flash.g,
                .b = self.renderer_palette.ui_bell_flash.b,
                .a = 38, // 15% of 255 ~= 38
            };
            backend.drawFilledRectAlpha(bounds, flash_color);
            self.requestFrame(); // Keep rendering until flash ends
        }
    }

    // If mode is none, consume and discard (already consumed above if trigger fired)
}

/// Process agent flash state for a pane during render: consume trigger, draw flash overlay.
/// Mirrors processBellForPane pattern (D-16: 150ms amber flash at 15% alpha).
pub fn processAgentFlashForPane(self: *App, pd: *PaneData, bounds: RendererRect, backend: *OpenGLBackend) void {
    // Idle transition: if in .working and no output for 500ms, go back to .idle
    // Also clears resize suppress flag so normal detection resumes
    if (pd.agent_state.state.load(.acquire) == .working or
        pd.suppress_agent_output.load(.acquire))
    {
        const now = std.time.nanoTimestamp();
        if (pd.idle_tracker.last_output_ns > 0 and
            (now - pd.idle_tracker.last_output_ns) >= 500_000_000)
        {
            pd.suppress_agent_output.store(false, .release);
            pd.agent_state.markIdle();
        }
    }
    // Consume notification pending flag and fire OS notification
    if (pd.agent_state.notification_pending.load(.acquire)) {
        pd.agent_state.notification_pending.store(false, .release);
        // Build pane identity string "Tab N, Pane M"
        var identity_buf: [64]u8 = undefined;
        var identity_stream = std.io.fixedBufferStream(&identity_buf);
        identity_stream.writer().print("Tab {d}, Pane {d}", .{
            pd.tab_index + 1,
            pd.pane_id,
        }) catch {};
        const pane_identity = identity_buf[0..identity_stream.pos];
        self.notification_manager.notify(
            self.allocator,
            pd.pane_id,
            pane_identity,
            null, // matched_text not available at render time
            self.focused,
        );
    }

    _ = pd.agent_state.consumeFlash();
    pd.agent_state.updateFlash();
    if (pd.agent_state.flash_active) {
        const alert_color = self.renderer_palette.ui_agent_alert;
        const flash_color = renderer_types.Color{
            .r = alert_color.r,
            .g = alert_color.g,
            .b = alert_color.b,
            .a = 38, // 15% of 255 ~= 38
        };
        backend.drawFilledRectAlpha(bounds, flash_color);
        self.requestFrame(); // Keep rendering until flash ends
    }
    // Keep rendering while in waiting state (for pulse animation)
    if (pd.agent_state.state.load(.acquire) == .waiting) {
        self.requestFrame();
    }
}

/// Extract the last N visible lines from the terminal for agent pattern scanning.
/// Returns the number of lines extracted. Each line is written into line_buf/lines arrays.
/// Uses the same ghostty-vt pin API as snapshotCells.
pub fn extractVisibleLines(
    terminal_snapshot: anytype,
    line_buf: *[20][256]u8,
    lines: *[20][]const u8,
    max_lines: u32,
) usize {
    const n = @min(max_lines, 20);
    const screens = @constCast(terminal_snapshot).getScreens();
    const screen = screens.active;
    const rows: usize = @intCast(screen.pages.rows);
    const cols: usize = @intCast(screen.pages.cols);
    const cursor_row: usize = @intCast(screen.cursor.y);

    var count: usize = 0;
    // Scan from (cursor_row - n + 1) to cursor_row
    const start_row: usize = if (cursor_row >= n - 1) cursor_row - (n - 1) else 0;
    var row_idx: usize = 0;
    while (row_idx < n and (start_row + row_idx) < rows) : (row_idx += 1) {
        const r = start_row + row_idx;
        var buf_pos: usize = 0;
        var col: usize = 0;
        while (col < cols and buf_pos < 255) : (col += 1) {
            const pin = screen.pages.pin(.{ .active = .{
                .x = @intCast(col),
                .y = @intCast(r),
            } });
            if (pin) |p| {
                const rac = p.rowAndCell();
                const cell = rac.cell;
                // Get first codepoint (char_data or grapheme)
                const cp: u21 = cell.codepoint();
                if (cp == 0) {
                    line_buf[count][buf_pos] = ' ';
                } else if (cp < 128) {
                    line_buf[count][buf_pos] = @intCast(cp);
                } else {
                    line_buf[count][buf_pos] = '?';
                }
            } else {
                line_buf[count][buf_pos] = ' ';
            }
            buf_pos += 1;
        }
        // Trim trailing spaces
        while (buf_pos > 0 and line_buf[count][buf_pos - 1] == ' ') : (buf_pos -= 1) {}
        lines[count] = line_buf[count][0..buf_pos];
        count += 1;
    }
    return count;
}
