/// Surface coordinator: wires TermIO + Renderer + FontGrid + Input (D-15 render thread).
///
/// Thread model:
///   Main thread:   GLFW events, input dispatch, OSC title updates
///   Render thread: GL context, frame rendering, buffer swap
///
/// Communication between threads uses atomics (lock-free for hot path).
const std = @import("std");
const glfw = @import("zglfw");

/// Wrapper around glfw.getProcAddress that aligns the returned pointer
/// for zigglgen compatibility (macOS returns `?*const anyopaque` but
/// zigglgen expects `?*align(4) const anyopaque`).
fn glProcLoader(name: [*:0]const u8) ?*align(4) const anyopaque {
    const ptr = glfw.getProcAddress(name) orelse return null;
    return @alignCast(ptr);
}
const gl = @import("gl");
const termio_mod = @import("termio");
const renderer_mod = @import("renderer");
const renderer_types = @import("renderer_types");
const font_grid_mod = @import("fontgrid");
const font_types = @import("font_types");
const window_mod = @import("window");
const input_encoder = @import("input_encoder");
const render_state = @import("render_state");
const opengl_backend_mod = @import("opengl_backend");
const config_mod = @import("config");
const keybindings = @import("keybindings");
const theme_mod = @import("theme");
const selection_mod = @import("selection");

const TermIO = termio_mod.TermIO;
const Renderer = renderer_mod.Renderer;
const FrameScheduler = renderer_types.FrameScheduler;
const CursorStyle = renderer_types.CursorStyle;
const palette = renderer_types.palette;
const FontGrid = font_grid_mod.FontGrid;
const FontMetrics = font_types.FontMetrics;
const FontConfig = font_types.FontConfig;
const Window = window_mod.Window;
const OpenGLBackend = opengl_backend_mod.OpenGLBackend;
const Config = config_mod.Config;
const RendererPalette = theme_mod.RendererPalette;

pub const SurfaceOptions = struct {
    perf_logging: bool = false,
    debug_keys: bool = false,
};

