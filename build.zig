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
}
