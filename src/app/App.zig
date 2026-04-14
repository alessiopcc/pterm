/// Application lifecycle: init, run, deinit.
///
/// Multi-pane architecture:
/// App owns TabManager, PaneRegistry, Compositor, and shared FontGrid.
/// Each pane has its own TermIO + PTY. The render thread uses Compositor
/// to iterate visible panes and render each in its own viewport/scissor rect.
///
/// Thread model (D-15):
///   Main thread:   GLFW events, input dispatch, OSC title updates, pane operations
///   Render thread: GL context, Compositor.renderFrame, buffer swap
///
/// Input routing:
///   GLFW user pointer -> *App
///   Key/char events -> focused pane's Surface (VT encoding + keybinding dispatch)
///   Mouse clicks -> hit-test tab bar / pane borders / pane area
const builtin = @import("builtin");
const std = @import("std");
const glfw = @import("zglfw");
const gl = @import("gl");
const Config = @import("config").Config;
const Surface = @import("surface").Surface;
const termio_mod = @import("termio");
const pty_mod = @import("pty");
const shell_mod = @import("shell");
const window_mod = @import("window");
const fontgrid_mod = @import("fontgrid");
const font_types = @import("font_types");
const observer_mod = @import("observer");
const renderer_types = @import("renderer_types");
const watcher_mod = @import("watcher");
const FileWatcher = watcher_mod.FileWatcher;
const cli_mod = @import("cli");
const layout_mod = @import("layout");
const opengl_backend_mod = @import("opengl_backend");
const render_state = @import("render_state");
const theme_mod = @import("theme");
const keybindings = @import("keybindings");
const callbacks = @import("callbacks.zig");
const utils = @import("utils.zig");

const TermIO = termio_mod.TermIO;
const TermIOConfig = termio_mod.TermIOConfig;
const Pty = pty_mod.Pty;
const Window = window_mod.Window;
const FontGrid = fontgrid_mod.FontGrid;
const FontMetrics = font_types.FontMetrics;
const FontConfig = font_types.FontConfig;
const OpenGLBackend = opengl_backend_mod.OpenGLBackend;
const RendererPalette = theme_mod.RendererPalette;
const layout_types = @import("layout_types");
const RendererRect = layout_types.Rect;

const search_mod = @import("search");
const SearchState = search_mod.SearchState.SearchState;
const SearchOverlay = search_mod.SearchOverlay.SearchOverlay;
const SearchColors = search_mod.SearchOverlay.SearchColors;
const matcher = search_mod.matcher;

const url_mod = @import("url");
const UrlDetector = url_mod.UrlDetector;
const UrlState = url_mod.UrlState.UrlState;
const open_url = @import("open_url");

const bell_state_mod = @import("bell_state");
const BellState = bell_state_mod.BellState;
const system_beep = @import("system_beep");

const AgentState = @import("agent_state").AgentState;
const AgentDetector = @import("agent_detector").AgentDetector;
const IdleTracker = @import("idle_tracker").IdleTracker;
const notification_manager_mod = @import("notification_manager");
const NotificationManager = notification_manager_mod.NotificationManager;
const status_bar_mod = @import("status_bar_renderer");
const StatusBarRenderer = status_bar_mod.StatusBarRenderer;

const TabManager = layout_mod.TabManager.TabManager;
const Tab = layout_mod.Tab.Tab;
const PaneTree = layout_mod.PaneTree;
const PaneNode = PaneTree.PaneNode;
const tree_ops = layout_mod.tree_ops;
const Rect = layout_mod.Rect.Rect;
const Compositor = layout_mod.Compositor.Compositor;
const PaneRegistry = layout_mod.Compositor.PaneRegistry;
const PaneState = layout_mod.Compositor.PaneState;
const TabBarRenderer = layout_mod.TabBarRenderer.TabBarRenderer;
const LayoutPreset = layout_mod.LayoutPreset;
const PresetPicker = layout_mod.PresetPicker.PresetPicker;
const ShellPicker = layout_mod.ShellPicker.ShellPicker;
const ShellPickerColors = layout_mod.ShellPicker.ShellPickerColors;
const ShellInfo = shell_mod.ShellInfo;

