/// Application lifecycle: init, run, deinit.
///
/// Multi-pane architecture (Phase 5 Plan 02):
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

    /// Per-pane search state (Phase 6, D-09: independent per pane).
    search_state: SearchState = .{},

    /// Per-pane URL hover state (Phase 6, D-14/D-20: underline + hand cursor on hover).
    url_state: UrlState = .{},

    /// Per-pane bell state (Phase 6, D-26: per-pane flash + badge).
    bell_state: BellState = .{},

    /// Per-pane agent monitoring state (Phase 7, D-17: independent per pane).
    agent_state: AgentState = .{},

    /// Per-pane idle tracker (Phase 7, D-09: optional idle detection).
    idle_tracker: IdleTracker = IdleTracker.init(5, false),

    /// Flag set by observer callback, consumed by render snapshot for debounced scan.
    needs_agent_scan: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Suppress agent state transitions during resize (PTY redraws cause false positives).
    suppress_agent_output: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Scrollback viewport offset: 0 = live (bottom), >0 = scrolled up N lines into history.
    scroll_offset: u32 = 0,
};

// Static state for config reload callback (FileWatcher callback has no context pointer).
// Safe because there is exactly one App instance per process.
var g_reload_app: ?*App = null;

// Static state for screen change callback (shared across all panes).
var g_screen_change_app: ?*App = null;

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

    // Shell picker overlay (Phase 11)
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

    // URL hover cursor (Phase 6, D-20: pointing hand on URL hover)
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

    const WindowEdge = packed struct {
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
        const chrome_h = TabBarRenderer.computeHeight(metrics.cell_height, 4);
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
            .renderer_palette = theme_mod.buildRendererPaletteFromConfig(config.colors),
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
            .key_callback = keyCallback,
            .char_callback = charCallback,
            .framebuffer_size_callback = framebufferSizeCallback,
            .focus_callback = focusCallback,
            .scroll_callback = scrollCallback,
            .mouse_button_callback = mouseButtonCallback,
            .cursor_pos_callback = cursorPosCallback,
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
        g_screen_change_app = self;
        var it = self.pane_data.iterator();
        while (it.next()) |entry| {
            const pane = entry.value_ptr.*;
            if (pane.termio.reader == null or pane.termio.parser != null) continue;
            try pane.termio.start();
            pane.termio.terminal.observer.onScreenChange = &screenChangeCallback;
            pane.termio.terminal.observer.screen_change_ctx = @ptrCast(pane);
        }

        // Initialize config file watcher
        if (self.config_path) |path| {
            g_reload_app = self;
            self.config_watcher = FileWatcher.init(
                self.allocator,
                &.{path},
                configReloadCallback,
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
        const pane_id = generatePaneId(self);

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

        // Wire bell detection: Observer fires bellCallback when BEL (0x07) found in output.
        pd.termio.terminal.observer.onBell = bellCallback;
        pd.termio.terminal.observer.bell_ctx = @ptrCast(&pd.bell_state);

        // Wire agent output detection: Observer fires agentOutputCallback on raw output.
        pd.termio.terminal.observer.onAgentOutput = agentOutputCallback;
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
        self.notification_manager.removePane(self.allocator, pane_id);

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

    /// Config reload callback
    fn configReloadCallback() void {
        const self = g_reload_app orelse return;
        const cli_args = cli_mod.CliArgs{ .config_path = self.config_path };
        const new_config = Config.load(self.allocator, cli_args) catch |err| {
            std.log.warn("Config reload failed: {}", .{err});
            return;
        };
        self.renderer_palette = theme_mod.buildRendererPaletteFromConfig(new_config.colors);
        // Update notification manager from new config (D-20 hot-reload)
        self.notification_manager.updateConfig(
            new_config.agent.notification_cooldown,
            new_config.agent.notifications,
            new_config.agent.suppress_when_focused,
            new_config.agent.notification_sound,
        );
        self.config = new_config;
        self.requestFrame();
        std.log.info("Config hot-reloaded", .{});
    }

    pub fn deinit(self: *App) void {
        // Free cached shell list (Phase 11)
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

    // -- Input routing --

    /// Handle key input: route to focused pane's Surface for VT encoding.
    fn handleKeyInput(self: *App, key: glfw.Key, action: glfw.Action, mods: glfw.Mods) void {
        if (action != .press and action != .repeat) return;

        self.last_mods = glfwModsToModifiers(mods);

        // Clear text selection on any keypress except clipboard keys (Esc or typing deselects)
        if (self.getFocusedPaneData()) |pd| {
            if (pd.surface.selection.range != null) {
                // Don't clear for modifier-only keys or Ctrl+C/V — clipboard handler needs the selection
                const is_modifier = key == .left_shift or key == .right_shift or
                    key == .left_control or key == .right_control or
                    key == .left_alt or key == .right_alt or
                    key == .left_super or key == .right_super;
                const is_clipboard = mods.control and !mods.alt and !mods.super and
                    (key == .c or key == .v);
                if (!is_modifier and !is_clipboard) {
                    pd.surface.selection.clear();
                    self.requestFrame();
                    if (key == .escape) return;
                }
            }
        }

        // Reset scrollback viewport on keypress (snap to live terminal)
        if (self.getFocusedPaneData()) |pd| {
            if (pd.scroll_offset > 0) {
                pd.scroll_offset = 0;
                self.requestFrame();
            }
        }

        // Intercept input when shell picker is visible (Phase 11)
        if (self.shell_picker.visible) {
            self.handleShellPickerInput(key);
            return;
        }

        // Intercept input when preset picker is visible
        if (self.preset_picker.visible) {
            self.handlePickerInput(key);
            return;
        }

        // D-11: Full input capture when search is open
        if (self.getFocusedPaneData()) |pd| {
            if (pd.search_state.is_open) {
                self.handleSearchKeyInput(pd, key, mods);
                return;
            }
        }

        if (self.debug_key_file) |f| {
            var tmp: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&tmp, "[key] code={d} action={d} ctrl={} shift={} alt={}\n", .{
                @intFromEnum(key), @intFromEnum(action), mods.control, mods.shift, mods.alt,
            }) catch "";
            if (line.len > 0) _ = f.write(line) catch 0;
        }

        // Check keybinding map — special keys first, then character keys
        const km = glfwModsToModifiers(mods);

        if (Surface.mapGlfwKeyToSpecial(key)) |special| {
            const combo = keybindings.KeyCombo{
                .key = .{ .special = special },
                .mods = km,
            };

            if (keybindings.isReservedClipboardKey(combo)) {
                if (self.getFocusedPaneData()) |pd| {
                    pd.surface.handleClipboardAction(combo);
                }
                return;
            }

            if (self.keybinding_map.get(combo)) |bound_action| {
                self.dispatchAction(bound_action);
                return;
            }
        }

        // Character-based keybindings (ctrl+shift+h, alt+1, etc.)
        if (glfwKeyToChar(key)) |ch| {
            const combo = keybindings.KeyCombo{
                .key = .{ .char = ch },
                .mods = km,
            };

            if (keybindings.isReservedClipboardKey(combo)) {
                if (self.getFocusedPaneData()) |pd| {
                    pd.surface.handleClipboardAction(combo);
                }
                return;
            }

            if (self.keybinding_map.get(combo)) |bound_action| {
                self.dispatchAction(bound_action);
                return;
            }
        }

        // Font zoom via GLFW key codes
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

        // Fall through to focused pane for VT encoding
        if (self.getFocusedPaneData()) |pd| {
            pd.surface.handleKeyInput(key, action, mods);
        }
    }

    /// Handle character input: route to focused pane.
    fn handleCharInput(self: *App, codepoint: u32) void {
        const cp: u21 = if (codepoint <= 0x10FFFF) @intCast(codepoint) else return;

        // D-11: When search is open, printable chars go to search query
        if (self.getFocusedPaneData()) |pd| {
            if (pd.search_state.is_open) {
                if (cp >= 0x20 and cp < 0x7F) {
                    pd.search_state.addChar(@intCast(cp));
                    self.requestFrame();
                }
                return;
            }
        }

        const combo = keybindings.KeyCombo{
            .key = .{ .char = if (cp >= 'A' and cp <= 'Z') cp + 32 else cp },
            .mods = self.last_mods,
        };

        if (keybindings.isReservedClipboardKey(combo)) {
            if (self.getFocusedPaneData()) |pd| {
                pd.surface.handleClipboardAction(combo);
            }
            return;
        }

        if (self.keybinding_map.get(combo)) |bound_action| {
            self.dispatchAction(bound_action);
            return;
        }

        // Fall through to focused pane
        if (self.getFocusedPaneData()) |pd| {
            pd.surface.handleCharInput(codepoint);
        }
    }

    /// Handle mouse button: hit-test tab bar, pane borders, pane area (D-07, D-08, D-34).
    pub fn handleMouseButton(self: *App, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
        // Handle drag release
        if (action == .release and button == .left) {
            if (self.window_resize_active) {
                self.window_resize_active = false;
                self.window_resize_edge = .{};
            }
            if (self.window_drag_active) {
                // If released without moving, treat as a tab click
                if (!self.window_drag_moved) {
                    if (self.window_drag_tab_hit) |idx| {
                        self.switchToTab(idx);
                        self.requestFrame();
                    }
                }
                self.window_drag_active = false;
                self.window_drag_moved = false;
                self.window_drag_tab_hit = null;
            }
            if (self.border_drag_active) {
                self.border_drag_active = false;
                self.border_drag_branch = null;
                // Snap to cell grid on release (D-29)
                self.resizeAllPanes();
                self.requestFrame();
            }
            if (self.text_select_pending) {
                // Single click released without drag — no selection
                self.text_select_pending = false;
                self.text_select_pane_id = null;
            }
            if (self.text_select_active) {
                self.text_select_active = false;
                if (self.text_select_pane_id) |pid| {
                    if (self.pane_data.get(pid)) |pd| {
                        _ = pd.surface.selection.finish();
                        self.requestFrame();
                    }
                }
                self.text_select_pane_id = null;
            }
            return;
        }

        if (action != .press) return;

        // GLFW on Windows reports cursor positions in the same space as the
        // framebuffer (already DPI-scaled). No multiplication needed.
        const pos = self.window.handle.getCursorPos();
        const fb_x: i32 = @intFromFloat(pos[0]);
        const fb_y: i32 = @intFromFloat(pos[1]);
        const win_x = fb_x;
        const win_y = fb_y;
        const metrics = self.font_grid.getMetrics();
        const fb = self.window.getFramebufferSize();

        // Check window edge resize — but NOT on title bar controls
        if (button == .left) {
            const edge = self.detectWindowEdge(win_x, win_y);
            const in_controls = TabBarRenderer.isInControlsArea(fb_x, fb_y, metrics.cell_height, fb.width);
            if (edgeIsAny(edge) and !in_controls) {
                self.window_resize_active = true;
                self.window_resize_edge = edge;
                const wpos = self.window.getPos();
                const wsz = self.window.getSize();
                self.window_resize_start_screen_x = wpos.x + win_x;
                self.window_resize_start_screen_y = wpos.y + win_y;
                self.window_resize_start_win_x = wpos.x;
                self.window_resize_start_win_y = wpos.y;
                self.window_resize_start_win_w = @intCast(wsz.width);
                self.window_resize_start_win_h = @intCast(wsz.height);
                return;
            }
        }

        // Check title bar + tab bar (both rows) — all in framebuffer coords
        const total_h: i32 = @intCast(TabBarRenderer.computeHeight(metrics.cell_height, 4));
        if (fb_y >= 0 and fb_y < total_h) {
            if (button == .middle) {
                const hit = TabBarRenderer.hitTest(fb_x, fb_y, self.tab_manager.tabCount(), metrics.cell_width, metrics.cell_height, fb.width);
                switch (hit) {
                    .tab => |_| self.actionCloseTab(),
                    else => {},
                }
                return;
            }
            if (button != .left) return;

            const hit = TabBarRenderer.hitTest(
                fb_x,
                fb_y,
                self.tab_manager.tabCount(),
                metrics.cell_width,
                metrics.cell_height,
                fb.width,
            );
            switch (hit) {
                .close_tab => |_| {
                    self.actionCloseTab();
                },
                .new_tab => {
                    self.actionNewTab();
                },
                .window_minimize => self.window.iconify(),
                .window_maximize => self.window.toggleMaximize(),
                .window_close => self.window.requestClose(),
                else => {
                    // Double-click on title bar area → maximize/restore
                    const now = std.time.nanoTimestamp();
                    const elapsed_ns = now - self.titlebar_last_click_time;
                    self.titlebar_last_click_time = now;
                    if (elapsed_ns > 0 and elapsed_ns < 400_000_000) { // 400ms threshold
                        self.window.toggleMaximize();
                        self.titlebar_last_click_time = 0; // Reset to prevent triple-click trigger
                        return;
                    }

                    // Tab clicks, drag region, empty space — all start a drag.
                    // If released without movement, treat as tab click (see release handler).
                    self.window_drag_active = true;
                    self.window_drag_moved = false;
                    self.window_drag_tab_hit = switch (hit) {
                        .tab => |idx| @as(?usize, idx),
                        else => null,
                    };
                    const wpos = self.window.getPos();
                    self.window_drag_screen_x = wpos.x + win_x;
                    self.window_drag_screen_y = wpos.y + win_y;
                },
            }
            return;
        }

        // Phase 8 D-16: Right-click context-sensitive copy/paste in pane area
        if (button == .right and action == .press) {
            if (self.getFocusedPaneData()) |pd| {
                if (pd.surface.selection.range != null) {
                    pd.surface.copySelection();
                    // copySelection already clears selection
                } else {
                    pd.surface.pasteFromClipboard();
                }
            }
            return;
        }

        // Phase 8 D-18: Middle-click paste in pane area
        if (button == .middle and action == .press) {
            if (self.getFocusedPaneData()) |pd| {
                pd.surface.pasteFromClipboard();
            }
            return;
        }

        if (button != .left) return;

        // Pane bounds are in framebuffer space (fb_x/fb_y already computed above)

        // Check pane border grab zone (within 4px of border, D-21)
        const active_tab = self.tab_manager.getActiveTab() orelse return;
        if (self.findBorderAtPoint(active_tab.root, fb_x, fb_y)) |border_info| {
            self.border_drag_active = true;
            self.border_drag_branch = border_info.branch;
            self.border_drag_is_vertical = border_info.is_vertical;
            self.border_drag_start_pos = if (border_info.is_vertical) pos[0] else pos[1];
            self.border_drag_start_ratio = border_info.branch.branch.ratio;
            return;
        }

        // Phase 6 D-16: Ctrl+Click (Cmd+Click macOS) opens hovered URL
        // Only when url.enabled=true (D-22: when disabled, Ctrl+Click passes through)
        if (self.config.url.enabled) {
            const is_url_click = if (builtin.os.tag == .macos) mods.super else mods.control;
            if (is_url_click) {
                if (self.getFocusedPaneData()) |pd| {
                    if (pd.url_state.getHoveredUrl()) |url| {
                        open_url.openUrl(url);
                        return; // Consume click (D-16: no terminal selection)
                    }
                }
            }
        }

        // Check status bar click: focus the corresponding pane
        if (self.config.status_bar.visible) {
            const sb_height = StatusBarRenderer.statusBarHeight(metrics.cell_height);
            const sb_top: i32 = @intCast(if (fb.height > sb_height) fb.height - sb_height else 0);
            if (fb_y >= sb_top) {
                // Build the same pane_number→pane_id mapping used in render
                const leaf_infos = tree_ops.collectLeafInfos(active_tab.root, std.heap.page_allocator) catch &.{};
                defer if (leaf_infos.len > 0) std.heap.page_allocator.free(leaf_infos);

                var sb_pane_infos: [32]status_bar_mod.PaneStatusInfo = undefined;
                var sb_count: usize = 0;
                for (leaf_infos) |li| {
                    if (sb_count >= 32) break;
                    if (self.pane_data.get(li.pane_id)) |_| {
                        sb_pane_infos[sb_count] = .{
                            .pane_number = @intCast(sb_count + 1),
                            .state = .idle,
                            .is_focused = false,
                        };
                        sb_count += 1;
                    }
                }

                if (StatusBarRenderer.hitTest(sb_pane_infos[0..sb_count], fb_x, metrics.cell_height)) |pane_number| {
                    // pane_number is 1-indexed, leaf_infos is 0-indexed
                    const idx = pane_number - 1;
                    if (idx < leaf_infos.len) {
                        active_tab.focused_pane_id = leaf_infos[idx].pane_id;
                        self.requestFrame();
                        return;
                    }
                }
            }
        }

        // Check pane area: focus the clicked pane (D-34)
        const leaves = tree_ops.collectLeaves(active_tab.root, std.heap.page_allocator) catch return;
        defer std.heap.page_allocator.free(leaves);

        for (leaves) |pane_id| {
            if (tree_ops.findLeaf(active_tab.root, pane_id)) |leaf_node| {
                if (leaf_node.leaf.bounds.contains(fb_x, fb_y)) {
                    active_tab.focused_pane_id = pane_id;

                    // Start text selection at click position
                    // Detect multi-click: double-click = word, triple-click = line
                    if (self.pane_data.get(pane_id)) |pd| {
                        const m = self.font_grid.getMetrics();
                        const cw: u32 = @intFromFloat(m.cell_width);
                        const ch: u32 = @intFromFloat(m.cell_height);
                        if (cw > 0 and ch > 0) {
                            const bounds = leaf_node.leaf.bounds;
                            const rel_x = fb_x - bounds.x;
                            const rel_y = fb_y - bounds.y;
                            if (rel_x >= 0 and rel_y >= 0) {
                                const col: u16 = @intCast(@min(@as(u32, @intCast(rel_x)) / cw, 65535));
                                const row: u32 = @as(u32, @intCast(rel_y)) / ch;
                                const cols: u16 = if (cw > 0) @intCast(@as(u32, @intCast(bounds.w)) / cw) else 80;

                                // Multi-click detection (400ms threshold)
                                const now = std.time.nanoTimestamp();
                                const elapsed_ns = now - self.text_select_last_click_time;
                                self.text_select_last_click_time = now;
                                if (elapsed_ns > 0 and elapsed_ns < 400_000_000) {
                                    self.text_select_click_count = @min(self.text_select_click_count + 1, 3);
                                } else {
                                    self.text_select_click_count = 1;
                                }

                                pd.surface.selection.clear();

                                if (self.text_select_click_count >= 2) {
                                    // Double/triple click: select immediately
                                    if (self.text_select_click_count >= 3) {
                                        // Line select
                                        pd.surface.selection.begin(row, 0, .line);
                                        pd.surface.selection.update(row, cols);
                                    } else {
                                        // Word select: expand to word boundaries
                                        const snapshot = pd.termio.lockTerminal();
                                        const screens = @constCast(snapshot).getScreens();
                                        const screen = screens.active;
                                        const tcols: u16 = @intCast(screen.pages.cols);

                                        // Read codepoint at position
                                        const isWordChar = struct {
                                            fn f(cp: u21) bool {
                                                if (cp == 0 or cp == ' ' or cp == '\t') return false;
                                                // Punctuation/delimiters break words
                                                if (cp < 128) {
                                                    const c: u8 = @intCast(cp);
                                                    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
                                                }
                                                return true; // Non-ASCII = part of word
                                            }
                                        }.f;

                                        const getCp = struct {
                                            fn f(scr: anytype, r: u32, c: u16) u21 {
                                                const p = scr.pages.pin(.{ .active = .{
                                                    .x = @intCast(c),
                                                    .y = @intCast(r),
                                                } }) orelse return 0;
                                                return p.rowAndCell().cell.codepoint();
                                            }
                                        }.f;

                                        // Find word start (scan left)
                                        var word_start: u16 = col;
                                        while (word_start > 0 and isWordChar(getCp(screen, row, word_start -| 1))) {
                                            word_start -= 1;
                                        }
                                        // Find word end (scan right)
                                        var word_end: u16 = col;
                                        while (word_end + 1 < tcols and isWordChar(getCp(screen, row, word_end + 1))) {
                                            word_end += 1;
                                        }
                                        pd.termio.unlockTerminal();

                                        pd.surface.selection.begin(row, word_start, .word);
                                        pd.surface.selection.update(row, word_end);
                                    }

                                    self.text_select_active = true;
                                    self.text_select_pending = false;
                                } else {
                                    // Single click: defer selection until drag
                                    self.text_select_pending = true;
                                    self.text_select_start_row = row;
                                    self.text_select_start_col = col;
                                    self.text_select_active = false;
                                }
                                self.text_select_pane_id = pane_id;
                            }
                        }
                    }

                    self.requestFrame();
                    return;
                }
            }
        }
    }

    /// Handle cursor position for border drag resize and cursor shape.
    pub fn handleCursorPos(self: *App, xpos: f64, ypos: f64) void {
        // Window edge resize (frameless window)
        if (self.window_resize_active) {
            const wpos = self.window.getPos();
            const screen_x: i32 = wpos.x + @as(i32, @intFromFloat(xpos));
            const screen_y: i32 = wpos.y + @as(i32, @intFromFloat(ypos));
            const dx = screen_x - self.window_resize_start_screen_x;
            const dy = screen_y - self.window_resize_start_screen_y;
            const e = self.window_resize_edge;

            var new_x = self.window_resize_start_win_x;
            var new_y = self.window_resize_start_win_y;
            var new_w: i32 = @intCast(self.window_resize_start_win_w);
            var new_h: i32 = @intCast(self.window_resize_start_win_h);

            if (e.right) new_w += dx;
            if (e.bottom) new_h += dy;
            if (e.left) {
                new_x += dx;
                new_w -= dx;
            }
            if (e.top) {
                new_y += dy;
                new_h -= dy;
            }

            // Minimum window size
            const min_w: i32 = 200;
            const min_h: i32 = 100;
            if (new_w < min_w) {
                if (e.left) new_x -= min_w - new_w;
                new_w = min_w;
            }
            if (new_h < min_h) {
                if (e.top) new_y -= min_h - new_h;
                new_h = min_h;
            }

            self.window.setPos(new_x, new_y);
            self.window.setSize(new_w, new_h);
            return;
        }

        // Window drag (frameless window)
        // Use screen-absolute coordinates: window_pos + cursor_pos gives screen position.
        // Compare against the screen-absolute position where the drag started.
        if (self.window_drag_active) {
            const wpos = self.window.getPos();
            const screen_x: i32 = wpos.x + @as(i32, @intFromFloat(xpos));
            const screen_y: i32 = wpos.y + @as(i32, @intFromFloat(ypos));
            const dx = screen_x - self.window_drag_screen_x;
            const dy = screen_y - self.window_drag_screen_y;
            // Only move if there's actual movement (distinguishes click from drag)
            if (dx != 0 or dy != 0) {
                self.window_drag_moved = true;
                self.window.setPos(wpos.x + dx, wpos.y + dy);
                self.window_drag_screen_x = screen_x;
                self.window_drag_screen_y = screen_y;
            }
            return;
        }

        if (self.border_drag_active) {
            const branch = self.border_drag_branch orelse return;
            const b = &branch.branch;
            const parent_bounds = getNodeBounds(branch);

            const total_size: f64 = if (self.border_drag_is_vertical)
                @floatFromInt(parent_bounds.w)
            else
                @floatFromInt(parent_bounds.h);

            if (total_size <= 0) return;

            const current_pos: f64 = if (self.border_drag_is_vertical) xpos else ypos;
            const delta_px = current_pos - self.border_drag_start_pos;
            const delta_ratio: f32 = @floatCast(delta_px / total_size);

            var new_ratio = self.border_drag_start_ratio + delta_ratio;
            new_ratio = @max(0.1, @min(0.9, new_ratio));
            b.ratio = new_ratio;

            self.resizeAllPanes();
            self.requestFrame();
            return;
        }

        // Text selection: start selection on first drag movement (single click deferred)
        if (self.text_select_pending) {
            if (self.text_select_pane_id) |pid| {
                if (self.pane_data.get(pid)) |pd| {
                    pd.surface.selection.begin(self.text_select_start_row, self.text_select_start_col, .normal);
                    self.text_select_active = true;
                    self.text_select_pending = false;
                }
            }
        }

        // Text selection drag: update selection endpoint as cursor moves
        if (self.text_select_active) {
            if (self.text_select_pane_id) |pid| {
                if (self.pane_data.get(pid)) |pd| {
                    const active_tab_sel = self.tab_manager.getActiveTab();
                    if (active_tab_sel) |at| {
                        if (tree_ops.findLeaf(at.root, pid)) |leaf_node| {
                            const m = self.font_grid.getMetrics();
                            const cw: u32 = @intFromFloat(m.cell_width);
                            const ch: u32 = @intFromFloat(m.cell_height);
                            if (cw > 0 and ch > 0) {
                                const bounds = leaf_node.leaf.bounds;
                                const rel_x = @as(i32, @intFromFloat(xpos)) - bounds.x;
                                const rel_y = @as(i32, @intFromFloat(ypos)) - bounds.y;
                                const clamped_x: u32 = if (rel_x < 0) 0 else @intCast(rel_x);
                                const clamped_y: u32 = if (rel_y < 0) 0 else @intCast(rel_y);
                                const col: u16 = @intCast(@min(clamped_x / cw, 65535));
                                const row: u32 = clamped_y / ch;
                                pd.surface.selection.update(row, col);
                                self.requestFrame();
                            }
                        }
                    }
                }
            }
            return;
        }

        // GLFW cursor positions are already in framebuffer space on Windows
        const win_x: i32 = @intFromFloat(xpos);
        const win_y: i32 = @intFromFloat(ypos);
        const fb_x = win_x;
        const fb_y = win_y;

        // Track which control button is hovered (for background highlight)
        const cur_metrics = self.font_grid.getMetrics();
        const cur_fb = self.window.getFramebufferSize();
        const old_hover = self.hovered_control;
        if (TabBarRenderer.isInControlsArea(fb_x, fb_y, cur_metrics.cell_height, cur_fb.width)) {
            const hit = TabBarRenderer.hitTest(fb_x, fb_y, 0, cur_metrics.cell_width, cur_metrics.cell_height, cur_fb.width);
            self.hovered_control = switch (hit) {
                .window_minimize => 1,
                .window_maximize => 2,
                .window_close => 3,
                else => 0,
            };
        } else {
            self.hovered_control = 0;
        }
        if (self.hovered_control != old_hover) self.requestFrame();

        // Window edge cursor shape (frameless window resize)
        const edge = self.detectWindowEdge(win_x, win_y);
        if (edgeIsAny(edge)) {
            const shape: glfw.Cursor.Shape = blk: {
                if ((edge.left and edge.top) or (edge.right and edge.bottom)) break :blk .resize_nwse;
                if ((edge.right and edge.top) or (edge.left and edge.bottom)) break :blk .resize_nesw;
                if (edge.left or edge.right) break :blk .resize_ew;
                break :blk .resize_ns;
            };
            if (glfw.Cursor.createStandard(shape)) |cursor| {
                self.window.handle.setCursor(cursor);
            } else |_| {}
            return;
        }

        // Pane border cursor shape (pane bounds are in framebuffer space)
        const active_tab = self.tab_manager.getActiveTab() orelse return;
        if (self.findBorderAtPoint(active_tab.root, fb_x, fb_y)) |border_info| {
            const shape: glfw.Cursor.Shape = if (border_info.is_vertical) .resize_ew else .resize_ns;
            if (glfw.Cursor.createStandard(shape)) |cursor| {
                self.window.handle.setCursor(cursor);
            } else |_| {}
        } else {
            // Phase 6 D-14/D-20: URL hover detection + pointing hand cursor
            if (self.config.url.enabled) {
                if (self.getFocusedPaneData()) |pd| {
                    // Convert pixel position to cell coordinates
                    const cur_m = self.font_grid.getMetrics();
                    const active_t = self.tab_manager.getActiveTab();
                    if (active_t) |at| {
                        if (tree_ops.findLeaf(at.root, at.focused_pane_id)) |leaf| {
                            const bounds = leaf.leaf.bounds;
                            const rel_x = fb_x - bounds.x;
                            const rel_y = fb_y - bounds.y;
                            const cw_int: u32 = @intFromFloat(cur_m.cell_width);
                            const ch_int: u32 = @intFromFloat(cur_m.cell_height);
                            if (rel_x >= 0 and rel_y >= 0 and cw_int > 0 and ch_int > 0) {
                                const cell_col: u16 = @intCast(@min(@as(u32, @intCast(rel_x)) / cw_int, 65535));
                                const cell_row: u32 = @as(u32, @intCast(rel_y)) / ch_int;

                                // Extract line codepoints for URL string extraction
                                var line_buf: [512]u21 = undefined;
                                var line_slice: ?[]const u21 = null;
                                {
                                    const snapshot = pd.termio.lockTerminal();
                                    defer pd.termio.unlockTerminal();
                                    const screens = @constCast(snapshot).getScreens();
                                    const screen = screens.active;
                                    const cols: u16 = @intCast(screen.pages.cols);
                                    var ci: u16 = 0;
                                    while (ci < cols and ci < 512) : (ci += 1) {
                                        const pin = screen.pages.pin(.{ .active = .{
                                            .x = @intCast(ci),
                                            .y = @intCast(cell_row),
                                        } }) orelse {
                                            line_buf[ci] = ' ';
                                            continue;
                                        };
                                        const rac = pin.rowAndCell();
                                        const cp = rac.cell.codepoint();
                                        line_buf[ci] = if (cp > 0) cp else ' ';
                                    }
                                    line_slice = line_buf[0..ci];
                                }
                                pd.url_state.updateHoverWithLine(cell_row, cell_col, line_slice);

                                if (pd.url_state.hovered_url != null) {
                                    if (!pd.url_state.cursor_is_hand) {
                                        if (self.hand_cursor) |hc| {
                                            self.window.handle.setCursor(hc);
                                        }
                                        pd.url_state.cursor_is_hand = true;
                                    }
                                    self.requestFrame(); // Redraw underline
                                    return;
                                } else if (pd.url_state.cursor_is_hand) {
                                    pd.url_state.cursor_is_hand = false;
                                    self.window.handle.setCursor(null);
                                    self.requestFrame(); // Remove underline
                                    return;
                                }
                            }
                        }
                    }
                }
            }
            self.window.handle.setCursor(null); // Default arrow
        }
    }

    /// Border hit-test result.
    const BorderHit = struct {
        branch: *PaneNode,
        is_vertical: bool, // true = vertical border (left/right resize)
    };

    /// Find a border within the grab zone (4px) at the given pixel position.
    fn findBorderAtPoint(self: *App, node: *PaneNode, x: i32, y: i32) ?BorderHit {
        _ = self;
        return findBorderRecursive(node, x, y);
    }

    fn findBorderRecursive(node: *PaneNode, x: i32, y: i32) ?BorderHit {
        switch (node.*) {
            .branch => |b| {
                const first_bounds = getNodeBounds(b.first);
                const grab_zone: i32 = 4;

                switch (b.direction) {
                    .vertical => {
                        const border_x = first_bounds.x + @as(i32, @intCast(first_bounds.w));
                        if (x >= border_x - grab_zone and x <= border_x + grab_zone) {
                            return .{ .branch = node, .is_vertical = true };
                        }
                    },
                    .horizontal => {
                        const border_y = first_bounds.y + @as(i32, @intCast(first_bounds.h));
                        if (y >= border_y - grab_zone and y <= border_y + grab_zone) {
                            return .{ .branch = node, .is_vertical = false };
                        }
                    },
                }

                // Recurse into children
                return findBorderRecursive(b.first, x, y) orelse findBorderRecursive(b.second, x, y);
            },
            .leaf => return null,
        }
    }

    /// Dispatch a keybinding action.
    fn dispatchAction(self: *App, action: keybindings.Action) void {
        switch (action) {
            .copy => if (self.getFocusedPaneData()) |pd| pd.surface.copySelection(),
            .paste => if (self.getFocusedPaneData()) |pd| pd.surface.pasteFromClipboard(),
            .increase_font_size => self.changeFontSize(1.0),
            .decrease_font_size => self.changeFontSize(-1.0),
            .reset_font_size => self.resetFontSize(),
            .scroll_page_up => if (self.getFocusedPaneData()) |pd| pd.surface.scrollPageUp(),
            .scroll_page_down => if (self.getFocusedPaneData()) |pd| pd.surface.scrollPageDown(),

            // Tab operations
            .new_tab => self.actionNewTab(),
            .close_tab => self.actionCloseTab(),
            .next_tab => {
                const count = self.tab_manager.tabCount();
                if (count > 1) {
                    const next = (self.tab_manager.active_idx + 1) % count;
                    self.switchToTab(next);
                }
            },
            .prev_tab => {
                const count = self.tab_manager.tabCount();
                if (count > 1) {
                    const prev = if (self.tab_manager.active_idx == 0) count - 1 else self.tab_manager.active_idx - 1;
                    self.switchToTab(prev);
                }
            },
            .goto_tab_1 => self.switchToTab(0),
            .goto_tab_2 => self.switchToTab(1),
            .goto_tab_3 => self.switchToTab(2),
            .goto_tab_4 => self.switchToTab(3),
            .goto_tab_5 => self.switchToTab(4),
            .goto_tab_6 => self.switchToTab(5),
            .goto_tab_7 => self.switchToTab(6),
            .goto_tab_8 => self.switchToTab(7),
            .goto_tab_9 => self.switchToTab(8),
            .goto_tab_last => {
                const count = self.tab_manager.tabCount();
                if (count > 0) {
                    self.switchToTab(count - 1);
                }
            },

            // Pane operations
            .split_horizontal => self.actionSplit(.horizontal),
            .split_vertical => self.actionSplit(.vertical),
            .close_pane => self.actionClosePane(),

            // Focus navigation
            .focus_next_pane => {
                if (self.tab_manager.getActiveTab()) |tab| {
                    if (tree_ops.focusNext(tab.root, tab.focused_pane_id)) |next_id| {
                        tab.focused_pane_id = next_id;
                        self.requestFrame();
                    }
                }
            },
            .focus_prev_pane => {
                if (self.tab_manager.getActiveTab()) |tab| {
                    if (tree_ops.focusPrev(tab.root, tab.focused_pane_id)) |prev_id| {
                        tab.focused_pane_id = prev_id;
                        self.requestFrame();
                    }
                }
            },
            .focus_pane_up => self.focusDirection(.up),
            .focus_pane_down => self.focusDirection(.down),
            .focus_pane_left => self.focusDirection(.left),
            .focus_pane_right => self.focusDirection(.right),

            // Tab reorder
            .move_tab_left => { self.tab_manager.moveTabLeft(); self.requestFrame(); },
            .move_tab_right => { self.tab_manager.moveTabRight(); self.requestFrame(); },

            // Zoom (D-24)
            .zoom_pane => self.actionZoomPane(),
            .equalize_panes => {
                if (self.tab_manager.getActiveTab()) |tab| {
                    tree_ops.equalize(tab.root);
                    self.resizeAllPanes();
                    self.requestFrame();
                }
            },
            .rotate_split => self.actionRotateSplit(),

            // Pane resize (keyboard, 1 cell per press, D-29)
            .resize_pane_up => self.actionResizePane(.up),
            .resize_pane_down => self.actionResizePane(.down),
            .resize_pane_left => self.actionResizePane(.left),
            .resize_pane_right => self.actionResizePane(.right),

            // Swap pane (D-30)
            .swap_pane_up => self.actionSwapDirectional(.up),
            .swap_pane_down => self.actionSwapDirectional(.down),
            .swap_pane_left => self.actionSwapDirectional(.left),
            .swap_pane_right => self.actionSwapDirectional(.right),

            // Break out pane to new tab (D-32)
            .break_out_pane => self.actionBreakOut(),

            .open_layout_picker => {
                if (self.config.layouts.len > 0) {
                    self.preset_picker.open(self.config.layouts.len);
                    self.requestFrame();
                }
            },
            // Phase 7: Agent monitoring actions
            .toggle_agent_tab => {
                if (self.getFocusedPaneData()) |pd| {
                    pd.agent_state.toggleAgentTab();
                    self.requestFrame();
                }
            },
            // Phase 11: shell switching
            .change_shell => self.actionOpenShellPicker(),
            .scroll_to_top, .scroll_to_bottom => {},
            .search => {
                // Phase 6: Toggle search overlay on focused pane (D-08 viewport save/restore)
                if (self.getFocusedPaneData()) |pd| {
                    if (pd.search_state.is_open) {
                        // Close search and restore viewport (D-08)
                        const saved = pd.search_state.getSavedViewport();
                        pd.search_state.close();
                        // Restore viewport position
                        const snap = pd.termio.lockTerminal();
                        defer pd.termio.unlockTerminal();
                        const scr = @constCast(snap).getScreens();
                        switch (saved) {
                            .active => scr.active.pages.scroll(.active),
                            .top => scr.active.pages.scroll(.top),
                            .row => |r| scr.active.pages.scroll(.{ .row = r }),
                        }
                    } else {
                        // Open search, saving current viewport (D-08)
                        const snap = pd.termio.lockTerminal();
                        defer pd.termio.unlockTerminal();
                        const scr = @constCast(snap).getScreens();
                        const current_vp: SearchState.SavedViewport = switch (scr.active.pages.viewport) {
                            .active => .active,
                            .top => .top,
                            // For .pin, conservatively save as .active (most common case).
                            // Precise row offset computation deferred to v2.
                            .pin => .active,
                        };
                        pd.search_state.open(current_vp);
                    }
                    self.requestFrame();
                }
            },
            .none => {},
        }
    }

    /// Navigate focus to the pane in the given direction (D-22).
    fn actionFocusDirectional(self: *App, direction: PaneTree.FocusDirection) void {
        self.focusDirection(direction);
    }

    /// Switch to a tab by index, clearing activity indicator (D-13).
    fn actionNewTab(self: *App) void {
        const tab = self.tab_manager.createTab() catch return;
        const pane_id = self.createPane(null, null, null) catch return;

        // Wire the new tab's root leaf to this pane
        tab.root.leaf.pane_id = pane_id;
        tab.focused_pane_id = pane_id;
        tab.next_pane_id = pane_id + 1;

        // Set tab_index on the pane and start TermIO
        const new_tab_idx: u32 = @intCast(self.tab_manager.tabCount() - 1);

        if (self.pane_data.get(pane_id)) |pd| {
            pd.tab_index = new_tab_idx;
            pd.termio.start() catch {};
            pd.termio.terminal.observer.onScreenChange = &screenChangeCallback;
            pd.termio.terminal.observer.screen_change_ctx = @ptrCast(pd);
        }

        // Switch to the new tab and clear stale activity indicators
        self.switchToTab(new_tab_idx);
        self.resizeAllPanes();
        self.updateTabTitles();
        for (self.tab_manager.tabs.items) |*t| t.has_activity = false;
    }

    fn actionCloseTab(self: *App) void {
        self.pane_mutex.lock();
        defer self.pane_mutex.unlock();

        const tab = self.tab_manager.getActiveTab() orelse return;

        // Destroy all panes in this tab
        const leaves = tree_ops.collectLeaves(tab.root, std.heap.page_allocator) catch return;
        defer std.heap.page_allocator.free(leaves);
        for (leaves) |pane_id| {
            self.destroyPane(pane_id);
        }

        const idx = self.tab_manager.active_idx;
        const result = self.tab_manager.closeTab(idx);
        if (result == .last_tab_closed) {
            self.window.handle.setShouldClose(true);
            return;
        }
        self.resizeAllPanes();
        self.requestFrame();
    }

    fn switchToTab(self: *App, idx: usize) void {
        // Close overlays on tab switch (Pitfall 3: prevent acting on wrong pane)
        self.closeShellPicker();
        self.tab_manager.switchTab(idx);
        // Clear activity on the now-active tab
        if (self.tab_manager.getActiveTab()) |tab| {
            tab.has_activity = false;
            // Clear bell badges on the now-active tab's panes (D-29)
            const leaf_infos = tree_ops.collectLeafInfos(tab.root, self.allocator) catch &.{};
            defer if (leaf_infos.len > 0) self.allocator.free(leaf_infos);
            for (leaf_infos) |info| {
                if (self.pane_data.getPtr(info.pane_id)) |pd_ptr| {
                    pd_ptr.*.bell_state.clearBadge();
                }
            }
        }
        self.requestFrame();
    }

    fn focusDirection(self: *App, direction: PaneTree.FocusDirection) void {
        if (self.tab_manager.getActiveTab()) |tab| {
            if (tree_ops.findLeaf(tab.root, tab.focused_pane_id)) |leaf| {
                if (tree_ops.focusDirectional(leaf, direction)) |target_id| {
                    tab.focused_pane_id = target_id;
                    self.requestFrame();
                }
            }
        }
    }

    /// Dispatch a pane/tab action by name (alias for dispatchAction for plan compliance).
    fn dispatchPaneAction(self: *App, action: keybindings.Action) void {
        self.dispatchAction(action);
    }

    /// Split the focused pane in the given direction.
    /// Checks canSplit minimum before proceeding (UI-SPEC: 10x3).
    fn actionSplit(self: *App, direction: PaneTree.SplitDirection) void {
        const tab = self.tab_manager.getActiveTab() orelse return;
        const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;
        const metrics = self.font_grid.getMetrics();

        // Check minimum size constraint (10 cols x 3 rows)
        if (!tree_ops.canSplit(leaf.leaf.bounds, direction, metrics.cell_width, metrics.cell_height, 10, 3)) {
            return;
        }

        const new_id = tab.splitFocused(direction) catch return;

        // Create pane with TermIO + PTY
        const pane_id = self.createPane(null, null, null) catch return;

        // Update the new leaf's pane_id to match the created pane
        if (tree_ops.findLeaf(tab.root, new_id)) |new_leaf| {
            new_leaf.leaf.pane_id = pane_id;
        }
        tab.focused_pane_id = pane_id;

        // Set tab_index and start the new pane's TermIO
        if (self.pane_data.get(pane_id)) |pd| {
            pd.tab_index = @intCast(self.tab_manager.active_idx);
            pd.termio.start() catch {};
            pd.termio.terminal.observer.onScreenChange = &screenChangeCallback;
            pd.termio.terminal.observer.screen_change_ctx = @ptrCast(pd);
        }

        self.resizeAllPanes();
        self.updateTabTitles();
        self.requestFrame();
    }

    /// Close the focused pane (D-20, D-27).
    fn actionClosePane(self: *App) void {
        self.pane_mutex.lock();
        defer self.pane_mutex.unlock();

        const tab = self.tab_manager.getActiveTab() orelse return;
        const old_pane_id = tab.focused_pane_id;

        const result = tab.closeFocused();
        self.destroyPane(old_pane_id);

        if (result) |_| {
            // Sibling takes focus, resize remaining panes
            self.resizeAllPanes();
            self.updateTabTitles();
            self.requestFrame();
        } else {
            // Was last pane in tab (D-27) - close the tab
            const idx = self.tab_manager.active_idx;
            const close_result = self.tab_manager.closeTab(idx);
            if (close_result == .last_tab_closed) {
                self.window.handle.setShouldClose(true);
            }
            self.resizeAllPanes();
            self.updateTabTitles();
            self.requestFrame();
        }
    }

    /// Toggle zoom on the focused pane (D-24).
    fn actionZoomPane(self: *App) void {
        const tab = self.tab_manager.getActiveTab() orelse return;

        if (tab.is_zoomed) {
            // Unzoom: restore saved root
            if (tab.zoom_saved_root) |saved| {
                tab.root = saved;
                tab.zoom_saved_root = null;
            }
            tab.is_zoomed = false;
        } else {
            // Zoom: save current root, create single-leaf root for focused pane
            tab.zoom_saved_root = tab.root;
            const new_root = PaneTree.createLeaf(self.allocator, tab.focused_pane_id, null) catch return;
            tab.root = new_root;
            tab.is_zoomed = true;
        }
        self.resizeAllPanes();
        self.requestFrame();
    }

    /// Resize the focused pane by 1 cell in the given direction (D-29).
    fn actionResizePane(self: *App, direction: PaneTree.FocusDirection) void {
        const tab = self.tab_manager.getActiveTab() orelse return;
        const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;

        // Find the nearest ancestor branch whose split matches the resize direction
        const branch = tree_ops.findResizableBranch(leaf, direction) orelse return;
        const b = &branch.branch;

        const metrics = self.font_grid.getMetrics();

        // Compute delta as a ratio change equivalent to 1 cell
        const total_size: f32 = switch (b.direction) {
            .horizontal => @floatFromInt(getNodeBounds(branch).h),
            .vertical => @floatFromInt(getNodeBounds(branch).w),
        };
        if (total_size <= 0) return;

        const cell_size: f32 = switch (b.direction) {
            .horizontal => metrics.cell_height,
            .vertical => metrics.cell_width,
        };
        const delta = cell_size / total_size;

        // Determine sign: growing first child or second based on direction + which child has focus
        const focus_in_first = tree_ops.findLeaf(b.first, tab.focused_pane_id) != null;
        const grow_first = switch (direction) {
            .down, .right => focus_in_first,
            .up, .left => !focus_in_first,
        };

        var new_ratio = if (grow_first) b.ratio + delta else b.ratio - delta;
        new_ratio = @max(0.1, @min(0.9, new_ratio)); // Clamp
        b.ratio = new_ratio;

        self.resizeAllPanes();
        self.requestFrame();
    }

    /// Swap focused pane with neighbor in the given direction (D-30).
    fn actionSwapDirectional(self: *App, direction: PaneTree.FocusDirection) void {
        const tab = self.tab_manager.getActiveTab() orelse return;
        const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;
        const neighbor_id = tree_ops.focusDirectional(leaf, direction) orelse return;
        const neighbor_leaf = tree_ops.findLeaf(tab.root, neighbor_id) orelse return;

        tree_ops.swap(leaf, neighbor_leaf);
        self.requestFrame();
    }

    /// Rotate the split direction of the focused pane's parent branch (D-33).
    fn actionRotateSplit(self: *App) void {
        const tab = self.tab_manager.getActiveTab() orelse return;
        const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;
        if (leaf.leaf.parent) |parent| {
            tree_ops.rotate(parent);
            self.resizeAllPanes();
            self.requestFrame();
        }
    }

    /// Break the focused pane out into a new tab (D-32).
    fn actionBreakOut(self: *App) void {
        const tab = self.tab_manager.getActiveTab() orelse return;
        const pane_id = tab.focused_pane_id;

        // Only break out if there's more than one pane
        if (tab.paneCount() <= 1) return;

        // Remove from current tab tree (close returns sibling focus)
        const new_focus = tab.closeFocused() orelse return;
        _ = new_focus;

        // Create new tab
        const new_tab = self.tab_manager.createTab() catch return;

        // Point the new tab's root leaf to the existing pane (don't destroy/recreate)
        new_tab.root.leaf.pane_id = pane_id;
        new_tab.focused_pane_id = pane_id;
        new_tab.next_pane_id = pane_id + 1;

        self.resizeAllPanes();
        self.requestFrame();
    }

    /// Recompute bounds for the active tab and resize all pane PTYs.
    /// Called after any structural layout change (split, close, resize, zoom, etc).
    fn resizeAllPanes(self: *App) void {
        // Suppress activity for 30 frames — async PTY redraws from resize cause false positives
        self.suppress_activity_frames.store(30, .release);
        for (self.tab_manager.tabs.items) |*t| t.has_activity = false;
        // Suppress agent state transitions on ALL panes during resize
        var pd_iter = self.pane_data.iterator();
        while (pd_iter.next()) |entry| {
            entry.value_ptr.*.suppress_agent_output.store(true, .release);
        }
        const tab = self.tab_manager.getActiveTab() orelse return;
        const fb = self.window.getFramebufferSize();
        const metrics = self.font_grid.getMetrics();
        const tab_bar_height = TabBarRenderer.computeHeight(metrics.cell_height, 4);
        const status_bar_height: u32 = if (self.config.status_bar.visible)
            StatusBarRenderer.statusBarHeight(metrics.cell_height)
        else
            0;

        const content_y: i32 = @intCast(tab_bar_height);
        const total_chrome = tab_bar_height + status_bar_height;
        const content_h: u32 = if (fb.height > total_chrome) fb.height - total_chrome else 0;
        const available = Rect{
            .x = 0,
            .y = content_y,
            .w = fb.width,
            .h = content_h,
        };

        tree_ops.computeBounds(tab.root, available, metrics.cell_width, metrics.cell_height, 1);

        // Resize each pane's TermIO/PTY to match its new bounds
        const leaves = tree_ops.collectLeaves(tab.root, std.heap.page_allocator) catch return;
        defer std.heap.page_allocator.free(leaves);

        for (leaves) |pid| {
            if (self.pane_data.get(pid)) |pd| {
                if (tree_ops.findLeaf(tab.root, pid)) |leaf_node| {
                    const bounds = leaf_node.leaf.bounds;
                    const cols: u16 = @intFromFloat(@min(500.0, @max(1.0, @as(f32, @floatFromInt(bounds.w)) / metrics.cell_width)));
                    const rows: u16 = @intFromFloat(@min(500.0, @max(1.0, @as(f32, @floatFromInt(bounds.h)) / metrics.cell_height)));
                    pd.termio.resize(cols, rows) catch {};
                }
            }
        }
    }

    /// Update tab titles from focused pane CWD and process name (D-03, D-04).
    /// Format: "N: basename: process [count] [Z]"
    /// Called periodically from the render loop.
    fn updateTabTitles(self: *App) void {
        for (self.tab_manager.tabs.items) |*tab| {
            var title_buf: [128]u8 = undefined;
            var offset: usize = 0;

            // Prefer CWD basename; fall back to process name
            if (self.pane_data.get(tab.focused_pane_id)) |pd| {
                const cwd_l = pd.cwd_len.load(.acquire);
                if (cwd_l > 0) {
                    const cwd_slice = pd.cwd[0..cwd_l];
                    const base = if (std.mem.lastIndexOfScalar(u8, cwd_slice, '/')) |i|
                        cwd_slice[i + 1 ..]
                    else if (std.mem.lastIndexOfScalar(u8, cwd_slice, '\\')) |i|
                        cwd_slice[i + 1 ..]
                    else
                        cwd_slice;
                    const copy_len = @min(base.len, title_buf.len - offset);
                    @memcpy(title_buf[offset .. offset + copy_len], base[0..copy_len]);
                    offset += copy_len;
                } else if (pd.process_name_len > 0) {
                    // No CWD — show process name as fallback
                    const pname = pd.process_name[0..pd.process_name_len];
                    const copy_len = @min(pname.len, title_buf.len - offset);
                    @memcpy(title_buf[offset .. offset + copy_len], pname[0..copy_len]);
                    offset += copy_len;
                }
            }

            // Pane count badge "[N]" if >1 pane (D-03)
            const pcount = tab.paneCount();
            if (pcount > 1) {
                const badge = std.fmt.bufPrint(title_buf[offset..], " [{d}]", .{pcount}) catch "";
                offset += badge.len;
            }

            // Zoom badge "[Z]" (D-24)
            if (tab.is_zoomed) {
                if (offset + 4 <= title_buf.len) {
                    @memcpy(title_buf[offset .. offset + 4], " [Z]");
                    offset += 4;
                }
            }

            const new_title = title_buf[0..offset];
            tab.setTitle(new_title);
        }
    }

    /// Handle keyboard input while the preset picker overlay is visible.
    fn handlePickerInput(self: *App, key: glfw.Key) void {
        switch (key) {
            .up => {
                self.preset_picker.moveUp();
                self.requestFrame();
            },
            .down => {
                self.preset_picker.moveDown();
                self.requestFrame();
            },
            .enter, .kp_enter => {
                const idx = self.preset_picker.getSelectedIndex();
                if (idx < self.config.layouts.len) {
                    self.activatePreset(&self.config.layouts[idx]);
                }
                self.preset_picker.close();
                self.requestFrame();
            },
            .escape => {
                self.preset_picker.close();
                self.requestFrame();
            },
            else => {}, // Ignore all other keys while picker is open
        }
    }

    /// Open the shell picker overlay (D-10: single action opens picker).
    fn actionOpenShellPicker(self: *App) void {
        // Get the currently active pane's shell name for marking
        const current_shell_name: []const u8 = if (self.getFocusedPaneData()) |pd|
            pd.process_name[0..pd.process_name_len]
        else
            "";

        // Filter available shells (D-11, D-12, D-13)
        const result = shell_mod.filterAvailableShells(
            self.allocator,
            self.config.shell.program,
        );

        if (result.count == 0) {
            if (result.items.len > 0) self.allocator.free(result.items);
            return;
        }

        // Free any previous list (including path allocations)
        if (self.available_shells) |prev| {
            for (prev) |si| {
                if (si.path_alloc) |alloc_ptr| {
                    const sentinel_len = std.mem.len(alloc_ptr);
                    self.allocator.free(alloc_ptr[0 .. sentinel_len + 1]);
                }
            }
            self.allocator.free(prev);
        }
        self.available_shells = result.items;

        // Build display strings: "name -- path" or "* name -- path" for active
        var active_idx: usize = 0;
        for (result.items[0..result.count], 0..) |si, i| {
            const is_active = std.mem.eql(u8, si.name, current_shell_name);
            if (is_active) active_idx = i;

            const buf = &self.available_shell_display[i];
            const prefix: []const u8 = if (is_active) "* " else "  ";
            const display = std.fmt.bufPrint(buf, "{s}{s} -- {s}", .{ prefix, si.name, si.path }) catch "???";
            self.available_shell_display_slices[i] = display;
        }

        self.shell_picker.open(result.count, active_idx);
        self.requestFrame();
    }

    /// Handle keyboard input while the shell picker overlay is visible (D-05).
    fn handleShellPickerInput(self: *App, key: glfw.Key) void {
        switch (key) {
            .up => {
                self.shell_picker.moveUp();
                self.requestFrame();
            },
            .down => {
                self.shell_picker.moveDown();
                self.requestFrame();
            },
            .enter, .kp_enter => {
                const idx = self.shell_picker.getSelectedIndex();
                if (self.available_shells) |shells| {
                    if (idx < shells.len) {
                        const selected = shells[idx];
                        if (self.getFocusedPaneData()) |pd| {
                            self.respawnShell(pd, selected.name) catch |err| {
                                std.log.err("Shell switch failed: {}", .{err});
                            };
                        }
                    }
                }
                self.closeShellPicker();
                self.requestFrame();
            },
            .escape => {
                self.closeShellPicker();
                self.requestFrame();
            },
            else => {},
        }
    }

    /// Close shell picker and free cached shell list.
    fn closeShellPicker(self: *App) void {
        self.shell_picker.close();
        if (self.available_shells) |shells| {
            // Free path allocations from findExecutable
            for (shells) |si| {
                if (si.path_alloc) |alloc_ptr| {
                    const sentinel_len = std.mem.len(alloc_ptr);
                    const slice = alloc_ptr[0 .. sentinel_len + 1];
                    self.allocator.free(slice);
                }
            }
            self.allocator.free(shells);
            self.available_shells = null;
        }
    }

    /// Kill current PTY and respawn with a new shell, preserving pane position (D-01, D-03).
    /// Content is lost (D-02). Follows destroyPane ordering for teardown, createPane for spawn.
    fn respawnShell(self: *App, pd: *PaneData, shell_name: []const u8) !void {
        // Compute actual pane dimensions from bounds (not default config)
        const metrics = self.font_grid.getMetrics();
        var actual_cols = self.config.cols();
        var actual_rows = self.config.rows();
        if (self.tab_manager.getActiveTab()) |tab| {
            if (tree_ops.findLeaf(tab.root, pd.pane_id)) |leaf_node| {
                const bounds = leaf_node.leaf.bounds;
                actual_cols = @intFromFloat(@min(500.0, @max(1.0, @as(f32, @floatFromInt(bounds.w)) / metrics.cell_width)));
                actual_rows = @intFromFloat(@min(500.0, @max(1.0, @as(f32, @floatFromInt(bounds.h)) / metrics.cell_height)));
            }
        }

        // --- TEARDOWN (same order as destroyPane) ---
        pd.termio.stop();
        pd.row_cache.invalidate();
        pd.search_state.deinit(self.allocator);
        pd.url_state.deinit();
        pd.surface.deinit();
        pd.pty.deinit();
        pd.termio.deinit();

        // --- RESPAWN (same sequence as createPane lines 487-586) ---
        pd.termio = try TermIO.init(self.allocator, TermIOConfig{
            .cols = actual_cols,
            .rows = actual_rows,
            .scrollback_lines = self.config.scrollback_lines(),
        });

        pd.pty = try Pty.init(self.allocator, .{
            .cols = actual_cols,
            .rows = actual_rows,
        });

        // Resolve and spawn the selected shell
        const shell_config = shell_mod.resolveShell(self.allocator, shell_name, null);
        defer shell_config.deinit();
        try pd.pty.spawn(shell_config.path, shell_config.args, null);
        pd.termio.attachPty(&pd.pty);

        pd.surface = try Surface.init(self.allocator, self.config, &self.window, &pd.termio, .{
            .perf_logging = self.perf_logging,
            .debug_keys = false,
        });

        // Fix up internal pointers (Pitfall 1 — CRITICAL, same as createPane lines 580-586)
        pd.surface.termio = &pd.termio;
        pd.surface.window = &self.window;

        // Rewire observer callbacks (same as createPane lines 588-594)
        pd.termio.terminal.observer.onBell = bellCallback;
        pd.termio.terminal.observer.bell_ctx = @ptrCast(&pd.bell_state);
        pd.termio.terminal.observer.onAgentOutput = agentOutputCallback;
        pd.termio.terminal.observer.agent_ctx = @ptrCast(pd);

        // Update process name from new shell
        {
            const shell_path_slice = std.mem.span(shell_config.path);
            const base = if (std.mem.lastIndexOfScalar(u8, shell_path_slice, '/')) |idx|
                shell_path_slice[idx + 1 ..]
            else if (std.mem.lastIndexOfScalar(u8, shell_path_slice, '\\')) |idx|
                shell_path_slice[idx + 1 ..]
            else
                shell_path_slice;
            const name = if (std.mem.endsWith(u8, base, ".exe"))
                base[0 .. base.len - 4]
            else
                base;
            const copy_len = @min(name.len, pd.process_name.len);
            @memset(&pd.process_name, 0);
            @memcpy(pd.process_name[0..copy_len], name[0..copy_len]);
            pd.process_name_len = @intCast(copy_len);
        }

        // Reset transient pane state (D-02: content lost)
        pd.scroll_offset = 0;
        pd.search_state = .{};
        pd.url_state = .{};
        pd.bell_state = .{};
        pd.agent_state = .{};
        pd.needs_agent_scan = std.atomic.Value(bool).init(false);
        pd.suppress_agent_output = std.atomic.Value(bool).init(false);
        pd.idle_tracker = IdleTracker.init(
            @intCast(self.config.agent.idle_timeout),
            self.config.agent.idle_detection,
        );

        // Wire screen change callback (triggers frame request on terminal output)
        pd.termio.terminal.observer.onScreenChange = &screenChangeCallback;
        pd.termio.terminal.observer.screen_change_ctx = @ptrCast(pd);

        // Start TermIO reader thread (must happen after attachPty and observer wiring)
        try pd.termio.start();

        std.log.info("Shell switched to '{s}' in pane {d}", .{ shell_name, pd.pane_id });
    }

    /// Activate a layout preset: create new tabs with the preset's pane tree.
    /// Non-destructive: opens in new tab(s), preserving existing tabs (D-39).
    fn activatePreset(self: *App, preset: *const LayoutPreset.LayoutPreset) void {
        var first_new_tab_idx: ?usize = null;

        for (preset.tabs) |tab_def| {
            // Create new tab
            const tab = self.tab_manager.createTab() catch continue;
            if (first_new_tab_idx == null) {
                first_new_tab_idx = self.tab_manager.tabCount() - 1;
            }

            if (tab_def.panes.len == 0) continue;

            // Build tree from preset panes
            const start_id = generatePaneId(self);
            const build_result = LayoutPreset.buildTree(self.allocator, tab_def.panes, start_id) catch continue;

            // Replace the tab's default root with the built tree
            PaneTree.destroyNode(self.allocator, tab.root);
            tab.root = build_result.root;

            // Create actual panes (TermIO + PTY) for each leaf
            const leaves = tree_ops.collectLeaves(tab.root, self.allocator) catch continue;
            defer self.allocator.free(leaves);

            for (leaves, 0..) |pane_id, i| {
                const dir = if (i < tab_def.panes.len) tab_def.panes[i].dir else null;
                const pane_shell = if (i < tab_def.panes.len) tab_def.panes[i].shell else null;
                const pane_shell_args = if (i < tab_def.panes.len) tab_def.panes[i].shell_args else null;
                const actual_id = self.createPane(dir, pane_shell, pane_shell_args) catch continue;

                // If the generated pane_id differs from what buildTree assigned,
                // update the tree leaf to match the actual pane_id
                if (actual_id != pane_id) {
                    if (tree_ops.findLeaf(tab.root, pane_id)) |leaf| {
                        leaf.leaf.pane_id = actual_id;
                    }
                }

                // Set focused pane to first leaf
                if (i == 0) {
                    tab.focused_pane_id = actual_id;
                }

                // Execute startup command if specified (D-40)
                if (i < tab_def.panes.len) {
                    if (tab_def.panes[i].cmd) |cmd| {
                        if (self.pane_data.get(actual_id)) |pd| {
                            // Write command + newline to the pane's TermIO
                            // Shell stays interactive after command runs
                            pd.termio.writeInput(cmd) catch {};
                            pd.termio.writeInput("\n") catch {};
                        }
                    }
                }

                // Phase 7 D-12: Set agent tab flag from preset definition
                if (tab_def.agent) {
                    if (self.pane_data.get(actual_id)) |pd| {
                        pd.agent_state.is_agent_tab.store(true, .release);
                    }
                }
            }

            // Update tab's next_pane_id
            tab.next_pane_id = generatePaneId(self);
        }

        // Switch to the first new tab
        if (first_new_tab_idx) |idx| {
            self.tab_manager.switchTab(idx);
        }
        self.requestFrame();
    }

    /// Activate a named layout preset by name. Used by --layout CLI flag.
    pub fn activatePresetByName(self: *App, name: []const u8) void {
        for (self.config.layouts) |*preset| {
            if (std.mem.eql(u8, preset.name, name)) {
                self.activatePreset(preset);
                return;
            }
        }
        std.log.err("Layout \"{s}\" not found in config.", .{name});
    }

    fn changeFontSize(self: *App, delta: f32) void {
        const current_fp = self.new_font_size.load(.acquire);
        const current: f32 = @as(f32, @floatFromInt(current_fp)) / 100.0;
        var new_size = current + delta;
        new_size = @max(6.0, @min(72.0, new_size));
        const new_fp: u32 = @intFromFloat(new_size * 100.0);
        if (new_fp != current_fp) {
            self.new_font_size.store(new_fp, .release);
            self.pending_font_change.store(true, .release);
            self.requestFrame();
        }
    }

    fn resetFontSize(self: *App) void {
        const default_fp: u32 = @intFromFloat(self.config.font_size_pt() * 100.0);
        if (self.new_font_size.load(.acquire) == default_fp) return;
        self.new_font_size.store(default_fp, .release);
        self.pending_font_change.store(true, .release);
        self.requestFrame();
    }

    /// Request a new frame render.
    pub fn requestFrame(self: *App) void {
        self.frame_requested.store(true, .release);
    }

    /// Queue a pane operation for execution on the render thread.
    fn queueOp(self: *App, op: PaneOp) void {
        self.pending_ops_mutex.lock();
        defer self.pending_ops_mutex.unlock();
        self.pending_ops.append(self.allocator, op) catch {};
        self.requestFrame();
    }


    /// Get PaneData for the currently focused pane.
    // -------------------------------------------------------
    // Phase 6: Search input handling (D-11: full input capture)
    // -------------------------------------------------------

    /// Handle key input when search is open. Intercepts all keys.
    fn handleSearchKeyInput(self: *App, pd: *PaneData, key: glfw.Key, mods: glfw.Mods) void {
        switch (key) {
            .escape => {
                pd.search_state.close();
                self.requestFrame();
            },
            .enter => {
                if (mods.shift) {
                    pd.search_state.navigatePrev();
                } else {
                    pd.search_state.navigateNext();
                }
                self.requestFrame();
            },
            .backspace => {
                pd.search_state.deleteChar();
                self.requestFrame();
            },
            else => {
                // Ctrl+Shift+F toggles search closed
                if (mods.control and mods.shift) {
                    if (glfwKeyToChar(key)) |ch| {
                        if (ch == 'f') {
                            pd.search_state.close();
                            self.requestFrame();
                        }
                    }
                }
                // Printable chars handled via charCallback (handleCharInput)
            },
        }
    }

    /// Run search matching for a pane's current query against scrollback history + visible screen (D-07).
    /// Extracts history rows from ghostty-vt PageList using .screen coordinates, then scans
    /// visible screen lines via .active coordinates.
    fn runSearchForPane(self: *App, pd: *PaneData) void {
        _ = self;
        const query = pd.search_state.getQuery();
        if (query.len == 0) {
            pd.search_state.clearMatches(std.heap.page_allocator);
            return;
        }

        // Lock terminal for screen access
        const snapshot = pd.termio.lockTerminal();
        defer pd.termio.unlockTerminal();

        // Collect screen lines from ghostty-vt
        const screens = @constCast(snapshot).getScreens();
        const screen = screens.active;
        const cols: u16 = @intCast(screen.pages.cols);
        const rows: u16 = @intCast(screen.pages.rows);

        // --- Extract scrollback (history) lines from ghostty-vt PageList (D-07) ---
        const total_rows = screen.pages.total_rows;
        const active_rows = screen.pages.rows;
        const history_rows: u32 = if (total_rows > active_rows) @intCast(total_rows - active_rows) else 0;
        const max_history: u32 = @min(history_rows, 10_000); // Cap to prevent huge allocations

        const alloc = std.heap.page_allocator;
        const scrollback_lines_alloc = alloc.alloc([]const u21, max_history) catch return;
        defer alloc.free(scrollback_lines_alloc);

        // Flat buffer for codepoint storage: max_history * 512 u21 values
        const cps_per_row: usize = 512;
        const scrollback_cps_flat = alloc.alloc(u21, @as(usize, max_history) * cps_per_row) catch return;
        defer alloc.free(scrollback_cps_flat);

        var sb_row: u32 = 0;
        while (sb_row < max_history) : (sb_row += 1) {
            const row_offset = @as(usize, sb_row) * cps_per_row;
            var col: u16 = 0;
            var len: usize = 0;
            while (col < cols and len < cps_per_row) : (col += 1) {
                const pin_result = screen.pages.pin(.{ .screen = .{
                    .x = @intCast(col),
                    .y = @intCast(sb_row),
                } }) orelse {
                    scrollback_cps_flat[row_offset + len] = ' ';
                    len += 1;
                    continue;
                };
                const rac = pin_result.rowAndCell();
                const cp = rac.cell.codepoint();
                scrollback_cps_flat[row_offset + len] = if (cp > 0) cp else ' ';
                len += 1;
            }
            scrollback_lines_alloc[sb_row] = scrollback_cps_flat[row_offset .. row_offset + len];
        }

        // --- Extract visible screen lines using .active coordinates ---
        var screen_lines_buf: [500][]const u21 = undefined;
        var screen_cps_buf: [500][512]u21 = undefined;
        const screen_rows = @min(rows, 500);
        var row: u16 = 0;
        while (row < screen_rows) : (row += 1) {
            var col: u16 = 0;
            var len: usize = 0;
            while (col < cols and len < 512) : (col += 1) {
                const pin = screen.pages.pin(.{ .active = .{
                    .x = @intCast(col),
                    .y = @intCast(row),
                } }) orelse {
                    screen_cps_buf[row][len] = ' ';
                    len += 1;
                    continue;
                };
                const rac = pin.rowAndCell();
                const cp = rac.cell.codepoint();
                screen_cps_buf[row][len] = if (cp > 0) cp else ' ';
                len += 1;
            }
            screen_lines_buf[row] = screen_cps_buf[row][0..len];
        }
        const screen_lines = screen_lines_buf[0..screen_rows];

        const matches = matcher.findMatches(scrollback_lines_alloc, screen_lines, query, alloc) catch return;
        defer alloc.free(matches);

        pd.search_state.scrollback_offset = max_history;
        pd.search_state.updateMatches(alloc, matches);
    }

    fn getFocusedPaneData(self: *App) ?*PaneData {
        const tab = self.tab_manager.getActiveTab() orelse return null;
        return self.pane_data.get(tab.focused_pane_id);
    }

    // -- Render thread --

    fn renderThreadMain(self: *App) void {
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
        self.resizeAllPanes();

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

                    self.resizeAllPanes();
                }

                // Handle pending resize
                if (self.pending_resize.swap(false, .acq_rel)) {
                    const w = self.new_fb_width.load(.acquire);
                    const h = self.new_fb_height.load(.acquire);
                    backend.resize(w, h);
                    self.resizeAllPanes();
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
                const tab_bar_height = TabBarRenderer.computeHeight(metrics.cell_height, 4);

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

                // Build per-tab bell badge and agent badge flags for TabBarRenderer (D-29, Phase 7 D-15)
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
                                // Phase 7: Agent waiting badge
                                if (pd_ptr.*.agent_state.show_badge) {
                                    agent_badges_buf[ti] = true;
                                }
                                // Phase 7: Agent tab icon
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
                    tab_bar_height,
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
                                        self.runSearchForPane(pd);
                                    } else {
                                        self.requestFrame(); // keep rendering until debounce fires
                                    }
                                }

                                // Phase 7: Debounced agent scan — check flag set by observer callback
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
                                // Phase 7: Idle detection check (skip during resize suppress)
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

                                // Phase 6 D-21: URL detection on visible viewport
                                if (self.config.url.enabled) {
                                    // Extract visible lines as u21 codepoint slices for URL scanning
                                    const url_rows = snap.rows;
                                    const url_cols = snap.cols;
                                    const url_lines = self.frame_arena.allocator().alloc([]const u21, url_rows) catch null;
                                    if (url_lines) |lines| {
                                        for (0..url_rows) |r| {
                                            const row_start = r * @as(usize, url_cols);
                                            const row_cps = self.frame_arena.allocator().alloc(u21, url_cols) catch {
                                                lines[r] = &.{};
                                                continue;
                                            };
                                            for (0..url_cols) |c| {
                                                const cell_snap = snap.cells[row_start + c];
                                                row_cps[c] = if (cell_snap.grapheme_len > 0) cell_snap.grapheme[0] else ' ';
                                            }
                                            lines[r] = row_cps;
                                        }
                                        const detected = UrlDetector.detectUrls(lines, 0, self.frame_arena.allocator()) catch &.{};
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

                                // Phase 6: Draw search match highlight rectangles (semi-transparent over text)
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

                                // Phase 8: Selection highlight rendering
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

                                // Phase 6 D-14: URL hover underline rendering
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

                                // Phase 6 D-26/D-27: Bell flash overlay + sound + window attention
                                // Never flash the active pane — only background panes
                                if (!is_focused) {
                                    self.processBellForPane(pd, toRendererRect(bounds), &backend);
                                } else {
                                    // Still consume the trigger so it doesn't fire later
                                    _ = pd.bell_state.consumeTrigger();
                                }

                                // Phase 7: Agent flash overlay (D-16: 150ms flash on waiting entry)
                                if (!is_focused) {
                                    self.processAgentFlashForPane(pd, toRendererRect(bounds), &backend);
                                }

                                // Phase 6: Search overlay rendering
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

                    // Phase 7: Render status bar at window bottom
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
                                    const raw_state = lpd.agent_state.state.load(.acquire);
                                    pane_infos[pane_count] = .{
                                        .pane_number = @intCast(pane_count + 1),
                                        .state = switch (raw_state) {
                                            .idle => .idle,
                                            .working => .working,
                                            .waiting => .waiting,
                                        },
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
                        pickerDrawRectCallback,
                        pickerDrawTextCallback,
                        @ptrCast(&backend),
                    );
                }

                // Render shell picker overlay if visible (Phase 11)
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

    fn drawFilledRectCallback(rect: Rect, color: layout_mod.Compositor.ColorU32, ctx: *anyopaque) void {
        const rc: *TabBarRenderCtx = @ptrCast(@alignCast(ctx));
        const c = renderer_types.Color.fromU32(color);
        rc.backend.drawFilledRect(toRendererRect(rect), c);
    }

    fn shellPickerDrawRectCallback(x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void {
        const rc: *TabBarRenderCtx = @ptrCast(@alignCast(ctx));
        const c = renderer_types.Color.fromU32(color);
        rc.backend.drawFilledRect(.{ .x = x, .y = y, .w = w, .h = h }, c);
    }

    fn pickerDrawRectCallback(x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void {
        const backend: *OpenGLBackend = @ptrCast(@alignCast(ctx));
        const c = renderer_types.Color.fromU32(color);
        backend.drawFilledRect(.{ .x = x, .y = y, .w = w, .h = h }, c);
    }

    fn pickerDrawTextCallback(_: []const u8, _: i32, _: i32, _: u32, _: *anyopaque) void {
        // TODO: glyph-based text rendering for picker overlay
        // Same deferral as tab bar text - colored backgrounds render immediately,
        // glyph text rendering requires building CellInstance arrays.
    }

    const TabBarRenderCtx = struct {
        backend: *OpenGLBackend,
        font_grid: *FontGrid,
    };

    fn drawTextCallback(text: []const u8, px_x: i32, px_y: i32, color: layout_mod.Compositor.ColorU32, ctx: *anyopaque) void {
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

    // -- Search overlay render callbacks (Phase 6) --

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

    // -- Status bar render callbacks (Phase 7) --

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
    fn lightenColorU32(color: u32, percent: u32) u32 {
        const r = @as(u8, @truncate((color >> 24) & 0xFF));
        const g = @as(u8, @truncate((color >> 16) & 0xFF));
        const b_ch = @as(u8, @truncate((color >> 8) & 0xFF));
        const a = @as(u8, @truncate(color & 0xFF));
        const nr: u8 = @intCast(@min(255, @as(u16, r) + @as(u16, @intCast(((@as(u32, 255 - r) * percent) / 100)))));
        const ng: u8 = @intCast(@min(255, @as(u16, g) + @as(u16, @intCast(((@as(u32, 255 - g) * percent) / 100)))));
        const nb: u8 = @intCast(@min(255, @as(u16, b_ch) + @as(u16, @intCast(((@as(u32, 255 - b_ch) * percent) / 100)))));
        return (@as(u32, nr) << 24) | (@as(u32, ng) << 16) | (@as(u32, nb) << 8) | @as(u32, a);
    }

    fn renderPaneBorders(node: *PaneNode, focused_id: u32, backend: *OpenGLBackend, pal: *const RendererPalette, pane_data_map: *const std.AutoHashMapUnmanaged(u32, *PaneData)) void {
        switch (node.*) {
            .branch => |b| {
                // Use the FULL parent bounds so the border line spans the entire split
                const parent_bounds = getNodeBounds(node);
                const first_bounds = getNodeBounds(b.first);

                // Use active border color if focused pane is adjacent
                const focus_in_first = tree_ops.findLeaf(b.first, focused_id) != null;
                const focus_in_second = tree_ops.findLeaf(b.second, focused_id) != null;

                // Phase 7: Check if any adjacent pane is in waiting state for agent_alert border
                var has_waiting = false;
                var has_agent_tab_waiting = false;
                _ = &has_agent_tab_waiting; // Reserved for pulse alpha in future
                {
                    const subtrees = [_]*PaneNode{ b.first, b.second };
                    for (subtrees) |subtree| {
                        const leaves = tree_ops.collectLeaves(subtree, std.heap.page_allocator) catch &[_]u32{};
                        defer if (leaves.len > 0) std.heap.page_allocator.free(leaves);
                        for (leaves) |pid| {
                            if (pane_data_map.get(pid)) |pd| {
                                if (pd.agent_state.state.load(.acquire) == .waiting) {
                                    has_waiting = true;
                                    if (pd.agent_state.is_agent_tab.load(.acquire)) {
                                        has_agent_tab_waiting = true;
                                    }
                                }
                            }
                        }
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

    fn getNodeBounds(node: *PaneNode) Rect {
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

    fn updateCursorBlink(self: *App) void {
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

    // -- Helpers --

    /// Convert a layout Rect to renderer layout_types Rect.
    /// Map GLFW key code to lowercase ASCII character for keybinding lookup.
    fn glfwKeyToChar(key: glfw.Key) ?u21 {
        const code: u32 = @intCast(@intFromEnum(key));
        // A-Z (GLFW codes 65-90) -> lowercase 'a'-'z'
        if (code >= 65 and code <= 90) return @intCast(code + 32);
        // 0-9 (GLFW codes 48-57) -> '0'-'9'
        if (code >= 48 and code <= 57) return @intCast(code);
        // Common punctuation
        return switch (key) {
            .minus => '-',
            .equal => '=',
            .left_bracket => '[',
            .right_bracket => ']',
            .backslash => '\\',
            .semicolon => ';',
            .apostrophe => '\'',
            .comma => ',',
            .period => '.',
            .slash => '/',
            .grave_accent => '`',
            .space => ' ',
            else => null,
        };
    }

    fn toRendererRect(rect: Rect) RendererRect {
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }

    /// Detect if cursor is on a window edge for resize (5px grab zone).
    const resize_grab = 5;
    fn detectWindowEdge(self: *App, x: i32, y: i32) WindowEdge {
        const fb = self.window.getFramebufferSize();
        const w: i32 = @intCast(fb.width);
        const h: i32 = @intCast(fb.height);
        return .{
            .left = x < resize_grab,
            .right = x >= w - resize_grab,
            .top = y < resize_grab,
            .bottom = y >= h - resize_grab,
        };
    }

    fn edgeIsAny(edge: WindowEdge) bool {
        return edge.left or edge.right or edge.top or edge.bottom;
    }

    /// Convert GLFW modifier flags to keybinding Modifiers.
    fn glfwModsToModifiers(mods: glfw.Mods) keybindings.Modifiers {
        return .{
            .ctrl = mods.control,
            .shift = mods.shift,
            .alt = mods.alt,
            .super = mods.super,
        };
    }

    fn generatePaneId(self: *App) u32 {
        // Simple incrementing ID across all tabs
        var max_id: u32 = 0;
        var it = self.pane_data.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* > max_id) max_id = entry.key_ptr.*;
        }
        return max_id + 1;
    }

    fn setupScreenChangeCallback(self: *App, pd: *PaneData) void {
        // Use a single global callback that requests a frame on the App.
        // All panes share the same callback since any screen change triggers a frame.
        _ = pd;
        g_screen_change_app = self;
    }

    /// Process bell state for a pane during render: consume trigger, draw flash, play sound.
    fn processBellForPane(self: *App, pd: *PaneData, bounds: RendererRect, backend: *OpenGLBackend) void {
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

    /// Bell callback: invoked from read thread when BEL byte detected in output.
    /// Context pointer points to the PaneData's BellState.
    fn bellCallback(ctx: ?*anyopaque) void {
        if (ctx) |c| {
            const state: *BellState = @ptrCast(@alignCast(c));
            _ = state.trigger();
        }
    }

    /// Process agent flash state for a pane during render: consume trigger, draw flash overlay.
    /// Mirrors processBellForPane pattern (D-16: 150ms amber flash at 15% alpha).
    fn processAgentFlashForPane(self: *App, pd: *PaneData, bounds: RendererRect, backend: *OpenGLBackend) void {
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
    fn extractVisibleLines(
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

    /// Agent output callback: invoked from read thread on every raw output event.
    /// Context pointer points to PaneData. Clears waiting state (D-04),
    /// resets idle timer, and schedules scan for next render snapshot.
    fn agentOutputCallback(ctx: ?*anyopaque) void {
        if (ctx) |c| {
            const pd: *PaneData = @ptrCast(@alignCast(c));
            // Suppress agent state transitions during resize (PTY redraws cause false positives)
            if (pd.suppress_agent_output.load(.acquire)) {
                pd.idle_tracker.recordOutputNow();
                return;
            }
            pd.agent_state.onOutput();
            pd.idle_tracker.recordOutputNow();
            pd.needs_agent_scan.store(true, .release);
        }
    }

    // -- Static GLFW callbacks --

    fn keyCallback(handle: *glfw.Window, key: glfw.Key, _: c_int, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
        const app = Window.getUserPointer(App, handle) orelse return;
        app.handleKeyInput(key, action, mods);
    }

    fn charCallback(handle: *glfw.Window, codepoint: u32) callconv(.c) void {
        const app = Window.getUserPointer(App, handle) orelse return;
        app.handleCharInput(codepoint);
    }

    fn framebufferSizeCallback(handle: *glfw.Window, width: c_int, height: c_int) callconv(.c) void {
        const app = Window.getUserPointer(App, handle) orelse return;
        // Ignore 0x0 (minimized window) — don't store it so restore sees correct old size
        if (width <= 0 or height <= 0) return;
        // Skip if size hasn't actually changed (e.g., restore from minimize)
        // to avoid terminal reflow that repositions cursor to top
        const old_w = app.new_fb_width.load(.acquire);
        const old_h = app.new_fb_height.load(.acquire);
        if (old_w == @as(u32, @intCast(width)) and old_h == @as(u32, @intCast(height))) {
            app.requestFrame(); // Still redraw, just don't resize terminal
            return;
        }
        // Suppress agent state transitions immediately — before any render thread
        // processes the resize and triggers PTY output that would flip state to working
        var pd_iter = app.pane_data.iterator();
        while (pd_iter.next()) |entry| {
            entry.value_ptr.*.suppress_agent_output.store(true, .release);
        }
        app.new_fb_width.store(@intCast(width), .release);
        app.new_fb_height.store(@intCast(height), .release);
        app.pending_resize.store(true, .release);
        app.requestFrame();
    }

    fn focusCallback(handle: *glfw.Window, focused: glfw.Bool) callconv(.c) void {
        const app = Window.getUserPointer(App, handle) orelse return;
        app.focused = @intFromEnum(focused) != 0;
        if (app.focused) {
            app.cursor_blink_timer = std.time.nanoTimestamp();
            app.cursor_visible = true;
            // Invalidate row caches to force full redraw after minimize/restore.
            // This avoids triggering pending_resize which would reflow the terminal.
            var pd_iter = app.pane_data.iterator();
            while (pd_iter.next()) |entry| {
                entry.value_ptr.*.row_cache.invalidate();
            }
        }
        app.requestFrame();
    }

    fn scrollCallback(handle: *glfw.Window, _: f64, yoffset: f64) callconv(.c) void {
        const app = Window.getUserPointer(App, handle) orelse return;
        // Mouse wheel scrollback: scroll 3 lines per notch
        if (yoffset != 0) {
            if (app.getFocusedPaneData()) |pd| {
                const lines: i32 = @intFromFloat(yoffset * 3.0);
                if (lines > 0) {
                    // Scroll up (into history)
                    pd.scroll_offset +|= @intCast(lines);
                    // Clamp to available history
                    const snapshot = pd.termio.lockTerminal();
                    const screens = @constCast(snapshot).getScreens();
                    const screen = screens.active;
                    const total_rows = screen.pages.total_rows;
                    const active_rows = screen.pages.rows;
                    pd.termio.unlockTerminal();
                    const max_scroll: u32 = if (total_rows > active_rows) @intCast(total_rows - active_rows) else 0;
                    pd.scroll_offset = @min(pd.scroll_offset, max_scroll);
                } else {
                    // Scroll down (toward live)
                    const down: u32 = @intCast(-lines);
                    if (down >= pd.scroll_offset) {
                        pd.scroll_offset = 0;
                    } else {
                        pd.scroll_offset -= down;
                    }
                }
            }
        }
        app.requestFrame();
    }

    fn mouseButtonCallback(handle: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
        const app = Window.getUserPointer(App, handle) orelse return;
        app.handleMouseButton(button, action, mods);
    }

    fn cursorPosCallback(handle: *glfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
        const app = Window.getUserPointer(App, handle) orelse return;
        app.handleCursorPos(xpos, ypos);
    }
};

/// Per-pane screen change callback (D-13).
/// Context pointer is the PaneData that produced output.
/// Only marks that pane's tab as having activity (not all tabs).
fn screenChangeCallback(ctx: ?*anyopaque) void {
    if (g_screen_change_app) |app| {
        // Skip activity marking during resize cooldown
        if (app.suppress_activity_frames.load(.acquire) == 0) {
            if (ctx) |raw| {
                const pd: *PaneData = @ptrCast(@alignCast(raw));
                const pane_tab_idx = pd.tab_index;
                const active_idx = app.tab_manager.active_idx;
                if (pane_tab_idx != active_idx and pane_tab_idx < app.tab_manager.tabs.items.len) {
                    app.tab_manager.tabs.items[pane_tab_idx].has_activity = true;
                }
            }
        }
        app.requestFrame();
    }
}

