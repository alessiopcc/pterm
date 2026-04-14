const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve ghostty dependency once (simd disabled for Windows C++ toolchain compat)
    const ghostty_dep = b.lazyDependency("ghostty", .{
        .simd = false,
    });

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build options: version string injected at compile time (D-09, D-15)
    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "Version string") orelse "0.1.0-dev");
    exe_mod.addOptions("build_options", options);

    if (ghostty_dep) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "pterm",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Shared ghostty-vt module for core components
    const ghostty_vt_mod = if (ghostty_dep) |dep| dep.module("ghostty-vt") else null;

    // Core observer module (no ghostty-vt dependency)
    const observer_mod = b.createModule(.{
        .root_source_file = b.path("src/core/observer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Core cell module (depends on ghostty-vt)
    const cell_mod = b.createModule(.{
        .root_source_file = b.path("src/core/cell.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (ghostty_vt_mod) |m| {
        cell_mod.addImport("ghostty-vt", m);
    }

    // Core terminal module (depends on ghostty-vt and observer)
    const terminal_mod = b.createModule(.{
        .root_source_file = b.path("src/core/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (ghostty_vt_mod) |m| {
        terminal_mod.addImport("ghostty-vt", m);
    }
    terminal_mod.addImport("observer.zig", observer_mod);

    // Core buffer module (scrollback ring buffer, D-12)
    const buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/core/buffer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Core selection module (D-14 copy-on-select)
    const selection_mod = b.createModule(.{
        .root_source_file = b.path("src/core/selection.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Core mouse module (SGR mouse protocol, CORE-10)
    const mouse_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mouse.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TermIO mailbox module (SPSC ring buffer)
    const mailbox_mod = b.createModule(.{
        .root_source_file = b.path("src/termio/mailbox.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TermIO parser module (D-07 dedicated parse thread)
    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/termio/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (ghostty_vt_mod) |m| {
        parser_mod.addImport("ghostty-vt", m);
    }
    parser_mod.addImport("terminal", terminal_mod);
    parser_mod.addImport("mailbox", mailbox_mod);

    // TermIO coordinator module (D-17 double-buffer swap)
    const termio_mod = b.createModule(.{
        .root_source_file = b.path("src/termio/termio.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (ghostty_vt_mod) |m| {
        termio_mod.addImport("ghostty-vt", m);
    }
    termio_mod.addImport("terminal", terminal_mod);
    termio_mod.addImport("observer", observer_mod);
    termio_mod.addImport("mailbox", mailbox_mod);
    termio_mod.addImport("parser", parser_mod);

    // Platform modules
    const platform_pty_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/pty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const platform_shell_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/shell.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TermIO reader module (PTY read thread, depends on platform + mailbox)
    const reader_mod = b.createModule(.{
        .root_source_file = b.path("src/termio/reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    reader_mod.addImport("mailbox", mailbox_mod);
    reader_mod.addImport("pty", platform_pty_mod);

    // Wire reader and pty modules into termio (PTY integration, Plan 01-05)
    termio_mod.addImport("reader", reader_mod);
    termio_mod.addImport("pty", platform_pty_mod);

    // -------------------------------------------------------
    // GPU Rendering & Windowing dependencies
    // -------------------------------------------------------

    // zigglgen: Generate OpenGL 3.3 core profile bindings at build time
    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"3.3",
        .profile = .core,
        .extensions = &.{},
    });

    // zglfw: GLFW windowing library (C lib + Zig module)
    const zglfw_dep = b.lazyDependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });

    // freetype: Font rasterization C library
    const freetype_dep = b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });

    // harfbuzz: Text shaping C library
    const harfbuzz_dep = b.lazyDependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
    });

    // Renderer types module (Color, CellInstance, RenderState, etc.)
    const renderer_types_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Renderer interface module (Renderer tagged union)
    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/Renderer.zig"),
        .target = target,
        .optimize = optimize,
    });
    renderer_mod.addImport("types", renderer_types_mod);

    // Shader source strings module
    const shaders_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/opengl/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Font types module (GlyphBitmap, GlyphKey, AtlasRegion, FontMetrics)
    const font_types_mod = b.createModule(.{
        .root_source_file = b.path("src/font/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shader program compilation module
    const program_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/opengl/Program.zig"),
        .target = target,
        .optimize = optimize,
    });
    program_mod.addImport("gl", gl_bindings);

    // Layout types module (lightweight Rect duplicate for renderer, avoids circular dep)
    const layout_types_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/layout_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // OpenGL backend module
    const opengl_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/opengl/Backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    opengl_backend_mod.addImport("gl", gl_bindings);
    opengl_backend_mod.addImport("renderer_types", renderer_types_mod);
    opengl_backend_mod.addImport("shaders", shaders_mod);
    opengl_backend_mod.addImport("Program.zig", program_mod);
    opengl_backend_mod.addImport("layout_types", layout_types_mod);

    // Wire GL bindings into renderer modules
    renderer_mod.addImport("gl", gl_bindings);
    renderer_mod.addImport("opengl_backend", opengl_backend_mod);
    shaders_mod.addImport("gl", gl_bindings);

    // Wire zglfw module and library into renderer for future use
    if (zglfw_dep) |dep| {
        renderer_mod.addImport("zglfw", dep.module("root"));
        renderer_mod.linkLibrary(dep.artifact("glfw"));
    }

    // Wire freetype into font module for future use
    if (freetype_dep) |dep| {
        font_types_mod.addImport("freetype", dep.module("freetype"));
        font_types_mod.linkLibrary(dep.artifact("freetype"));
    }

    // Wire harfbuzz into font module for future use
    if (harfbuzz_dep) |dep| {
        font_types_mod.addImport("harfbuzz", dep.module("harfbuzz"));
        font_types_mod.linkLibrary(dep.artifact("harfbuzz"));
    }

    // -------------------------------------------------------
    // Font pipeline modules
    // -------------------------------------------------------

    // FreeType rasterizer backend (Linux/Windows)
    const rasterizer_freetype_mod = b.createModule(.{
        .root_source_file = b.path("src/font/rasterizer_freetype.zig"),
        .target = target,
        .optimize = optimize,
    });
    rasterizer_freetype_mod.addImport("font_types", font_types_mod);
    if (freetype_dep) |dep| {
        rasterizer_freetype_mod.addImport("freetype", dep.module("freetype"));
        rasterizer_freetype_mod.linkLibrary(dep.artifact("freetype"));
    }

    // CoreText rasterizer backend (macOS only -- comptime excluded on other platforms)
    const rasterizer_coretext_mod = b.createModule(.{
        .root_source_file = b.path("src/font/rasterizer_coretext.zig"),
        .target = target,
        .optimize = optimize,
    });
    rasterizer_coretext_mod.addImport("font_types", font_types_mod);
    if (freetype_dep) |dep| {
        rasterizer_coretext_mod.linkLibrary(dep.artifact("freetype"));
    }
    if (target.result.os.tag == .macos) {
        rasterizer_coretext_mod.linkFramework("CoreText", .{});
        rasterizer_coretext_mod.linkFramework("CoreGraphics", .{});
        rasterizer_coretext_mod.linkFramework("CoreFoundation", .{});
    }

    // Platform-dispatched rasterizer (comptime selects backend)
    const rasterizer_mod = b.createModule(.{
        .root_source_file = b.path("src/font/Rasterizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    rasterizer_mod.addImport("rasterizer_freetype.zig", rasterizer_freetype_mod);
    rasterizer_mod.addImport("rasterizer_coretext.zig", rasterizer_coretext_mod);

    // GlyphAtlas module (shelf-packed texture atlas)
    const atlas_mod = b.createModule(.{
        .root_source_file = b.path("src/font/GlyphAtlas.zig"),
        .target = target,
        .optimize = optimize,
    });
    atlas_mod.addImport("font_types", font_types_mod);

    // Windows font discovery module
    const discovery_windows_mod = b.createModule(.{
        .root_source_file = b.path("src/font/discovery_windows.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Fontconfig font discovery module (Linux)
    const discovery_fontconfig_mod = b.createModule(.{
        .root_source_file = b.path("src/font/discovery_fontconfig.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .linux) {
        discovery_fontconfig_mod.linkSystemLibrary("fontconfig", .{});
    }

    // CoreText font discovery module (macOS)
    const discovery_coretext_mod = b.createModule(.{
        .root_source_file = b.path("src/font/discovery_coretext.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .macos) {
        discovery_coretext_mod.linkFramework("CoreText", .{});
        discovery_coretext_mod.linkFramework("CoreFoundation", .{});
    }

    // Platform-dispatched font discovery
    const discovery_mod = b.createModule(.{
        .root_source_file = b.path("src/font/discovery.zig"),
        .target = target,
        .optimize = optimize,
    });
    discovery_mod.addImport("discovery_fontconfig.zig", discovery_fontconfig_mod);
    discovery_mod.addImport("discovery_coretext.zig", discovery_coretext_mod);
    discovery_mod.addImport("discovery_windows.zig", discovery_windows_mod);

    // Wire discovery imports back (circular reference: discovery_*.zig imports discovery.zig for DiscoverResult)
    discovery_windows_mod.addImport("discovery.zig", discovery_mod);
    discovery_fontconfig_mod.addImport("discovery.zig", discovery_mod);
    discovery_coretext_mod.addImport("discovery.zig", discovery_mod);

    // Tofu box renderer module (D-06: missing glyph visualization)
    const tofu_mod = b.createModule(.{
        .root_source_file = b.path("src/font/tofu.zig"),
        .target = target,
        .optimize = optimize,
    });
    tofu_mod.addImport("font_types", font_types_mod);

    // FontGrid module (font collection with fallback chain)
    const fontgrid_mod = b.createModule(.{
        .root_source_file = b.path("src/font/FontGrid.zig"),
        .target = target,
        .optimize = optimize,
    });
    fontgrid_mod.addImport("font_types", font_types_mod);
    fontgrid_mod.addImport("glyph_atlas", atlas_mod);
    fontgrid_mod.addImport("rasterizer", rasterizer_mod);
    fontgrid_mod.addImport("discovery", discovery_mod);
    fontgrid_mod.addImport("tofu", tofu_mod);
    // Bundled Symbols Nerd Font Mono (OFL-licensed) embedded for fallback
    const bundled_nerd_font_mod = b.createModule(.{
        .root_source_file = b.path("assets/fonts/bundled_nerd_font.zig"),
        .target = target,
        .optimize = optimize,
    });
    fontgrid_mod.addImport("bundled_nerd_font", bundled_nerd_font_mod);
    if (freetype_dep) |dep| {
        fontgrid_mod.linkLibrary(dep.artifact("freetype"));
    }

    // Shaper module (HarfBuzz text shaping)
    const shaper_mod = b.createModule(.{
        .root_source_file = b.path("src/font/Shaper.zig"),
        .target = target,
        .optimize = optimize,
    });
    shaper_mod.addImport("font_types", font_types_mod);
    if (freetype_dep) |dep| {
        shaper_mod.linkLibrary(dep.artifact("freetype"));
    }
    if (harfbuzz_dep) |dep| {
        shaper_mod.addImport("harfbuzz", dep.module("harfbuzz"));
        shaper_mod.linkLibrary(dep.artifact("harfbuzz"));
    }

    // Wire shaper into fontgrid (post-declaration)
    fontgrid_mod.addImport("shaper", shaper_mod);

    // DirectWrite emoji rasterizer (Windows only)
    const dwrite_emoji_mod = b.createModule(.{
        .root_source_file = b.path("src/font/dwrite_emoji.zig"),
        .target = target,
        .optimize = optimize,
    });
    dwrite_emoji_mod.addImport("font_types", font_types_mod);
    if (target.result.os.tag == .windows) {
        dwrite_emoji_mod.addCSourceFile(.{
            .file = b.path("src/font/dwrite_emoji.cpp"),
            .flags = &.{"-std=c++17"},
        });
        dwrite_emoji_mod.addIncludePath(b.path("src/font"));
        dwrite_emoji_mod.linkSystemLibrary("dwrite", .{});
        dwrite_emoji_mod.linkSystemLibrary("d2d1", .{});
        dwrite_emoji_mod.linkSystemLibrary("ole32", .{});
        dwrite_emoji_mod.linkSystemLibrary("windowscodecs", .{});
    }

    // -------------------------------------------------------
    // Integration modules (Window, Input, Surface, App)
    // -------------------------------------------------------

    // GLFW window wrapper (D-14 resize snap, D-15 context detach)
    const window_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zglfw_dep) |dep| {
        window_mod.addImport("zglfw", dep.module("root"));
        window_mod.linkLibrary(dep.artifact("glfw"));
    }

    // Window icon (embedded RGBA pixel data for taskbar/title bar)
    const icon_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/icon.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zglfw_dep) |dep| {
        icon_mod.addImport("zglfw", dep.module("root"));
    }
    window_mod.addImport("icon", icon_mod);

    // Input encoder (GLFW keys -> VT sequences)
    const input_encoder_mod = b.createModule(.{
        .root_source_file = b.path("src/surface/InputEncoder.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zglfw_dep) |dep| {
        input_encoder_mod.addImport("zglfw", dep.module("root"));
    }

    // RenderState builder (terminal cells -> GPU instances)
    const render_state_mod = b.createModule(.{
        .root_source_file = b.path("src/surface/RenderState.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_state_mod.addImport("renderer_types", renderer_types_mod);
    render_state_mod.addImport("font_types", font_types_mod);
    render_state_mod.addImport("terminal", terminal_mod);
    render_state_mod.addImport("cell", cell_mod);
    render_state_mod.addImport("fontgrid", fontgrid_mod);
    render_state_mod.addImport("shaper", shaper_mod);
    render_state_mod.addImport("dwrite_emoji", dwrite_emoji_mod);
    if (ghostty_vt_mod) |m| {
        render_state_mod.addImport("ghostty-vt", m);
    }
    // Theme import for RendererPalette parameter (forward-declared here)
    if (freetype_dep) |dep| {
        render_state_mod.linkLibrary(dep.artifact("freetype"));
    }
    if (harfbuzz_dep) |dep| {
        render_state_mod.linkLibrary(dep.artifact("harfbuzz"));
    }

    // TOML parser dependency (sam701/zig-toml)
    const tomlz_dep = b.lazyDependency("tomlz", .{
        .target = target,
        .optimize = optimize,
    });

    // Config loader module (TOML file loading + import chain)
    const config_loader_mod = b.createModule(.{
        .root_source_file = b.path("src/config/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (tomlz_dep) |dep| {
        config_loader_mod.addImport("toml", dep.module("toml"));
    }

    // Config defaults module (platform path detection + dump-config)
    const config_defaults_mod = b.createModule(.{
        .root_source_file = b.path("src/config/defaults.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Config CLI module (argument parsing + overrides)
    const config_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/config/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Config env module (TERMP_* environment variable overrides)
    const config_env_mod = b.createModule(.{
        .root_source_file = b.path("src/config/env.zig"),
        .target = target,
        .optimize = optimize,
    });

    // App config module (full TOML-based config system)
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/Config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_mod.addImport("loader", config_loader_mod);
    config_mod.addImport("defaults", config_defaults_mod);
    config_mod.addImport("cli", config_cli_mod);
    config_mod.addImport("env", config_env_mod);

    // Wire Config.zig back into sub-modules that reference it
    config_loader_mod.addImport("Config.zig", config_mod);
    config_cli_mod.addImport("Config.zig", config_mod);
    config_cli_mod.addImport("defaults", config_defaults_mod);
    config_env_mod.addImport("Config.zig", config_mod);

    // Surface coordinator module (wires TermIO + Renderer + FontGrid + Input)
    const surface_mod = b.createModule(.{
        .root_source_file = b.path("src/surface/Surface.zig"),
        .target = target,
        .optimize = optimize,
    });
    surface_mod.addImport("termio", termio_mod);
    surface_mod.addImport("renderer", renderer_mod);
    surface_mod.addImport("renderer_types", renderer_types_mod);
    surface_mod.addImport("fontgrid", fontgrid_mod);
    surface_mod.addImport("font_types", font_types_mod);
    surface_mod.addImport("window", window_mod);
    surface_mod.addImport("input_encoder", input_encoder_mod);
    surface_mod.addImport("render_state", render_state_mod);
    surface_mod.addImport("terminal", terminal_mod);
    surface_mod.addImport("observer", observer_mod);
    surface_mod.addImport("opengl_backend", opengl_backend_mod);
    surface_mod.addImport("gl", gl_bindings);
    surface_mod.addImport("config", config_mod);
    surface_mod.addImport("selection", selection_mod);
    if (zglfw_dep) |dep| {
        surface_mod.addImport("zglfw", dep.module("root"));
        surface_mod.linkLibrary(dep.artifact("glfw"));
    }
    if (ghostty_vt_mod) |m| {
        surface_mod.addImport("ghostty-vt", m);
    }
    if (freetype_dep) |dep| {
        surface_mod.linkLibrary(dep.artifact("freetype"));
    }

    // App lifecycle module (init, run, deinit)
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/App.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("config", config_mod);
    app_mod.addImport("mouse", mouse_mod);
    app_mod.addImport("surface", surface_mod);
    app_mod.addImport("termio", termio_mod);
    app_mod.addImport("pty", platform_pty_mod);
    app_mod.addImport("shell", platform_shell_mod);
    app_mod.addImport("window", window_mod);
    app_mod.addImport("fontgrid", fontgrid_mod);
    app_mod.addImport("font_types", font_types_mod);
    app_mod.addImport("observer", observer_mod);
    app_mod.addImport("renderer_types", renderer_types_mod);
    app_mod.addImport("gl", gl_bindings);
    app_mod.addImport("opengl_backend", opengl_backend_mod);
    app_mod.addImport("render_state", render_state_mod);
    app_mod.addImport("layout_types", layout_types_mod);
    if (zglfw_dep) |dep| {
        app_mod.addImport("zglfw", dep.module("root"));
        app_mod.linkLibrary(dep.artifact("glfw"));
    }
    if (freetype_dep) |dep| {
        app_mod.linkLibrary(dep.artifact("freetype"));
    }
    if (harfbuzz_dep) |dep| {
        app_mod.linkLibrary(dep.artifact("harfbuzz"));
    }

    // Wire app module into main executable
    exe_mod.addImport("app", app_mod);
    exe_mod.addImport("config", config_mod);
    exe_mod.addImport("cli", config_cli_mod);
    exe_mod.addImport("defaults", config_defaults_mod);

    // Wire zglfw into exe_mod for GPU probe in main.zig (D-49)
    if (zglfw_dep) |dep| {
        exe_mod.addImport("zglfw", dep.module("root"));
        exe_mod.linkLibrary(dep.artifact("glfw"));
    }

    // -------------------------------------------------------
    // Layout module (binary tree pane model, tabs)
    // -------------------------------------------------------

    const layout_mod = b.createModule(.{
        .root_source_file = b.path("src/layout/layout.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Wire layout into surface, app, and config modules
    surface_mod.addImport("layout", layout_mod);
    app_mod.addImport("layout", layout_mod);
    config_mod.addImport("layout", layout_mod);
    config_loader_mod.addImport("layout", layout_mod);

    // -------------------------------------------------------
    // Keybinding system modules (defined early for exe + surface + test reuse)
    // -------------------------------------------------------

    // Keybinding types, parser, map builder, reserved keys
    const keybindings_mod = b.createModule(.{
        .root_source_file = b.path("src/config/keybindings.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Keybinding TUI (interactive configurator, D-22)
    const keybinding_tui_mod = b.createModule(.{
        .root_source_file = b.path("src/config/keybinding_tui.zig"),
        .target = target,
        .optimize = optimize,
    });
    keybinding_tui_mod.addImport("keybindings", keybindings_mod);

    // Wire keybindings into surface and app modules
    surface_mod.addImport("keybindings", keybindings_mod);
    app_mod.addImport("keybindings", keybindings_mod);

    // Wire keybinding TUI into main executable
    exe_mod.addImport("keybinding_tui", keybinding_tui_mod);

    // Test step
    const test_step = b.step("test", "Run unit tests");

    // VT compliance tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/vt_compliance.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (ghostty_vt_mod) |m| {
        test_mod.addImport("ghostty-vt", m);
    }
    test_mod.addImport("core_terminal", terminal_mod);
    test_mod.addImport("core_observer", observer_mod);
    test_mod.addImport("core_cell", cell_mod);

    const vt_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_vt_tests = b.addRunArtifact(vt_tests);
    test_step.dependOn(&run_vt_tests.step);

    // PTY tests (separate step due to ConPTY/test-runner interaction on Windows)
    // Run with: zig build test-pty
    const pty_test_step = b.step("test-pty", "Run PTY integration tests");
    const pty_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/pty_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pty_test_mod.addImport("platform_pty", platform_pty_mod);
    pty_test_mod.addImport("platform_shell", platform_shell_mod);
    pty_test_mod.addImport("mailbox", mailbox_mod);
    pty_test_mod.addImport("reader", reader_mod);

    const pty_tests = b.addTest(.{
        .root_module = pty_test_mod,
    });

    const run_pty_tests = b.addRunArtifact(pty_tests);
    pty_test_step.dependOn(&run_pty_tests.step);

    // Buffer tests (scrollback ring buffer)
    const buffer_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/buffer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    buffer_test_mod.addImport("core_buffer", buffer_mod);

    const buffer_tests = b.addTest(.{
        .root_module = buffer_test_mod,
    });
    const run_buffer_tests = b.addRunArtifact(buffer_tests);
    test_step.dependOn(&run_buffer_tests.step);

    // Mouse and selection tests
    const mouse_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/mouse_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mouse_test_mod.addImport("core_mouse", mouse_mod);
    mouse_test_mod.addImport("core_selection", selection_mod);

    const mouse_tests = b.addTest(.{
        .root_module = mouse_test_mod,
    });
    const run_mouse_tests = b.addRunArtifact(mouse_tests);
    test_step.dependOn(&run_mouse_tests.step);

    // Renderer types tests (Color, palette, CellInstance, FrameScheduler)
    const renderer_types_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/renderer/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_renderer_types_tests = b.addRunArtifact(renderer_types_tests);
    test_step.dependOn(&run_renderer_types_tests.step);

    // Font pipeline tests (GlyphAtlas, Rasterizer)
    const font_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/font_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    font_test_mod.addImport("font_types", font_types_mod);
    font_test_mod.addImport("glyph_atlas", atlas_mod);
    font_test_mod.addImport("rasterizer", rasterizer_mod);
    font_test_mod.addImport("fontgrid", fontgrid_mod);
    font_test_mod.addImport("tofu", tofu_mod);

    const font_tests = b.addTest(.{
        .root_module = font_test_mod,
    });
    // Link freetype for rasterizer/fontgrid tests
    if (freetype_dep) |dep| {
        font_test_mod.linkLibrary(dep.artifact("freetype"));
    }

    const run_font_tests = b.addRunArtifact(font_tests);
    test_step.dependOn(&run_font_tests.step);

    // Renderer tests (ortho projection, CellInstance size, Color, palette)
    const renderer_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/renderer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    renderer_test_mod.addImport("renderer_types", renderer_types_mod);
    renderer_test_mod.addImport("opengl_backend", opengl_backend_mod);

    const renderer_tests = b.addTest(.{
        .root_module = renderer_test_mod,
    });
    const run_renderer_tests = b.addRunArtifact(renderer_tests);
    test_step.dependOn(&run_renderer_tests.step);

    // InputEncoder tests (inline tests need zglfw import)
    const input_encoder_test_mod = b.createModule(.{
        .root_source_file = b.path("src/surface/InputEncoder.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zglfw_dep) |dep| {
        input_encoder_test_mod.addImport("zglfw", dep.module("root"));
    }
    const input_encoder_tests = b.addTest(.{
        .root_module = input_encoder_test_mod,
    });
    const run_input_encoder_tests = b.addRunArtifact(input_encoder_tests);
    test_step.dependOn(&run_input_encoder_tests.step);

    // Shaper tests (HarfBuzz buffer tests)
    const shaper_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/shaper_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    shaper_test_mod.addImport("shaper", shaper_mod);
    shaper_test_mod.addImport("font_types", font_types_mod);
    if (freetype_dep) |dep| {
        shaper_test_mod.linkLibrary(dep.artifact("freetype"));
    }
    if (harfbuzz_dep) |dep| {
        shaper_test_mod.addImport("harfbuzz", dep.module("harfbuzz"));
        shaper_test_mod.linkLibrary(dep.artifact("harfbuzz"));
    }
    const shaper_tests = b.addTest(.{ .root_module = shaper_test_mod });
    const run_shaper_tests = b.addRunArtifact(shaper_tests);
    test_step.dependOn(&run_shaper_tests.step);

    // Config system tests
    const config_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/config_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_test_mod.addImport("config", config_mod);
    config_test_mod.addImport("loader", config_loader_mod);
    config_test_mod.addImport("defaults", config_defaults_mod);
    config_test_mod.addImport("cli", config_cli_mod);
    config_test_mod.addImport("env", config_env_mod);
    if (tomlz_dep) |dep| {
        config_test_mod.addImport("toml", dep.module("toml"));
    }

    const config_tests = b.addTest(.{
        .root_module = config_test_mod,
    });
    const run_config_tests = b.addRunArtifact(config_tests);
    test_step.dependOn(&run_config_tests.step);

    // RenderState tests (shaping-aware rendering)
    const render_state_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/render_state_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_state_test_mod.addImport("renderer_types", renderer_types_mod);
    render_state_test_mod.addImport("font_types", font_types_mod);
    render_state_test_mod.addImport("cell", cell_mod);
    const render_state_tests = b.addTest(.{ .root_module = render_state_test_mod });
    const run_render_state_tests = b.addRunArtifact(render_state_tests);
    test_step.dependOn(&run_render_state_tests.step);

    // -------------------------------------------------------
    // Keybinding tests
    // -------------------------------------------------------

    // Keybinding inline tests (keybindings.zig)
    const keybinding_inline_test_mod = b.createModule(.{
        .root_source_file = b.path("src/config/keybindings.zig"),
        .target = target,
        .optimize = optimize,
    });
    const keybinding_inline_tests = b.addTest(.{ .root_module = keybinding_inline_test_mod });
    const run_keybinding_inline_tests = b.addRunArtifact(keybinding_inline_tests);
    test_step.dependOn(&run_keybinding_inline_tests.step);

    // Keybinding TUI inline tests (keybinding_tui.zig)
    const keybinding_tui_test_mod = b.createModule(.{
        .root_source_file = b.path("src/config/keybinding_tui.zig"),
        .target = target,
        .optimize = optimize,
    });
    keybinding_tui_test_mod.addImport("keybindings", keybindings_mod);
    const keybinding_tui_tests = b.addTest(.{ .root_module = keybinding_tui_test_mod });
    const run_keybinding_tui_tests = b.addRunArtifact(keybinding_tui_tests);
    test_step.dependOn(&run_keybinding_tui_tests.step);

    // Keybinding external tests (tests/keybinding_test.zig)
    const keybinding_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/keybinding_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    keybinding_test_mod.addImport("keybindings", keybindings_mod);
    keybinding_test_mod.addImport("keybinding_tui", keybinding_tui_mod);
    const keybinding_tests = b.addTest(.{ .root_module = keybinding_test_mod });
    const run_keybinding_tests = b.addRunArtifact(keybinding_tests);
    test_step.dependOn(&run_keybinding_tests.step);

    // -------------------------------------------------------
    // Layout tests (binary tree pane model, tabs)
    // -------------------------------------------------------

    const layout_test_mod = b.createModule(.{
        .root_source_file = b.path("src/layout/layout.zig"),
        .target = target,
        .optimize = optimize,
    });
    const layout_tests = b.addTest(.{ .root_module = layout_test_mod });
    const run_layout_tests = b.addRunArtifact(layout_tests);
    test_step.dependOn(&run_layout_tests.step);

    // -------------------------------------------------------
    // Theme and color palette modules
    // -------------------------------------------------------

    // Theme module (hex parsing, RendererPalette, palette conversion)
    const theme_mod = b.createModule(.{
        .root_source_file = b.path("src/config/theme.zig"),
        .target = target,
        .optimize = optimize,
    });
    theme_mod.addImport("renderer_types", renderer_types_mod);

    // Built-in themes module
    const builtin_themes_mod = b.createModule(.{
        .root_source_file = b.path("src/config/builtin_themes.zig"),
        .target = target,
        .optimize = optimize,
    });
    builtin_themes_mod.addImport("theme", theme_mod);

    // Cross-reference: theme needs builtin_themes for defaultRendererPalette
    theme_mod.addImport("builtin_themes", builtin_themes_mod);

    // Wire theme/builtin_themes into config_test_mod for palette tests
    config_test_mod.addImport("theme", theme_mod);
    config_test_mod.addImport("builtin_themes", builtin_themes_mod);
    config_test_mod.addImport("renderer_types", renderer_types_mod);

    // Wire theme into render_state_mod (for RendererPalette parameter)
    render_state_mod.addImport("theme", theme_mod);

    // File watcher module (config hot-reload, D-14)
    const watcher_mod = b.createModule(.{
        .root_source_file = b.path("src/config/watcher.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Theme tests
    const theme_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/theme_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    theme_test_mod.addImport("theme", theme_mod);
    theme_test_mod.addImport("builtin_themes", builtin_themes_mod);
    theme_test_mod.addImport("renderer_types", renderer_types_mod);

    const theme_tests = b.addTest(.{ .root_module = theme_test_mod });
    const run_theme_tests = b.addRunArtifact(theme_tests);
    test_step.dependOn(&run_theme_tests.step);

    // Wire theme and watcher modules into surface and app
    surface_mod.addImport("theme", theme_mod);
    surface_mod.addImport("builtin_themes", builtin_themes_mod);
    surface_mod.addImport("watcher", watcher_mod);
    app_mod.addImport("theme", theme_mod);
    app_mod.addImport("watcher", watcher_mod);
    app_mod.addImport("cli", config_cli_mod);
    app_mod.addImport("icon", icon_mod);

    // -------------------------------------------------------
    // Search modules (scrollback search)
    // -------------------------------------------------------

    const search_state_mod = b.createModule(.{
        .root_source_file = b.path("src/search/SearchState.zig"),
        .target = target,
        .optimize = optimize,
    });

    const search_overlay_mod = b.createModule(.{
        .root_source_file = b.path("src/search/SearchOverlay.zig"),
        .target = target,
        .optimize = optimize,
    });
    search_overlay_mod.addImport("SearchState.zig", search_state_mod);

    const matcher_mod = b.createModule(.{
        .root_source_file = b.path("src/search/matcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    matcher_mod.addImport("SearchState.zig", search_state_mod);

    // Barrel module for app import
    const search_mod = b.createModule(.{
        .root_source_file = b.path("src/search/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    search_mod.addImport("SearchState.zig", search_state_mod);
    search_mod.addImport("SearchOverlay.zig", search_overlay_mod);
    search_mod.addImport("matcher.zig", matcher_mod);

    // Wire search into app
    app_mod.addImport("search", search_mod);

    // SearchState inline tests
    const search_state_tests = b.addTest(.{ .root_module = search_state_mod });
    const run_search_state_tests = b.addRunArtifact(search_state_tests);
    test_step.dependOn(&run_search_state_tests.step);

    // matcher inline tests
    const matcher_tests = b.addTest(.{ .root_module = matcher_mod });
    const run_matcher_tests = b.addRunArtifact(matcher_tests);
    test_step.dependOn(&run_matcher_tests.step);

    // SearchOverlay inline tests
    const search_overlay_tests = b.addTest(.{ .root_module = search_overlay_mod });
    const run_search_overlay_tests = b.addRunArtifact(search_overlay_tests);
    test_step.dependOn(&run_search_overlay_tests.step);

    // URL detection modules (clickable URLs)
    // -------------------------------------------------------

    const url_detector_mod = b.createModule(.{
        .root_source_file = b.path("src/url/UrlDetector.zig"),
        .target = target,
        .optimize = optimize,
    });

    const url_state_mod = b.createModule(.{
        .root_source_file = b.path("src/url/UrlState.zig"),
        .target = target,
        .optimize = optimize,
    });
    url_state_mod.addImport("UrlDetector.zig", url_detector_mod);

    const open_url_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/open_url.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Barrel module for app import
    const url_mod = b.createModule(.{
        .root_source_file = b.path("src/url/url.zig"),
        .target = target,
        .optimize = optimize,
    });
    url_mod.addImport("UrlDetector.zig", url_detector_mod);
    url_mod.addImport("UrlState.zig", url_state_mod);

    // Wire URL modules into app
    app_mod.addImport("url", url_mod);
    app_mod.addImport("open_url", open_url_mod);

    // UrlDetector inline tests
    const url_detector_tests = b.addTest(.{ .root_module = url_detector_mod });
    const run_url_detector_tests = b.addRunArtifact(url_detector_tests);
    test_step.dependOn(&run_url_detector_tests.step);

    // UrlState inline tests
    const url_state_tests = b.addTest(.{ .root_module = url_state_mod });
    const run_url_state_tests = b.addRunArtifact(url_state_tests);
    test_step.dependOn(&run_url_state_tests.step);

    // open_url inline tests
    const open_url_tests = b.addTest(.{ .root_module = open_url_mod });
    const run_open_url_tests = b.addRunArtifact(open_url_tests);
    test_step.dependOn(&run_open_url_tests.step);

    // -------------------------------------------------------
    // Bell notification modules
    // -------------------------------------------------------

    const bell_state_mod = b.createModule(.{
        .root_source_file = b.path("src/bell/BellState.zig"),
        .target = target,
        .optimize = optimize,
    });

    const system_beep_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/system_beep.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Wire bell modules into app
    app_mod.addImport("bell_state", bell_state_mod);
    app_mod.addImport("system_beep", system_beep_mod);

    // BellState inline tests
    const bell_state_tests = b.addTest(.{ .root_module = bell_state_mod });
    const run_bell_state_tests = b.addRunArtifact(bell_state_tests);
    test_step.dependOn(&run_bell_state_tests.step);

    // system_beep inline tests
    const system_beep_tests = b.addTest(.{ .root_module = system_beep_mod });
    const run_system_beep_tests = b.addRunArtifact(system_beep_tests);
    test_step.dependOn(&run_system_beep_tests.step);

    // -------------------------------------------------------
    // Agent monitoring modules
    // -------------------------------------------------------

    const presets_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/presets.zig"),
        .target = target,
        .optimize = optimize,
    });

    const agent_state_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/AgentState.zig"),
        .target = target,
        .optimize = optimize,
    });

    const idle_tracker_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/IdleTracker.zig"),
        .target = target,
        .optimize = optimize,
    });

    const agent_detector_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/AgentDetector.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_detector_mod.addImport("presets", presets_mod);

    // Wire agent modules into app
    app_mod.addImport("agent_state", agent_state_mod);
    app_mod.addImport("agent_detector", agent_detector_mod);
    app_mod.addImport("idle_tracker", idle_tracker_mod);
    app_mod.addImport("presets", presets_mod);

    // Agent module inline tests
    const agent_state_tests = b.addTest(.{ .root_module = agent_state_mod });
    const run_agent_state_tests = b.addRunArtifact(agent_state_tests);
    test_step.dependOn(&run_agent_state_tests.step);

    const presets_tests = b.addTest(.{ .root_module = presets_mod });
    const run_presets_tests = b.addRunArtifact(presets_tests);
    test_step.dependOn(&run_presets_tests.step);

    const idle_tracker_tests = b.addTest(.{ .root_module = idle_tracker_mod });
    const run_idle_tracker_tests = b.addRunArtifact(idle_tracker_tests);
    test_step.dependOn(&run_idle_tracker_tests.step);

    const agent_detector_tests = b.addTest(.{ .root_module = agent_detector_mod });
    const run_agent_detector_tests = b.addRunArtifact(agent_detector_tests);
    test_step.dependOn(&run_agent_detector_tests.step);

    // -------------------------------------------------------
    // Notification modules
    // -------------------------------------------------------

    const notification_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/notification.zig"),
        .target = target,
        .optimize = optimize,
    });

    const notification_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/notification_manager.zig"),
        .target = target,
        .optimize = optimize,
    });
    notification_manager_mod.addImport("notification", notification_mod);

    // Wire notification modules into app
    app_mod.addImport("notification", notification_mod);
    app_mod.addImport("notification_manager", notification_manager_mod);

    // notification inline tests
    const notification_tests = b.addTest(.{ .root_module = notification_mod });
    const run_notification_tests = b.addRunArtifact(notification_tests);
    test_step.dependOn(&run_notification_tests.step);

    // notification_manager inline tests
    const notification_manager_tests = b.addTest(.{ .root_module = notification_manager_mod });
    const run_notification_manager_tests = b.addRunArtifact(notification_manager_tests);
    test_step.dependOn(&run_notification_manager_tests.step);

    // -------------------------------------------------------
    // Status bar renderer module
    // -------------------------------------------------------

    const status_bar_renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/layout/StatusBarRenderer.zig"),
        .target = target,
        .optimize = optimize,
    });
    status_bar_renderer_mod.addImport("agent_state", agent_state_mod);

    // Wire into app
    app_mod.addImport("status_bar_renderer", status_bar_renderer_mod);

    // StatusBarRenderer inline tests
    const status_bar_tests = b.addTest(.{ .root_module = status_bar_renderer_mod });
    const run_status_bar_tests = b.addRunArtifact(status_bar_tests);
    test_step.dependOn(&run_status_bar_tests.step);

    // -------------------------------------------------------
    // E2E test step (headless PTY-based platform tests)
    // -------------------------------------------------------
    const e2e_test_step = b.step("test-e2e", "Run E2E platform tests (spawns real shells)");

    // E2E harness module (shared across E2E tests)
    const e2e_harness_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/e2e_harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    e2e_harness_mod.addImport("pty", platform_pty_mod);

    // Shell spawn tests
    const shell_spawn_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/shell_spawn_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    shell_spawn_test_mod.addImport("e2e_harness", e2e_harness_mod);
    shell_spawn_test_mod.addImport("pty", platform_pty_mod);
    const shell_spawn_tests = b.addTest(.{ .root_module = shell_spawn_test_mod });
    const run_shell_spawn = b.addRunArtifact(shell_spawn_tests);
    e2e_test_step.dependOn(&run_shell_spawn.step);

    // CLI flags tests (spawns pterm binary, needs it built first)
    const cli_flags_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/cli_flags_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_flags_tests = b.addTest(.{ .root_module = cli_flags_test_mod });
    const run_cli_flags = b.addRunArtifact(cli_flags_tests);
    run_cli_flags.step.dependOn(&exe.step);
    e2e_test_step.dependOn(&run_cli_flags.step);

    // Env vars tests
    const env_vars_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/env_vars_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    env_vars_test_mod.addImport("e2e_harness", e2e_harness_mod);
    env_vars_test_mod.addImport("pty", platform_pty_mod);
    const env_vars_tests = b.addTest(.{ .root_module = env_vars_test_mod });
    const run_env_vars = b.addRunArtifact(env_vars_tests);
    e2e_test_step.dependOn(&run_env_vars.step);

    // Platform PTY tests
    const platform_pty_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/platform_pty_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_pty_test_mod.addImport("pty", platform_pty_mod);
    const platform_pty_e2e_tests = b.addTest(.{ .root_module = platform_pty_test_mod });
    const run_platform_pty_e2e = b.addRunArtifact(platform_pty_e2e_tests);
    e2e_test_step.dependOn(&run_platform_pty_e2e.step);

    // Stability tests
    const stability_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/stability_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stability_test_mod.addImport("e2e_harness", e2e_harness_mod);
    stability_test_mod.addImport("pty", platform_pty_mod);
    const stability_tests = b.addTest(.{ .root_module = stability_test_mod });
    const run_stability = b.addRunArtifact(stability_tests);
    e2e_test_step.dependOn(&run_stability.step);

    // Pane/tab lifecycle tests (headless, no PTY or GPU needed)
    const pane_tab_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/pane_tab_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pane_tab_test_mod.addImport("layout", layout_mod);
    const pane_tab_tests = b.addTest(.{ .root_module = pane_tab_test_mod });
    const run_pane_tab = b.addRunArtifact(pane_tab_tests);
    e2e_test_step.dependOn(&run_pane_tab.step);

    // Agent detection tests (headless, no PTY or GPU needed)
    const agent_detection_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/agent_detection_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_detection_test_mod.addImport("agent_detector", agent_detector_mod);
    const agent_detection_tests = b.addTest(.{ .root_module = agent_detection_test_mod });
    const run_agent_detection = b.addRunArtifact(agent_detection_tests);
    e2e_test_step.dependOn(&run_agent_detection.step);

    // Config loading + hot-reload tests (D-37)
    const config_e2e_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/config_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const config_e2e_tests = b.addTest(.{ .root_module = config_e2e_test_mod });
    const run_config_e2e = b.addRunArtifact(config_e2e_tests);
    run_config_e2e.step.dependOn(&exe.step);
    e2e_test_step.dependOn(&run_config_e2e.step);
}