pub const AppOptions = struct {
    perf_logging: bool = false,
    debug_keys: bool = false,
    layout_name: ?[]const u8 = null,
};

/// Per-pane data: holds the TermIO, PTY, and Surface state for one terminal pane.
pub const PaneData = struct {
    surface: Surface,
    termio: TermIO,
    pty: Pty,
    pane_id: u32,
    tab_index: u32,

    /// CWD tracked via OSC 7 or inherited from parent pane (D-03, D-23).
    cwd: [256]u8,
    cwd_len: std.atomic.Value(u32),

    /// Process name for tab title (e.g., "bash", "zsh", "powershell").
    process_name: [64]u8,
    process_name_len: u32,

    /// Screen change callback pointer for this pane (static per-pane).
    screen_change_fn: ?*const fn () void,

    /// Per-pane row cache for dirty-row rendering optimization.
    row_cache: render_state.RowCache,

    /// Per-pane search state (independent per pane).
    search_state: SearchState = .{},

    /// Per-pane URL hover state (underline + hand cursor on hover).
    url_state: UrlState = .{},

    /// Per-pane bell state (per-pane flash + badge).
    bell_state: BellState = .{},

    /// Per-pane agent monitoring state (independent per pane).
    agent_state: AgentState = .{},

    /// Per-pane idle tracker (optional idle detection).
    idle_tracker: IdleTracker = IdleTracker.init(5, false),

    /// Flag set by observer callback, consumed by render snapshot for debounced scan.
    needs_agent_scan: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Suppress agent state transitions during resize (PTY redraws cause false positives).
    suppress_agent_output: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Scrollback viewport offset: 0 = live (bottom), >0 = scrolled up N lines into history.
    scroll_offset: u32 = 0,
};

// Static state vars are in callbacks.zig (callbacks.g_reload_app, callbacks.g_screen_change_app).

