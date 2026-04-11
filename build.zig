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

    if (ghostty_dep) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "termp",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
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
    // Phase 2: GPU Rendering & Windowing dependencies
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
    // Phase 2 Plan 02: Font pipeline modules
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

    // CoreText font discovery module (macOS)
    const discovery_coretext_mod = b.createModule(.{
        .root_source_file = b.path("src/font/discovery_coretext.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    if (freetype_dep) |dep| {
        fontgrid_mod.linkLibrary(dep.artifact("freetype"));
    }

    // Shaper module (minimal HarfBuzz stub for Phase 2)
    const shaper_mod = b.createModule(.{
        .root_source_file = b.path("src/font/Shaper.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = shaper_mod;

    // -------------------------------------------------------
    // Phase 2 Plan 04: Integration modules (Window, Input, Surface, App)
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
    if (ghostty_vt_mod) |m| {
        render_state_mod.addImport("ghostty-vt", m);
    }
    if (freetype_dep) |dep| {
        render_state_mod.linkLibrary(dep.artifact("freetype"));
    }

    // App config module (hardcoded defaults for Phase 2)
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/app/Config.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    app_mod.addImport("surface", surface_mod);
    app_mod.addImport("termio", termio_mod);
    app_mod.addImport("pty", platform_pty_mod);
    app_mod.addImport("shell", platform_shell_mod);
    app_mod.addImport("window", window_mod);
    app_mod.addImport("fontgrid", fontgrid_mod);
    app_mod.addImport("font_types", font_types_mod);
    app_mod.addImport("observer", observer_mod);
    app_mod.addImport("renderer_types", renderer_types_mod);
    if (zglfw_dep) |dep| {
        app_mod.addImport("zglfw", dep.module("root"));
        app_mod.linkLibrary(dep.artifact("glfw"));
    }
    if (freetype_dep) |dep| {
        app_mod.linkLibrary(dep.artifact("freetype"));
    }

    // Wire app module into main executable
    exe_mod.addImport("app", app_mod);

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
}