pub const Surface = struct {
    termio: *TermIO,
    renderer: ?Renderer,
    font_grid: *FontGrid,
    window: *Window,
    scheduler: FrameScheduler,
    config: Config,
    perf_logging: bool,
    debug_keys: bool,
    debug_key_file: ?std.fs.File,

    // Cursor blink state
    cursor_blink_timer: i128,
    cursor_visible: bool,
    focused: bool,

    // Per-frame arena allocator
    frame_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    // D-15: Render thread synchronization
    frame_requested: std.atomic.Value(bool),
    should_quit: std.atomic.Value(bool),
    render_thread: ?std.Thread,

    // D-14: Resize state communicated to render thread
    pending_resize: std.atomic.Value(bool),
    new_fb_width: std.atomic.Value(u32),
    new_fb_height: std.atomic.Value(u32),
    new_grid_cols: std.atomic.Value(u16),
    new_grid_rows: std.atomic.Value(u16),

    // D-13: OSC title state communicated to main thread
    pending_title_update: std.atomic.Value(bool),
    osc_title: [256]u8,
    osc_title_len: std.atomic.Value(u32),

    // Font resize state (atomic for thread-safe communication)
    pending_font_change: std.atomic.Value(bool),
    new_font_size: std.atomic.Value(u32), // stored as size_pt * 100 (fixed point)

    // D-30: Runtime color palette from config (bridges config hex -> renderer Color)
    renderer_palette: RendererPalette,

    // Frame counter for periodic diagnostics logging (D-17)
    frame_count: u64,

    // Text selection state (clipboard integration)
    selection: selection_mod.Selection,

    // Scroll offset for selection coordinate mapping (synced from PaneData)
    scroll_offset: u32,

    // Keybinding map for action dispatch
    keybinding_map: keybindings.KeybindingMap,
    last_mods: keybindings.Modifiers,

    // GL procedure table (initialized on render thread, stored here for lifetime)
    gl_procs: gl.ProcTable,

    pub fn init(allocator: std.mem.Allocator, config: Config, window: *Window, termio: *TermIO, options: SurfaceOptions) !Surface {
        // Create FontGrid from config
        const dpi_scale = window.getContentScale();
        const font_config = FontConfig{
            .family = config.font_family(),
            .size_pt = config.font_size_pt(),
            .dpi_scale = dpi_scale,
            .fallback = config.font_fallback(),
        };

        const font_grid = try allocator.create(FontGrid);
        errdefer allocator.destroy(font_grid);
        font_grid.* = try FontGrid.init(allocator, font_config);
        errdefer font_grid.deinit();

        // Build keybinding map from defaults (user overrides via config)
        // Convert config keybinding entries to UserBinding slice for buildMap
        const user_bindings: ?[]const keybindings.UserBinding = if (config.keybindings.len > 0)
            @ptrCast(config.keybindings)
        else
            null;
        var kb_map = try keybindings.buildMap(allocator, user_bindings);
        errdefer kb_map.deinit();

        return Surface{
            .termio = termio,
            .renderer = null, // Created on render thread after GL context acquired
            .font_grid = font_grid,
            .window = window,
            .scheduler = FrameScheduler{},
            .config = config,
            .cursor_blink_timer = std.time.nanoTimestamp(),
            .cursor_visible = true,
            .focused = true,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .frame_requested = std.atomic.Value(bool).init(true), // render first frame
            .should_quit = std.atomic.Value(bool).init(false),
            .render_thread = null,
            .pending_resize = std.atomic.Value(bool).init(false),
            .new_fb_width = std.atomic.Value(u32).init(0),
            .new_fb_height = std.atomic.Value(u32).init(0),
            .new_grid_cols = std.atomic.Value(u16).init(0),
            .new_grid_rows = std.atomic.Value(u16).init(0),
            .pending_title_update = std.atomic.Value(bool).init(false),
            .osc_title = [_]u8{0} ** 256,
            .osc_title_len = std.atomic.Value(u32).init(0),
            .pending_font_change = std.atomic.Value(bool).init(false),
            .new_font_size = std.atomic.Value(u32).init(@intFromFloat(config.font_size_pt() * 100.0)),
            .renderer_palette = theme_mod.buildRendererPaletteFromConfig(config.colors, config.theme),
            .frame_count = 0,
            .selection = selection_mod.Selection.init(),
            .scroll_offset = 0,
            .keybinding_map = kb_map,
            .last_mods = .{},
            .perf_logging = options.perf_logging,
            .debug_keys = options.debug_keys,
            .debug_key_file = if (options.debug_keys)
                std.fs.cwd().createFile("pterm_debug.log", .{}) catch null
            else
                null,
            .gl_procs = undefined,
        };
    }

    pub fn deinit(self: *Surface) void {
        if (self.debug_key_file) |f| f.close();
        self.keybinding_map.deinit();
        self.frame_arena.deinit();
        self.font_grid.deinit();
        self.allocator.destroy(self.font_grid);
    }

    /// Spawn the render thread (D-15). Called after GL context detached from main thread.
    pub fn startRenderThread(self: *Surface) !void {
        self.render_thread = try std.Thread.spawn(.{}, renderThreadMain, .{self});
    }

    /// Signal the render thread to stop and wait for it to finish.
    pub fn stopRenderThread(self: *Surface) void {
        self.should_quit.store(true, .release);
        if (self.render_thread) |thread| {
            thread.join();
        }
        self.render_thread = null;
    }

    /// Render thread entry point (D-15).
    /// Owns the GL context for its entire lifetime.
    fn renderThreadMain(self: *Surface) void {
        // 1. Acquire GL context on this thread
        self.window.makeContextCurrent();

        // 2. Initialize GL procedure table
        if (!self.gl_procs.init(glProcLoader)) {
            std.log.err("Failed to initialize OpenGL procedure table", .{});
            return;
        }
        gl.makeProcTableCurrent(&self.gl_procs);

        // 3. Initialize OpenGL backend (all GL resource creation on render thread)
        var backend = OpenGLBackend.init() catch |err| {
            std.log.err("Failed to initialize OpenGL backend: {}", .{err});
            return;
        };
        self.renderer = Renderer{ .opengl = &backend };

        // 4. Initial viewport setup — sync terminal to actual framebuffer size
        {
            const fb = self.window.getFramebufferSize();
            backend.resize(fb.width, fb.height);

            const metrics = self.font_grid.getMetrics();
            const padding = self.config.grid_padding();
            const uw: f32 = @as(f32, @floatFromInt(fb.width)) - 2.0 * padding;
            const uh: f32 = @as(f32, @floatFromInt(fb.height)) - 2.0 * padding;
            const cols: u16 = @intFromFloat(@min(500.0, @max(1.0, uw / metrics.cell_width)));
            const rows: u16 = @intFromFloat(@min(500.0, @max(1.0, uh / metrics.cell_height)));
            self.termio.resize(cols, rows) catch {};
        }

        // 5. Upload initial atlas textures (grayscale + color)
        {
            const atlas = self.font_grid.getAtlas();
            backend.uploadAtlas(atlas.getPixels(), atlas.getSize());
            self.font_grid.getAtlasMut().clearDirty();
            // Upload initial color atlas (empty but properly sized)
            backend.uploadColorAtlas(atlas.getColorPixels(), atlas.getColorSize());
            self.font_grid.getAtlasMut().clearColorDirty();
        }

        // 6. Open perf log file if --perf flag (D-17: observable latency measurement)
        const perf_log = if (self.perf_logging)
            std.fs.cwd().createFile("pterm_perf.log", .{}) catch null
        else
            null;

        // 7. Render loop with frame rate limiting (~60fps = 16.6ms minimum between frames)
        const min_frame_ns: i128 = 16_000_000; // 16ms
        var last_frame_ns: i128 = 0;

        while (!self.should_quit.load(.acquire)) {
            if (self.frame_requested.swap(false, .acq_rel)) {
                // Throttle: skip if less than 16ms since last frame
                const now = std.time.nanoTimestamp();
                if (now - last_frame_ns < min_frame_ns) {
                    // Re-request so we render on the next cycle
                    self.frame_requested.store(true, .release);
                    std.Thread.sleep(1_000_000); // 1ms
                    continue;
                }
                last_frame_ns = now;

                self.scheduler.markActive();

                // Handle pending font size change
                if (self.pending_font_change.swap(false, .acq_rel)) {
                    const new_size_fp = self.new_font_size.load(.acquire);
                    const new_size: f32 = @as(f32, @floatFromInt(new_size_fp)) / 100.0;
                    self.font_grid.setSize(new_size) catch |err| {
                        std.debug.print("[render] setSize({d:.1}) failed: {}\n", .{ new_size, err });
                    };
                    // Do NOT upload the cleared atlas here -- setSize() clears the atlas
                    // and buildRenderState below will rasterize new glyphs into it.
                    // The post-buildRenderState dirty check will upload the fully populated atlas.

                    // Recompute grid dimensions with new cell size and resize terminal
                    const new_metrics = self.font_grid.getMetrics();
                    const fb2 = self.window.getFramebufferSize();
                    const padding = self.config.grid_padding();
                    const uw: f32 = @as(f32, @floatFromInt(fb2.width)) - 2.0 * padding;
                    const uh: f32 = @as(f32, @floatFromInt(fb2.height)) - 2.0 * padding;
                    const new_cols: u16 = @intFromFloat(@min(500.0, @max(1.0, uw / new_metrics.cell_width)));
                    const new_rows: u16 = @intFromFloat(@min(500.0, @max(1.0, uh / new_metrics.cell_height)));
                    self.termio.resize(new_cols, new_rows) catch {};

                    // Update projection matrix -- font metrics changed so cell positions shift.
                    // Without this, the OpenGL viewport/projection stays stale and text
                    // renders at wrong positions or gets clipped after zoom.
                    backend.resize(@intCast(fb2.width), @intCast(fb2.height));
                }

                // Handle pending resize: GL viewport + terminal buffer + PTY
                if (self.pending_resize.swap(false, .acq_rel)) {
                    const w = self.new_fb_width.load(.acquire);
                    const h = self.new_fb_height.load(.acquire);
                    const cols = self.new_grid_cols.load(.acquire);
                    const rows = self.new_grid_rows.load(.acquire);
                    backend.resize(w, h);
                    // Resize terminal and PTY while we're about to hold the mutex anyway
                    self.termio.resize(cols, rows) catch {};
                }

                // Pass 1: snapshot cell data under mutex (fast copy, no glyph lookups)
                const snapshot = self.termio.lockTerminal();
                const snap = render_state.snapshotCells(
                    self.frame_arena.allocator(),
                    snapshot,
                    &self.renderer_palette,
                    0, // Surface render path has no scrollback viewport
                ) catch {
                    self.termio.unlockTerminal();
                    _ = self.frame_arena.reset(.retain_capacity);
                    continue;
                };
                self.termio.unlockTerminal();

                // Pass 2: build CellInstances with glyph lookups (no mutex held)
                const metrics = self.font_grid.getMetrics();
                const fb = self.window.getFramebufferSize();
                var rs = render_state.buildFromSnapshot(
                    self.frame_arena.allocator(),
                    snap,
                    self.font_grid,
                    fb.width,
                    fb.height,
                    &self.renderer_palette,
                    null, // no per-pane cache in single-surface mode
                ) catch {
                    _ = self.frame_arena.reset(.retain_capacity);
                    continue;
                };

                // Update cursor blink state
                self.updateCursorBlink();

                // Apply cursor visibility: honor DECTCEM (app-requested hide),
                // blink state, and focus state.
                rs.cursor.visible = snap.cursor_visible and self.cursor_visible and self.focused;
                if (!self.focused) {
                    // Show hollow cursor when unfocused -- use ibeam as visual indicator
                    // (actual hollow rendering is backend-dependent; this signals "unfocused")
                    rs.cursor.style = .ibeam;
                }

                // Update cell dimensions in render state from current font metrics
                rs.cell_width = metrics.cell_width;
                rs.cell_height = metrics.cell_height;

                // Upload atlas if dirty (new glyphs rasterized)
                if (self.font_grid.getAtlas().isDirty()) {
                    const atlas = self.font_grid.getAtlas();
                    backend.uploadAtlas(atlas.getPixels(), atlas.getSize());
                    self.font_grid.getAtlasMut().clearDirty();
                }

                // Upload color atlas if dirty (new emoji/color glyphs rasterized)
                if (self.font_grid.getAtlas().isColorDirty()) {
                    const atlas = self.font_grid.getAtlas();
                    backend.uploadColorAtlas(atlas.getColorPixels(), atlas.getColorSize());
                    self.font_grid.getAtlasMut().clearColorDirty();
                }

                // Draw frame with config-driven background color
                backend.drawFrame(&rs, self.renderer_palette.default_bg);

                // Periodic diagnostics: log frame timing to pterm_perf.log (D-17)
                self.frame_count += 1;
                if (perf_log) |f| {
                    if (self.frame_count == 1 or self.frame_count % 60 == 0) {
                        const diag = backend.getDiagnostics();
                        var pbuf: [128]u8 = undefined;
                        const pline = std.fmt.bufPrint(&pbuf, "frame={d} frame_time={d}us draws={d} hits={d} misses={d}\n", .{
                            self.frame_count,      diag.frame_time_us,      diag.draw_calls,
                            diag.glyph_cache_hits, diag.glyph_cache_misses,
                        }) catch "";
                        if (pline.len > 0) _ = f.write(pline) catch 0;
                    }
                }

                self.window.swapBuffers();

                // Reset frame arena
                _ = self.frame_arena.reset(.retain_capacity);
            } else {
                // No frame requested -- sleep briefly to avoid busy-wait
                std.Thread.sleep(1_000_000); // 1ms
            }
        }

        // 8. Cleanup on render thread
        if (perf_log) |f| f.close();
        backend.deinit();
        self.renderer = null;
        gl.makeProcTableCurrent(null);
        Window.detachContext();
    }

    /// Request a new frame render (called from main thread).
    pub fn requestFrame(self: *Surface) void {
        self.frame_requested.store(true, .release);
    }

    /// Apply pending OSC title update (called on main thread).
    pub fn applyPendingTitle(self: *Surface) void {
        if (self.pending_title_update.swap(false, .acq_rel)) {
            const len = self.osc_title_len.load(.acquire);
            if (len > 0 and len < self.osc_title.len) {
                // Null-terminate and set window title
                self.osc_title[len] = 0;
                const title: [:0]const u8 = self.osc_title[0..len :0];
                self.window.setTitle(title);
            }
        }
    }

    /// Handle key input from GLFW callback (main thread).
    /// Check keybinding map for special keys before VT encoding.
    pub fn handleKeyInput(self: *Surface, key: glfw.Key, action: glfw.Action, mods: glfw.Mods) void {
        // Only handle press and repeat events
        if (action != .press and action != .repeat) return;

        // Store modifier state for charCallback (D-21: logical key detection)
        self.last_mods = glfwModsToModifiers(mods);

        // --debug-keys: write each keystroke to pterm_debug.log (file opened once at init)
        if (self.debug_key_file) |f| {
            var tmp: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&tmp, "[key] code={d} action={d} ctrl={} shift={} alt={}\n", .{
                @intFromEnum(key), @intFromEnum(action), mods.control, mods.shift, mods.alt,
            }) catch "";
            if (line.len > 0) _ = f.write(line) catch 0;
        }

        // Step A: Check for special (non-printable) keys via keybinding map
        if (mapGlfwKeyToSpecial(key)) |special| {
            const combo = keybindings.KeyCombo{
                .key = .{ .special = special },
                .mods = glfwModsToModifiers(mods),
            };

            // Step B: Reserved clipboard check (special keys won't match, but uniform)
            if (keybindings.isReservedClipboardKey(combo)) {
                self.handleClipboardAction(combo);
                return;
            }

            // Step C: Keybinding map lookup
            if (self.keybinding_map.get(combo)) |bound_action| {
                self.dispatchAction(bound_action);
                return;
            }
        }

        // Font zoom via GLFW key codes (charCallback doesn't fire with Ctrl held).
        // These are the physical key fallbacks — keybinding map handles logical combos.
        if (mods.control and !mods.alt and !mods.super) {
            const zoom_action: ?keybindings.Action = switch (key) {
                .equal, .right_bracket, .kp_add => .increase_font_size,
                .minus, .slash, .kp_subtract => .decrease_font_size,
                .zero, .kp_0 => .reset_font_size,
                else => null,
            };
            if (zoom_action) |za| {
                self.dispatchAction(za);
                return;
            }
        }

        // Step D: Fall through to VT encoding for terminal input
        var buf: [16]u8 = undefined;
        const result = input_encoder.encodeKey(key, mods, &buf);

        switch (result) {
            .bytes => |bytes| {
                self.termio.writeInput(bytes) catch {};
                self.scheduler.markActive();
                self.requestFrame();
                // Reset cursor blink on input
                self.cursor_blink_timer = std.time.nanoTimestamp();
                self.cursor_visible = true;
            },
            .paste_clipboard => {
                self.pasteFromClipboard();
            },
            .handled_internally => {},
            .none => {},
        }
    }

    /// Handle character input from GLFW callback (main thread).
    /// Combines charCallback codepoint with stored modifier state for logical key lookup (D-21).
    pub fn handleCharInput(self: *Surface, codepoint: u32) void {
        const cp: u21 = if (codepoint <= 0x10FFFF) @intCast(codepoint) else return;

        // Build KeyCombo from logical character + stored modifier state (D-21)
        const combo = keybindings.KeyCombo{
            .key = .{ .char = if (cp >= 'A' and cp <= 'Z') cp + 32 else cp },
            .mods = self.last_mods,
        };

        // Check reserved clipboard keys first (D-19)
        if (keybindings.isReservedClipboardKey(combo)) {
            self.handleClipboardAction(combo);
            return;
        }

        // Check keybinding map
        if (self.keybinding_map.get(combo)) |bound_action| {
            self.dispatchAction(bound_action);
            return;
        }

        // Fall through: write character to terminal
        var buf: [4]u8 = undefined;
        const bytes = input_encoder.encodeChar(cp, &buf);
        if (bytes.len > 0) {
            self.termio.writeInput(bytes) catch {};
            self.scheduler.markActive();
            self.requestFrame();
            // Reset cursor blink on input
            self.cursor_blink_timer = std.time.nanoTimestamp();
            self.cursor_visible = true;
        }
    }

    /// Dispatch a keybinding action.
    fn dispatchAction(self: *Surface, action: keybindings.Action) void {
        switch (action) {
            .copy => self.copySelection(self.scroll_offset),
            .paste => self.pasteFromClipboard(),
            .increase_font_size => self.changeFontSize(1.0),
            .decrease_font_size => self.changeFontSize(-1.0),
            .reset_font_size => self.resetFontSize(),
            .scroll_page_up => self.scrollPageUp(),
            .scroll_page_down => self.scrollPageDown(),
            .new_tab, .close_tab, .next_tab, .prev_tab => {},
            .split_horizontal, .split_vertical => {},
            .focus_next_pane, .focus_prev_pane => {},
            .close_pane => {},
            .focus_pane_up, .focus_pane_down, .focus_pane_left, .focus_pane_right => {},
            .resize_pane_up, .resize_pane_down, .resize_pane_left, .resize_pane_right => {},
            .zoom_pane => {},
            .equalize_panes => {},
            .swap_pane_up, .swap_pane_down, .swap_pane_left, .swap_pane_right => {},
            .rotate_split => {},
            .break_out_pane => {},
            .move_tab_left, .move_tab_right => {},
            .goto_tab_1, .goto_tab_2, .goto_tab_3, .goto_tab_4, .goto_tab_5 => {},
            .goto_tab_6, .goto_tab_7, .goto_tab_8, .goto_tab_9, .goto_tab_last => {},
            .open_layout_picker => {},
            .scroll_to_top, .scroll_to_bottom => {},
            .search => {},
            .toggle_agent_tab => {}, // handled in App.dispatchAction
            .change_shell => {}, // handled in App.dispatchAction
            .none => {},
        }
    }

    /// Handle clipboard action for reserved keys (D-19).
    /// D-17: Smart Ctrl+C -- copies selection when active, sends SIGINT (0x03) when not.
    pub fn handleClipboardAction(self: *Surface, combo: keybindings.KeyCombo) void {
        const is_c = switch (combo.key) {
            .char => |c| c == 'c',
            .special => false,
        };
        if (is_c) {
            // D-17: Smart Ctrl+C -- copy if selection active, send SIGINT if not
            if (self.selection.range != null) {
                self.copySelection(self.scroll_offset);
                // selection.clear() already called inside copySelection
            } else {
                // Send Ctrl+C (0x03 ETX) to terminal as SIGINT
                self.termio.writeInput("\x03") catch {};
            }
        } else {
            self.pasteFromClipboard();
        }
    }

    /// Copy current selection to clipboard (D-15: clipboard integration).
    /// Extracts text from terminal screen buffer via Selection.getSelectedText
    /// and sets the GLFW system clipboard. Clears selection after copy.
    pub fn copySelection(self: *Surface, scroll_offset: u32) void {
        const range = self.selection.range orelse return;

        // Lock terminal to access screen data
        const snapshot = self.termio.lockTerminal();

        const screens = @constCast(snapshot).getScreens();
        const screen = screens.active;
        const cols: u16 = @intCast(screen.pages.cols);
        const rows: u16 = @intCast(screen.pages.rows);

        // Compute screen-coordinate base row for scrollback viewport
        const total_rows = screen.pages.total_rows;
        const active_rows = screen.pages.rows;
        const history_rows: u32 = if (total_rows > active_rows) @intCast(total_rows - active_rows) else 0;
        const clamped_offset = @min(scroll_offset, history_rows);
        const viewport_base: u32 = history_rows - clamped_offset;

        // Build UTF-8 screen lines from terminal cells
        const alloc = std.heap.page_allocator;
        const screen_rows: usize = @min(@as(usize, rows), 500);
        const line_ptrs = alloc.alloc([]const u8, screen_rows) catch {
            self.termio.unlockTerminal();
            return;
        };

        // Flat buffer for UTF-8 bytes: each cell can produce up to 4 UTF-8 bytes
        const bytes_per_row: usize = @as(usize, cols) * 4;
        const flat_buf = alloc.alloc(u8, screen_rows * bytes_per_row) catch {
            alloc.free(line_ptrs);
            self.termio.unlockTerminal();
            return;
        };

        var row: u16 = 0;
        while (row < screen_rows) : (row += 1) {
            const row_offset = @as(usize, row) * bytes_per_row;
            var byte_len: usize = 0;
            var col: u16 = 0;
            while (col < cols) : (col += 1) {
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
                    // No cell at this position, emit space
                    flat_buf[row_offset + byte_len] = ' ';
                    byte_len += 1;
                    continue;
                };
                const rac = pin_val.rowAndCell();
                const cp: u21 = rac.cell.codepoint();
                if (cp == 0) {
                    flat_buf[row_offset + byte_len] = ' ';
                    byte_len += 1;
                } else {
                    // Encode codepoint as UTF-8
                    const dest = flat_buf[row_offset + byte_len .. row_offset + bytes_per_row];
                    const enc_len = std.unicode.utf8Encode(cp, dest) catch 0;
                    if (enc_len > 0) {
                        byte_len += enc_len;
                    } else {
                        flat_buf[row_offset + byte_len] = ' ';
                        byte_len += 1;
                    }
                }
            }
            line_ptrs[row] = flat_buf[row_offset .. row_offset + byte_len];
        }

        self.termio.unlockTerminal();

        // Extract selected text using Selection API
        const selected_text = selection_mod.Selection.getSelectedText(
            range,
            line_ptrs,
            alloc,
        ) catch return;
        defer alloc.free(selected_text);

        // Set GLFW clipboard (needs null-terminated string)
        if (selected_text.len > 0) {
            const clipboard_str = alloc.alloc(u8, selected_text.len + 1) catch return;
            defer alloc.free(clipboard_str);
            @memcpy(clipboard_str[0..selected_text.len], selected_text);
            clipboard_str[selected_text.len] = 0;
            const sentinel_str: [:0]const u8 = clipboard_str[0..selected_text.len :0];
            glfw.setClipboardString(self.window.handle, sentinel_str);
        }

        // Clean up screen line buffers
        alloc.free(flat_buf);
        alloc.free(line_ptrs);

        // Clear selection after successful copy
        self.selection.clear();
    }

    /// Paste clipboard contents to terminal PTY.
    /// When bracketed paste mode (DEC 2004) is active, wraps the pasted
    /// text in \e[200~ ... \e[201~ so the shell treats it as a single
    /// paste event rather than executing each line individually.
    pub fn pasteFromClipboard(self: *Surface) void {
        if (glfw.getClipboardString(self.window.handle)) |clip| {
            const snapshot = self.termio.lockTerminal();
            const bracketed = @constCast(snapshot).isBracketedPasteEnabled();
            self.termio.unlockTerminal();

            if (bracketed) {
                self.termio.writeInput("\x1b[200~") catch {};
            }
            self.termio.writeInput(clip) catch {};
            if (bracketed) {
                self.termio.writeInput("\x1b[201~") catch {};
            }
            self.scheduler.markActive();
            self.requestFrame();
        }
    }

    /// Change font size by delta points.
    fn changeFontSize(self: *Surface, delta: f32) void {
        const current_size_fp = self.new_font_size.load(.acquire);
        const current_size: f32 = @as(f32, @floatFromInt(current_size_fp)) / 100.0;
        var new_size = current_size + delta;
        new_size = @max(6.0, @min(72.0, new_size));

        if (@as(u32, @intFromFloat(new_size * 100.0)) != current_size_fp) {
            self.new_font_size.store(@intFromFloat(new_size * 100.0), .release);
            self.pending_font_change.store(true, .release);
            self.requestFrame();
        }
    }

    /// Reset font size to config default.
    fn resetFontSize(self: *Surface) void {
        const default_fp: u32 = @intFromFloat(self.config.font_size_pt() * 100.0);
        if (self.new_font_size.load(.acquire) == default_fp) return; // already at default
        self.new_font_size.store(default_fp, .release);
        self.pending_font_change.store(true, .release);
        self.requestFrame();
    }

    /// Scroll up one page.
    pub fn scrollPageUp(self: *Surface) void {
        // TODO: Implement terminal viewport scrolling when scrollback is wired
        self.requestFrame();
    }

    /// Scroll down one page.
    pub fn scrollPageDown(self: *Surface) void {
        // TODO: Implement terminal viewport scrolling when scrollback is wired
        self.requestFrame();
    }

    /// Handle framebuffer resize from GLFW callback (main thread, D-14).
    pub fn handleResize(self: *Surface, fb_width: u32, fb_height: u32) void {
        const metrics = self.font_grid.getMetrics();
        if (metrics.cell_width <= 0 or metrics.cell_height <= 0) return;

        // Compute new grid dimensions (D-14: snap to cell grid)
        const padding = self.config.grid_padding();
        const usable_w: f32 = @as(f32, @floatFromInt(fb_width)) - 2.0 * padding;
        const usable_h: f32 = @as(f32, @floatFromInt(fb_height)) - 2.0 * padding;
        const raw_cols = @max(1.0, usable_w / metrics.cell_width);
        const raw_rows = @max(1.0, usable_h / metrics.cell_height);
        const new_cols: u16 = @intFromFloat(@min(500.0, raw_cols));
        const new_rows: u16 = @intFromFloat(@min(500.0, raw_rows));

        // Store resize dimensions for render thread — it will resize both
        // the GL viewport and the terminal buffer while holding the mutex.
        // We do NOT call termio.resize() here because it would block the main
        // thread waiting on the mutex (render thread may hold it), freezing GLFW events.
        self.new_fb_width.store(fb_width, .release);
        self.new_fb_height.store(fb_height, .release);
        self.new_grid_cols.store(new_cols, .release);
        self.new_grid_rows.store(new_rows, .release);
        self.pending_resize.store(true, .release);
        self.requestFrame();
    }

    /// Handle focus change from GLFW callback (main thread).
    pub fn handleFocusChange(self: *Surface, focused: bool) void {
        self.focused = focused;
        if (focused) {
            self.cursor_blink_timer = std.time.nanoTimestamp();
            self.cursor_visible = true;
        }
        self.requestFrame();
    }

    /// Handle scroll from GLFW callback (main thread).
    pub fn handleScroll(self: *Surface, y_offset: f64) void {
        // Each scroll unit = 3 lines
        const lines: i32 = @intFromFloat(y_offset * 3.0);
        _ = lines;
        // TODO: Implement terminal viewport scrolling when scrollback is wired
        self.requestFrame();
    }

    /// Apply a new config after hot-reload (D-35).
    /// Guards restart-required fields per D-16.
    /// Currently guarded: font family (atlas rebuild).
    /// Structural guards for: keybindings (mid-session conflict avoidance),
    /// PTY/shell settings (requires process restart).
    /// Keybinding overrides are not yet stored on Config (built at init from
    /// TOML [keybindings] section); guard activates when Config gains that field.
    pub fn applyConfig(self: *Surface, new_config: Config) void {
        const old = self.config;

        // D-16: Font family changes require restart (atlas rebuild)
        const old_family = old.font_family() orelse "";
        const new_family = new_config.font_family() orelse "";
        if (!std.mem.eql(u8, old_family, new_family)) {
            std.log.warn("Font family change requires restart to apply (atlas rebuild). Skipping.", .{});
        }

        // D-16: Keybinding changes require restart.
        // keybinding_map is built once at init and never rebuilt on hot-reload.
        // When Config gains a keybindings field, compare here and warn on change.
        // For now, keybinding config changes on disk have no effect until restart,
        // which is the correct D-16 behavior — this comment documents the intent.

        // D-16: Shell/PTY settings require restart
        // (Config currently uses hardcoded shell; guard is for future TOML shell config)

        // Apply config but preserve restart-required fields from old config
        var effective = new_config;
        effective.font.family = old.font.family; // keep old font family

        self.config = effective;

        // Live-reloadable per D-15: colors — rebuild renderer palette from new config
        self.renderer_palette = theme_mod.buildRendererPaletteFromConfig(effective.colors, effective.theme);

        // Font size (live-reloadable, unlike font family)
        if (old.font_size_pt() != new_config.font_size_pt()) {
            const new_size_fp: u32 = @intFromFloat(new_config.font_size_pt() * 100.0);
            self.new_font_size.store(new_size_fp, .release);
            self.pending_font_change.store(true, .release);
        }

        self.requestFrame();
    }

    /// Update cursor blink state (called on render thread, ~530ms interval per UI-SPEC).
    fn updateCursorBlink(self: *Surface) void {
        if (!self.focused) {
            self.cursor_visible = true; // Always show hollow cursor when unfocused
            return;
        }

        const now = std.time.nanoTimestamp();
        const elapsed = now - self.cursor_blink_timer;
        const blink_interval: i128 = 530_000_000; // 530ms in nanoseconds

        if (elapsed >= blink_interval) {
            self.cursor_visible = !self.cursor_visible;
            self.cursor_blink_timer = now;
            // Request another frame for next blink toggle
            self.requestFrame();
        }
    }

    // -- Keybinding helpers --

    /// Convert GLFW modifier flags to keybinding Modifiers.
    fn glfwModsToModifiers(mods: glfw.Mods) keybindings.Modifiers {
        return .{
            .ctrl = mods.control,
            .shift = mods.shift,
            .alt = mods.alt,
            .super = mods.super,
        };
    }

    /// Map a GLFW key to a SpecialKey, or null if the key is printable.
    pub fn mapGlfwKeyToSpecial(key: glfw.Key) ?keybindings.SpecialKey {
        return switch (key) {
            .insert => .insert,
            .delete => .delete,
            .home => .home,
            .end => .end,
            .page_up => .page_up,
            .page_down => .page_down,
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
            .tab => .tab,
            .enter => .enter,
            .escape => .escape,
            .backspace => .backspace,
            .F1 => .f1,
            .F2 => .f2,
            .F3 => .f3,
            .F4 => .f4,
            .F5 => .f5,
            .F6 => .f6,
            .F7 => .f7,
            .F8 => .f8,
            .F9 => .f9,
            .F10 => .f10,
            .F11 => .f11,
            .F12 => .f12,
            else => null,
        };
    }

    // -- Static GLFW callbacks that route to Surface via user pointer --

    pub fn keyCallback(handle: *glfw.Window, key: glfw.Key, _: c_int, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
        const surface = Window.getUserPointer(Surface, handle) orelse return;
        surface.handleKeyInput(key, action, mods);
    }

    pub fn charCallback(handle: *glfw.Window, codepoint: u32) callconv(.c) void {
        const surface = Window.getUserPointer(Surface, handle) orelse return;
        surface.handleCharInput(codepoint);
    }

    pub fn framebufferSizeCallback(handle: *glfw.Window, width: c_int, height: c_int) callconv(.c) void {
        const surface = Window.getUserPointer(Surface, handle) orelse return;
        surface.handleResize(@intCast(width), @intCast(height));
    }

    pub fn focusCallback(handle: *glfw.Window, focused: glfw.Bool) callconv(.c) void {
        const surface = Window.getUserPointer(Surface, handle) orelse return;
        surface.handleFocusChange(@intFromEnum(focused) != 0);
    }

    pub fn scrollCallback(handle: *glfw.Window, _: f64, yoffset: f64) callconv(.c) void {
        const surface = Window.getUserPointer(Surface, handle) orelse return;
        surface.handleScroll(yoffset);
    }
};