pub const App = struct {
    window: Window,
    tab_manager: TabManager,
    pane_registry: PaneRegistry,
    compositor: Compositor,
    font_grid: *FontGrid,
    allocator: std.mem.Allocator,
    config: Config,
    config_path: ?[]const u8,
    config_watcher: ?FileWatcher,

    // Pane data storage (heap-allocated, referenced from PaneRegistry)
    pane_data: std.AutoHashMapUnmanaged(u32, *PaneData),

    // Render thread state
    frame_requested: std.atomic.Value(bool),
    should_quit: std.atomic.Value(bool),
    render_thread: ?std.Thread,
    gl_procs: gl.ProcTable,

    // Resize state (main thread -> render thread)
    pending_resize: std.atomic.Value(bool),
    new_fb_width: std.atomic.Value(u32),
    new_fb_height: std.atomic.Value(u32),

    // Font change state (main thread -> render thread)
    pending_font_change: std.atomic.Value(bool),
    new_font_size: std.atomic.Value(u32),

    // Runtime color palette
    renderer_palette: RendererPalette,

    // Keybinding map (shared across all panes)
    keybinding_map: keybindings.KeybindingMap,
    last_mods: keybindings.Modifiers,

    // Diagnostics
    perf_logging: bool,
    debug_keys: bool,
    debug_key_file: ?std.fs.File,
    frame_count: u64,

    // Cursor blink state (global, applies to focused pane)
    cursor_blink_timer: i128,
    cursor_visible: bool,
    focused: bool,

    // Frame arena for per-frame allocations
    frame_arena: std.heap.ArenaAllocator,

    /// Shared agent detector (one per app, patterns are global per D-03).
    agent_detector: ?AgentDetector = null,

    /// Notification manager: per-pane cooldown, focus suppression, OS notification dispatch.
    notification_manager: NotificationManager,

    // Layout preset picker overlay
    preset_picker: PresetPicker,

    // Shell picker overlay
    shell_picker: ShellPicker,
    available_shells: ?[]ShellInfo = null,
    available_shell_display: [16][128]u8 = undefined,
    available_shell_display_slices: [16][]const u8 = undefined,

    // Pending --layout activation (from CLI flag)
    pending_layout_name: ?[]const u8,

    // Pending pane operations (main thread -> render thread, mutex-protected)
    pending_ops: std.ArrayListUnmanaged(PaneOp),
    pending_ops_mutex: std.Thread.Mutex,

    /// Protects pane_data and tab_manager from concurrent access
    /// between the main thread (input/close) and render thread.
    pane_mutex: std.Thread.Mutex,

    // Border drag state (mouse resize)
    border_drag_active: bool,
    border_drag_branch: ?*PaneNode,
    border_drag_start_pos: f64,
    border_drag_start_ratio: f32,
    border_drag_is_vertical: bool,

    // Window drag state (frameless window drag via tab bar)
    window_drag_active: bool,
    window_drag_moved: bool,
    window_drag_tab_hit: ?usize, // Tab index if drag started on a tab (click-to-switch on release)
    window_drag_screen_x: i32,
    window_drag_screen_y: i32,

    // Title bar double-click detection (maximize/restore)
    titlebar_last_click_time: i128,

    // Window control hover state (0=none, 1=minimize, 2=maximize, 3=close)
    hovered_control: u8,

    // Suppress activity for N frames after resize (async redraws cause false positives)
    suppress_activity_frames: std.atomic.Value(u32),

    // URL hover cursor (pointing hand on URL hover)
    hand_cursor: ?*glfw.Cursor,

    // Text selection drag state (mouse click-drag to select text)
    text_select_active: bool,
    text_select_pane_id: ?u32,
    text_select_click_count: u8, // 1=normal, 2=word, 3=line
    text_select_last_click_time: i128,
    text_select_pending: bool, // true = click registered, waiting for drag to start selection
    text_select_start_row: u32,
    text_select_start_col: u16,

    // Window edge resize state (frameless window)
    window_resize_active: bool,
    window_resize_edge: WindowEdge,
    window_resize_start_screen_x: i32,
    window_resize_start_screen_y: i32,
    window_resize_start_win_x: i32,
    window_resize_start_win_y: i32,
    window_resize_start_win_w: u32,
    window_resize_start_win_h: u32,

    pub const WindowEdge = packed struct {
        left: bool = false,
        right: bool = false,
        top: bool = false,
        bottom: bool = false,
    };

    pub const PaneOp = union(enum) {
        split: struct { direction: PaneTree.SplitDirection },
        close_pane: u32,
        new_tab: void,
        close_tab: usize,
        switch_tab: usize,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config, options: AppOptions) !App {
        // Create font grid with dpi_scale=1.0 initially to get base metrics for window sizing.
        // After window creation, we re-initialize with the actual DPI scale.
        const font_config = FontConfig{
            .family = config.font_family(),
            .size_pt = config.font_size_pt(),
            .dpi_scale = 1.0,
            .fallback = config.font_fallback(),
        };

        const font_grid = try allocator.create(FontGrid);
        errdefer allocator.destroy(font_grid);
        font_grid.* = try FontGrid.init(allocator, font_config);
        errdefer font_grid.deinit();

        // Create TabManager and first tab
        var tab_manager = TabManager.init(allocator);
        errdefer tab_manager.deinit();
        _ = try tab_manager.createTab();

        // Create Window (pane TermIO/PTY created later in start())
        var metrics = font_grid.getMetrics();
        // Add chrome height (title bar + tab bar) to window size so content area
        // fits exactly rows * cell_height without cell-grid rounding gaps.
        const chrome_h = TabBarRenderer.computeHeight(metrics.cell_height);
        var window = try Window.init(window_mod.WindowConfig{
            .cols = config.cols(),
            .rows = config.rows(),
            .cell_width = metrics.cell_width,
            .cell_height = metrics.cell_height,
            .grid_padding = config.grid_padding(),
            .chrome_height = chrome_h,
            .title = "PTerm",
        });
        errdefer window.deinit();

        // Re-initialize font grid with actual DPI scale from the window
        const actual_dpi = window.getContentScale();
        if (actual_dpi > 1.01 or actual_dpi < 0.99) {
            // DPI differs from 1.0 — rebuild font grid with correct scale
            font_grid.deinit();
            font_grid.* = try FontGrid.init(allocator, FontConfig{
                .family = config.font_family(),
                .size_pt = config.font_size_pt(),
                .dpi_scale = actual_dpi,
                .fallback = config.font_fallback(),
            });
            metrics = font_grid.getMetrics();
        }

        // Build keybinding map
        const user_bindings: ?[]const keybindings.UserBinding = if (config.keybindings.len > 0)
            @ptrCast(config.keybindings)
        else
            null;
        var kb_map = try keybindings.buildMap(allocator, user_bindings);
        errdefer kb_map.deinit();

        // Build compositor
        const compositor = Compositor.init(allocator);

        // NOTE: Do NOT set GLFW callbacks or start threads here.
        // Call app.start() after init returns to set up callbacks at stable addresses.

        return App{
            .window = window,
            .tab_manager = tab_manager,
            .pane_registry = .{},
            .compositor = compositor,
            .font_grid = font_grid,
            .allocator = allocator,
            .config = config,
            .config_path = null,
            .config_watcher = null,
            .pane_data = .{},
            .frame_requested = std.atomic.Value(bool).init(true),
            .should_quit = std.atomic.Value(bool).init(false),
            .render_thread = null,
            .gl_procs = undefined,
            .pending_resize = std.atomic.Value(bool).init(false),
            .new_fb_width = std.atomic.Value(u32).init(0),
            .new_fb_height = std.atomic.Value(u32).init(0),
            .pending_font_change = std.atomic.Value(bool).init(false),
            .new_font_size = std.atomic.Value(u32).init(@intFromFloat(config.font_size_pt() * 100.0)),
            .renderer_palette = theme_mod.buildRendererPaletteFromConfig(config.colors, config.theme),
            .keybinding_map = kb_map,
            .last_mods = .{},
            .perf_logging = options.perf_logging,
            .debug_keys = options.debug_keys,
            .debug_key_file = if (options.debug_keys)
                std.fs.cwd().createFile("pterm_debug.log", .{}) catch null
            else
                null,
            .frame_count = 0,
            .cursor_blink_timer = std.time.nanoTimestamp(),
            .cursor_visible = true,
            .focused = true,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .agent_detector = if (config.agent.enabled)
                AgentDetector.init(
                    config.agent.preset,
                    config.agent.custom_patterns orelse &[_][]const u8{},
                    @intCast(config.agent.scan_lines),
                )
            else
                null,
            .notification_manager = NotificationManager.init(
                config.agent.notification_cooldown,
                config.agent.notifications,
                config.agent.suppress_when_focused,
                config.agent.notification_sound,
            ),
            .preset_picker = .{},
            .shell_picker = .{},
            .pending_layout_name = options.layout_name,
            .pending_ops = .{},
            .pending_ops_mutex = .{},
            .pane_mutex = .{},
            .text_select_active = false,
            .text_select_pane_id = null,
            .text_select_click_count = 0,
            .text_select_last_click_time = 0,
            .text_select_pending = false,
            .text_select_start_row = 0,
            .text_select_start_col = 0,
            .border_drag_active = false,
            .border_drag_branch = null,
            .border_drag_start_pos = 0,
            .border_drag_start_ratio = 0,
            .border_drag_is_vertical = false,
            .window_drag_active = false,
            .window_drag_moved = false,
            .window_drag_tab_hit = null,
            .window_drag_screen_x = 0,
            .window_drag_screen_y = 0,
            .titlebar_last_click_time = 0,
            .hovered_control = 0,
            .suppress_activity_frames = std.atomic.Value(u32).init(0),
            .hand_cursor = glfw.Cursor.createStandard(.hand) catch null,
            .window_resize_active = false,
            .window_resize_edge = .{},
            .window_resize_start_screen_x = 0,
            .window_resize_start_screen_y = 0,
            .window_resize_start_win_x = 0,
            .window_resize_start_win_y = 0,
            .window_resize_start_win_w = 0,
            .window_resize_start_win_h = 0,
        };
    }

    /// Start all threads and wire GLFW callbacks.
    /// Must be called after init() returns and the App struct is at its final address.
    pub fn start(self: *App) !void {
        // Create first pane (TermIO + PTY + Surface)
        const first_tab = self.tab_manager.getActiveTab() orelse return error.NoTab;
        const pane_id = try self.createPane(null, null, null);

        // Update the tab's root leaf to use this pane_id
        first_tab.root.leaf.pane_id = pane_id;
        first_tab.focused_pane_id = pane_id;
        first_tab.next_pane_id = pane_id + 1;

        // Set GLFW callbacks routing to App
        self.window.setUserPointer(@ptrCast(self));
        self.window.setCallbacks(.{
            .key_callback = callbacks.keyCallback,
            .char_callback = callbacks.charCallback,
            .framebuffer_size_callback = callbacks.framebufferSizeCallback,
            .focus_callback = callbacks.focusCallback,
            .scroll_callback = callbacks.scrollCallback,
            .mouse_button_callback = callbacks.mouseButtonCallback,
            .cursor_pos_callback = callbacks.cursorPosCallback,
        });

        // Activate --layout preset BEFORE starting the render thread to avoid
        // racing on tab tree mutations (the render thread walks active_tab.root).
        if (self.pending_layout_name) |name| {
            self.activatePresetByName(name);
            self.pending_layout_name = null;

            // Close the default tab (tab 0) — layout replaces it at startup
            if (self.tab_manager.tabCount() > 1) {
                // Destroy panes in the default tab before removing it
                switch (self.tab_manager.tabs.items[0].root.*) {
                    .leaf => |leaf| self.destroyPane(leaf.pane_id),
                    .branch => {}, // default tab is always a single leaf
                }
                _ = self.tab_manager.closeTab(0);
                self.tab_manager.switchTab(0);
            }
        }

        // Detach GL context from main thread
        Window.detachContext();

        // Start render thread
        self.render_thread = try std.Thread.spawn(.{}, renderThreadMain, .{self});

        // Start all pane TermIOs and wire per-pane screen change callbacks
        callbacks.g_screen_change_app = self;
        var it = self.pane_data.iterator();
        while (it.next()) |entry| {
            const pane = entry.value_ptr.*;
            if (pane.termio.reader == null or pane.termio.parser != null) continue;
            try pane.termio.start();
            pane.termio.terminal.observer.onScreenChange = &callbacks.screenChangeCallback;
            pane.termio.terminal.observer.screen_change_ctx = @ptrCast(pane);
        }

        // Initialize config file watcher
        if (self.config_path) |path| {
            callbacks.g_reload_app = self;
            self.config_watcher = FileWatcher.init(
                self.allocator,
                &.{path},
                callbacks.configReloadCallback,
            ) catch null;
        }
    }

    /// Create a new pane with its own TermIO + PTY.
    /// Returns the pane_id.
    pub fn createPane(
        self: *App,
        working_dir: ?[]const u8,
        shell_override: ?[]const u8,
        shell_args_override: ?[]const []const u8,
    ) !u32 {
        var termio = try TermIO.init(self.allocator, TermIOConfig{
            .cols = self.config.cols(),
            .rows = self.config.rows(),
            .scrollback_lines = self.config.scrollback_lines(),
        });
        errdefer termio.deinit();

        var pty = try Pty.init(self.allocator, .{
            .cols = self.config.cols(),
            .rows = self.config.rows(),
        });
        errdefer pty.deinit();

        // D-07: per-pane shell override > global config > auto-detect
        // D-09: if per-pane shell not specified, inherit global [shell] config
        const effective_program = shell_override orelse self.config.shell.program;
        const effective_args = shell_args_override orelse self.config.shell.args;
        const shell_config = shell_mod.resolveShell(
            self.allocator,
            effective_program,
            effective_args,
        );
        defer shell_config.deinit();

        // D-23: pass working_dir to PTY spawn for per-pane CWD
        var wd_buf: [1024]u8 = undefined;
        const wd_z: ?[*:0]const u8 = if (working_dir) |wd| blk: {
            if (wd.len < wd_buf.len) {
                @memcpy(wd_buf[0..wd.len], wd);
                wd_buf[wd.len] = 0;
                break :blk wd_buf[0..wd.len :0];
            }
            break :blk null;
        } else null;
        try pty.spawn(shell_config.path, shell_config.args, wd_z);
        termio.attachPty(&pty);

        // Allocate PaneData
        const pd = try self.allocator.create(PaneData);
        errdefer self.allocator.destroy(pd);

        // Generate unique pane ID
        const pane_id = utils.generatePaneId(self);

        // Create lightweight Surface for this pane
        const surface = try Surface.init(self.allocator, self.config, &self.window, &termio, .{
            .perf_logging = self.perf_logging,
            .debug_keys = false, // Only first pane gets debug logging
        });

        // Determine process name from shell
        var proc_name_buf: [64]u8 = [_]u8{0} ** 64;
        var proc_name_len: u32 = 0;
        {
            const shell_path_slice = std.mem.span(shell_config.path);
            // Extract basename from shell path
            const base = if (std.mem.lastIndexOfScalar(u8, shell_path_slice, '/')) |idx|
                shell_path_slice[idx + 1 ..]
            else if (std.mem.lastIndexOfScalar(u8, shell_path_slice, '\\')) |idx|
                shell_path_slice[idx + 1 ..]
            else
                shell_path_slice;
            // Strip .exe extension on Windows
            const name = if (std.mem.endsWith(u8, base, ".exe"))
                base[0 .. base.len - 4]
            else
                base;
            const copy_len = @min(name.len, proc_name_buf.len);
            @memcpy(proc_name_buf[0..copy_len], name[0..copy_len]);
            proc_name_len = @intCast(copy_len);
        }

        // Initialize CWD from working_dir, or detect from current process directory
        var cwd_buf: [256]u8 = [_]u8{0} ** 256;
        var cwd_len: u32 = 0;
        if (working_dir) |wd| {
            const copy_len = @min(wd.len, cwd_buf.len);
            @memcpy(cwd_buf[0..copy_len], wd[0..copy_len]);
            cwd_len = @intCast(copy_len);
        } else {
            // Detect CWD from the current process (shell inherits this)
            if (std.fs.cwd().realpath(".", &cwd_buf)) |resolved| {
                cwd_len = @intCast(resolved.len);
            } else |_| {}
        }

        pd.* = .{
            .surface = surface,
            .termio = termio,
            .pty = pty,
            .pane_id = pane_id,
            .tab_index = 0,
            .cwd = cwd_buf,
            .cwd_len = std.atomic.Value(u32).init(cwd_len),
            .process_name = proc_name_buf,
            .process_name_len = proc_name_len,
            .screen_change_fn = null,
            .row_cache = .{},
            .idle_tracker = IdleTracker.init(
                @intCast(self.config.agent.idle_timeout),
                self.config.agent.idle_detection,
            ),
        };

        // Fix up internal pointers to point to PaneData's copies (not the stack locals)
        pd.surface.termio = &pd.termio;
        pd.surface.window = &self.window;

        // Re-attach PTY pointer: termio.pty and the PtyReader both hold pointers to the
        // old stack-local pty. Now that pty lives inside PaneData, re-attach so all
        // pointers reference the stable heap location.
        pd.termio.attachPty(&pd.pty);

        // Wire bell detection: Observer fires callbacks.bellCallback when BEL (0x07) found in output.
        pd.termio.terminal.observer.onBell = callbacks.bellCallback;
        pd.termio.terminal.observer.bell_ctx = @ptrCast(&pd.bell_state);

        // Wire agent output detection: Observer fires callbacks.agentOutputCallback on raw output.
        pd.termio.terminal.observer.onAgentOutput = callbacks.agentOutputCallback;
        pd.termio.terminal.observer.agent_ctx = @ptrCast(pd);

        // Create PaneState for registry
        const ps = try self.allocator.create(PaneState);
        errdefer self.allocator.destroy(ps);
        ps.* = .{
            .user_data = @ptrCast(pd),
            .bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        };

        try self.pane_data.put(self.allocator, pane_id, pd);
        try self.pane_registry.put(self.allocator, pane_id, ps);

        return pane_id;
    }

    /// Destroy a pane: stop its TermIO, deinit PTY, remove from registries.
    pub fn destroyPane(self: *App, pane_id: u32) void {
        // Clean up notification cooldown entry for this pane
        self.notification_manager.removePane(pane_id);

        if (self.pane_data.get(pane_id)) |pd| {
            // Stop TermIO threads
            pd.termio.stop();

            // Free per-pane row cache
            pd.row_cache.invalidate();

            // Free per-pane search and URL state
            pd.search_state.deinit(self.allocator);
            pd.url_state.deinit();

            // Deinit in reverse order
            pd.surface.deinit();
            pd.pty.deinit();
            pd.termio.deinit();

            self.allocator.destroy(pd);
        }
        _ = self.pane_data.remove(pane_id);

        if (self.pane_registry.get(pane_id)) |ps| {
            self.allocator.destroy(ps);
        }
        _ = self.pane_registry.remove(pane_id);
    }

    pub fn deinit(self: *App) void {
        // Free cached shell list
        self.closeShellPicker();

        // Stop config watcher
        if (self.config_watcher) |*w| {
            w.deinit();
            self.config_watcher = null;
        }

        // Stop render thread
        self.should_quit.store(true, .release);
        if (self.render_thread) |thread| {
            thread.join();
        }
        self.render_thread = null;

        // Stop all pane TermIOs and clean up
        var it = self.pane_data.iterator();
        while (it.next()) |entry| {
            const pd = entry.value_ptr.*;
            pd.termio.stop();
            pd.search_state.deinit(self.allocator);
            pd.url_state.deinit();
            pd.surface.deinit();
            pd.pty.deinit();
            pd.termio.deinit();
            self.allocator.destroy(pd);
        }
        self.pane_data.deinit(self.allocator);

        // Clean up PaneState entries
        var ps_it = self.pane_registry.iterator();
        while (ps_it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pane_registry.deinit(self.allocator);

        // Clean up notification manager
        self.notification_manager.deinit(self.allocator);

        // Clean up remaining resources
        self.pending_ops.deinit(self.allocator);
        self.tab_manager.deinit();
        self.compositor.deinit();
        self.keybinding_map.deinit();
        if (self.debug_key_file) |f| f.close();
        self.frame_arena.deinit();
        self.font_grid.deinit();
        self.allocator.destroy(self.font_grid);
        self.window.deinit();
    }

    /// Main thread event loop (D-15: main thread does NOT do GL calls).
    pub fn run(self: *App) !void {
        while (!self.window.shouldClose()) {
            // Apply pending OSC title from focused pane
            if (self.getFocusedPaneData()) |pd| {
                pd.surface.applyPendingTitle();
            }

            // Poll config file watcher
            if (self.config_watcher) |*w| {
                w.poll();
            }

            // Adaptive event handling
            Window.pollEvents();
        }
    }

    // -- Delegated modules --
    // Input handling, action dispatch, rendering, and callbacks are in separate files.
    // These re-exports maintain the public API on the App struct.

    const input = @import("input.zig");
    const actions = @import("actions.zig");
    const render = @import("render.zig");

    pub fn handleKeyInput(self: *App, key: glfw.Key, action: glfw.Action, mods: glfw.Mods) void {
        input.handleKeyInput(self, key, action, mods);
    }
    pub fn handleCharInput(self: *App, codepoint: u32) void {
        input.handleCharInput(self, codepoint);
    }
    pub fn handleMouseButton(self: *App, button: glfw.MouseButton, action_val: glfw.Action, mods: glfw.Mods) void {
        input.handleMouseButton(self, button, action_val, mods);
    }
    pub fn handleCursorPos(self: *App, xpos: f64, ypos: f64) void {
        input.handleCursorPos(self, xpos, ypos);
    }
    pub fn handleSearchKeyInput(self: *App, pd: *PaneData, key: glfw.Key, mods: glfw.Mods) void {
        input.handleSearchKeyInput(self, pd, key, mods);
    }
    pub fn handlePickerInput(self: *App, key: glfw.Key) void {
        input.handlePickerInput(self, key);
    }
    pub fn handleShellPickerInput(self: *App, key: glfw.Key) void {
        input.handleShellPickerInput(self, key);
    }

    pub fn dispatchAction(self: *App, action_val: keybindings.Action) void {
        actions.dispatchAction(self, action_val);
    }
    pub fn actionNewTab(self: *App) void {
        actions.actionNewTab(self);
    }
    pub fn actionCloseTab(self: *App) void {
        actions.actionCloseTab(self);
    }
    pub fn switchToTab(self: *App, idx: usize) void {
        actions.switchToTab(self, idx);
    }
    pub fn focusDirection(self: *App, direction: PaneTree.FocusDirection) void {
        actions.focusDirection(self, direction);
    }
    pub fn actionSplit(self: *App, direction: PaneTree.SplitDirection) void {
        actions.actionSplit(self, direction);
    }
    pub fn actionClosePane(self: *App) void {
        actions.actionClosePane(self);
    }
    pub fn actionZoomPane(self: *App) void {
        actions.actionZoomPane(self);
    }
    pub fn actionResizePane(self: *App, direction: PaneTree.FocusDirection) void {
        actions.actionResizePane(self, direction);
    }
    pub fn actionSwapDirectional(self: *App, direction: PaneTree.FocusDirection) void {
        actions.actionSwapDirectional(self, direction);
    }
    pub fn actionRotateSplit(self: *App) void {
        actions.actionRotateSplit(self);
    }
    pub fn actionBreakOut(self: *App) void {
        actions.actionBreakOut(self);
    }
    pub fn resizeAllPanes(self: *App) void {
        actions.resizeAllPanes(self);
    }
    pub fn updateTabTitles(self: *App) void {
        actions.updateTabTitles(self);
    }
    pub fn actionOpenShellPicker(self: *App) void {
        actions.actionOpenShellPicker(self);
    }
    pub fn closeShellPicker(self: *App) void {
        actions.closeShellPicker(self);
    }
    pub fn respawnShell(self: *App, pd: *PaneData, shell_name: []const u8) !void {
        try actions.respawnShell(self, pd, shell_name);
    }
    pub fn activatePreset(self: *App, preset: *const LayoutPreset.LayoutPreset) void {
        actions.activatePreset(self, preset);
    }
    pub fn activatePresetByName(self: *App, name: []const u8) void {
        actions.activatePresetByName(self, name);
    }
    pub fn changeFontSize(self: *App, delta: f32) void {
        actions.changeFontSize(self, delta);
    }
    pub fn resetFontSize(self: *App) void {
        actions.resetFontSize(self);
    }

    pub fn requestFrame(self: *App) void {
        self.frame_requested.store(true, .release);
    }

    pub fn queueOp(self: *App, op: PaneOp) void {
        self.pending_ops_mutex.lock();
        defer self.pending_ops_mutex.unlock();
        self.pending_ops.append(self.allocator, op) catch {};
        self.requestFrame();
    }

    pub fn getFocusedPaneData(self: *App) ?*PaneData {
        const tab = self.tab_manager.getActiveTab() orelse return null;
        return self.pane_data.get(tab.focused_pane_id);
    }

    fn renderThreadMain(self: *App) void {
        render.renderThreadMain(self);
    }

    // Re-exported types for other modules
    pub const BorderHit = input.BorderHit;
};
