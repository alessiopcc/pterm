/// Surface coordinator: wires TermIO + Renderer + FontGrid + Input (D-15 render thread).
///
/// Thread model:
///   Main thread:   GLFW events, input dispatch, OSC title updates
///   Render thread: GL context, frame rendering, buffer swap
///
/// Communication between threads uses atomics (lock-free for hot path).
const std = @import("std");
const glfw = @import("zglfw");
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
    debug_key_log: [64 * 1024]u8,
    debug_key_log_len: usize,

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

    // Frame counter for periodic diagnostics logging (D-17)
    frame_count: u64,


    // GL procedure table (initialized on render thread, stored here for lifetime)
    gl_procs: gl.ProcTable,

    pub fn init(allocator: std.mem.Allocator, config: Config, window: *Window, termio: *TermIO, options: SurfaceOptions) !Surface {
        // Create FontGrid from config
        const dpi_scale = window.getContentScale();
        const font_config = FontConfig{
            .family = config.font_family,
            .size_pt = config.font_size_pt,
            .dpi_scale = dpi_scale,
        };

        const font_grid = try allocator.create(FontGrid);
        errdefer allocator.destroy(font_grid);
        font_grid.* = try FontGrid.init(allocator, font_config);
        errdefer font_grid.deinit();

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
            .new_font_size = std.atomic.Value(u32).init(@intFromFloat(config.font_size_pt * 100.0)),
            .frame_count = 0,
            .perf_logging = options.perf_logging,
            .debug_keys = options.debug_keys,
            .debug_key_log = undefined,
            .debug_key_log_len = 0,
            .gl_procs = undefined,
        };
    }

    pub fn deinit(self: *Surface) void {
        if (self.debug_keys and self.debug_key_log_len > 0) {
            if (std.fs.cwd().createFile("termp_debug.log", .{})) |f| {
                defer f.close();
                _ = f.write(self.debug_key_log[0..self.debug_key_log_len]) catch 0;
            } else |_| {}
        }
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
        if (!self.gl_procs.init(glfw.getProcAddress)) {
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
            const padding = self.config.grid_padding;
            const uw: f32 = @as(f32, @floatFromInt(fb.width)) - 2.0 * padding;
            const uh: f32 = @as(f32, @floatFromInt(fb.height)) - 2.0 * padding;
            const cols: u16 = @intFromFloat(@min(500.0, @max(1.0, uw / metrics.cell_width)));
            const rows: u16 = @intFromFloat(@min(500.0, @max(1.0, uh / metrics.cell_height)));
            self.termio.resize(cols, rows) catch {};
        }

        // 5. Upload initial atlas texture
        {
            const atlas = self.font_grid.getAtlas();
            backend.uploadAtlas(atlas.getPixels(), atlas.getSize());
            self.font_grid.getAtlasMut().clearDirty();
        }

        // 6. Open perf log file if --perf flag (D-17: observable latency measurement)
        const perf_log = if (self.perf_logging)
            std.fs.cwd().createFile("termp_perf.log", .{}) catch null
        else
            null;

        // 7. Render loop
        while (!self.should_quit.load(.acquire)) {
            if (self.frame_requested.swap(false, .acq_rel)) {
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
                    const padding = self.config.grid_padding;
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

                // Lock terminal, build render state, unlock
                const snapshot = self.termio.lockTerminal();
                const metrics = self.font_grid.getMetrics();
                const fb = self.window.getFramebufferSize();
                var rs = render_state.buildRenderState(
                    self.frame_arena.allocator(),
                    snapshot,
                    self.font_grid,
                    fb.width,
                    fb.height,
                ) catch {
                    self.termio.unlockTerminal();
                    _ = self.frame_arena.reset(.retain_capacity);
                    continue;
                };
                self.termio.unlockTerminal();

                // Update cursor blink state
                self.updateCursorBlink();

                // Apply cursor visibility from blink state
                rs.cursor.visible = self.cursor_visible and self.focused;
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

                // Draw frame
                backend.drawFrame(&rs);

                // Periodic diagnostics: log frame timing to termp_perf.log (D-17)
                self.frame_count += 1;
                if (perf_log) |f| {
                    if (self.frame_count == 1 or self.frame_count % 60 == 0) {
                        const diag = backend.getDiagnostics();
                        var pbuf: [128]u8 = undefined;
                        const pline = std.fmt.bufPrint(&pbuf, "frame={d} frame_time={d}us draws={d} hits={d} misses={d}\n", .{
                            self.frame_count, diag.frame_time_us, diag.draw_calls,
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
    pub fn handleKeyInput(self: *Surface, key: glfw.Key, action: glfw.Action, mods: glfw.Mods) void {
        // Only handle press and repeat events
        if (action != .press and action != .repeat) return;

        // --debug-keys: buffer key events in memory, flush to termp_debug.log on exit
        if (self.debug_keys) {
            var tmp: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&tmp, "[key] code={d} action={d} ctrl={} shift={} alt={}\n", .{
                @intFromEnum(key), @intFromEnum(action), mods.control, mods.shift, mods.alt,
            }) catch "";
            if (line.len > 0 and self.debug_key_log_len + line.len <= self.debug_key_log.len) {
                @memcpy(self.debug_key_log[self.debug_key_log_len..][0..line.len], line);
                self.debug_key_log_len += line.len;
            }
        }

        // Font zoom: handle directly before encoder to catch all key combos.
        // On Windows, Ctrl++ is Ctrl+Shift+= (key=.equal, shift=true, ctrl=true).
        // Also handle numpad +/- and standalone Ctrl+= and Ctrl+-.
        if (mods.control) {
            var zoom_delta: ?f32 = null;
            var zoom_reset = false;

            switch (key) {
                .equal, .right_bracket, .kp_add => zoom_delta = 1.0, // Ctrl++ (layout-dependent)
                .minus, .slash, .kp_subtract => zoom_delta = -1.0, // Ctrl+- (layout-dependent)
                .zero, .kp_0 => zoom_reset = true, // Ctrl+0
                else => {},
            }

            if (zoom_delta != null or zoom_reset) {
                const current_size_fp = self.new_font_size.load(.acquire);
                const current_size: f32 = @as(f32, @floatFromInt(current_size_fp)) / 100.0;
                var new_size = if (zoom_reset) self.config.font_size_pt else current_size + zoom_delta.?;
                new_size = @max(6.0, @min(72.0, new_size));

                if (@as(u32, @intFromFloat(new_size * 100.0)) != current_size_fp) {
                    self.new_font_size.store(@intFromFloat(new_size * 100.0), .release);
                    self.pending_font_change.store(true, .release);
                    self.requestFrame();
                }
                return; // Don't pass to encoder
            }
        }

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
                // Read clipboard and paste to PTY
                if (glfw.getClipboardString(self.window.handle)) |clip| {
                    self.termio.writeInput(clip) catch {};
                    self.scheduler.markActive();
                    self.requestFrame();
                }
            },
            .handled_internally => {},
            .none => {},
        }
    }

    /// Handle character input from GLFW callback (main thread).
    pub fn handleCharInput(self: *Surface, codepoint: u32) void {
        var buf: [4]u8 = undefined;
        const cp: u21 = if (codepoint <= 0x10FFFF) @intCast(codepoint) else return;
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

    /// Handle framebuffer resize from GLFW callback (main thread, D-14).
    pub fn handleResize(self: *Surface, fb_width: u32, fb_height: u32) void {
        const metrics = self.font_grid.getMetrics();
        if (metrics.cell_width <= 0 or metrics.cell_height <= 0) return;

        // Compute new grid dimensions (D-14: snap to cell grid)
        const padding = self.config.grid_padding;
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
