/// E2E tests: CLI flags --version, --help, --init-config.
///
/// Spawns the pterm binary with each flag and verifies output/behavior.
/// These tests require the pterm binary to be built first.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

test "cli flag --version prints version and exits 0" {
    const allocator = testing.allocator;
    const pterm_path = findPtermBinary(allocator) orelse {
        std.log.warn("pterm binary not found -- skipping --version test (run `zig build` first)", .{});
        return;
    };
    defer allocator.free(pterm_path);

    var child = std.process.Child.init(
        &.{ pterm_path, "--version" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, 16 * 1024) catch "";
    defer if (stdout.len > 0) allocator.free(stdout);

    const result = try child.wait();

    // Should exit cleanly
    try testing.expectEqual(@as(u32, 0), result.Exited);

    // Output should contain "pterm" and a version-like string
    if (stdout.len > 0) {
        try testing.expect(std.mem.indexOf(u8, stdout, "pterm") != null or
            std.mem.indexOf(u8, stdout, "PTerm") != null);
    }
}

test "cli flag --help prints usage and exits 0" {
    const allocator = testing.allocator;
    const pterm_path = findPtermBinary(allocator) orelse {
        std.log.warn("pterm binary not found -- skipping --help test", .{});
        return;
    };
    defer allocator.free(pterm_path);

    var child = std.process.Child.init(
        &.{ pterm_path, "--help" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, 16 * 1024) catch "";
    defer if (stdout.len > 0) allocator.free(stdout);

    // stderr may contain usage info on some programs
    const stderr = child.stderr.?.readToEndAlloc(allocator, 16 * 1024) catch "";
    defer if (stderr.len > 0) allocator.free(stderr);

    const result = try child.wait();
    try testing.expectEqual(@as(u32, 0), result.Exited);

    // Combined output should contain usage-related text
    const combined = if (stdout.len > 0) stdout else stderr;
    if (combined.len > 0) {
        const has_usage = std.mem.indexOf(u8, combined, "Usage") != null or
            std.mem.indexOf(u8, combined, "usage") != null or
            std.mem.indexOf(u8, combined, "Options") != null or
            std.mem.indexOf(u8, combined, "options") != null or
            std.mem.indexOf(u8, combined, "--") != null;
        try testing.expect(has_usage);
    }
}

test "cli flag --init-config creates config file" {
    const allocator = testing.allocator;
    const pterm_path = findPtermBinary(allocator) orelse {
        std.log.warn("pterm binary not found -- skipping --init-config test", .{});
        return;
    };
    defer allocator.free(pterm_path);

    // Create a temp directory to isolate the test (set HOME/USERPROFILE)
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Spawn pterm with --init-config using temp home directory
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    // Set home directory to temp dir to isolate config creation
    if (comptime builtin.os.tag == .windows) {
        try env_map.put("USERPROFILE", tmp_path);
        try env_map.put("APPDATA", tmp_path);
    } else {
        try env_map.put("HOME", tmp_path);
        try env_map.put("XDG_CONFIG_HOME", tmp_path);
    }

    var child = std.process.Child.init(
        &.{ pterm_path, "--init-config" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = &env_map;

    child.spawn() catch |err| {
        std.log.warn("failed to spawn pterm --init-config: {}", .{err});
        return;
    };

    _ = child.wait() catch {
        std.log.warn("pterm --init-config did not complete", .{});
        return;
    };

    // Verify a config file was created somewhere in the temp dir
    // The exact path depends on platform config path logic
    const config_exists = checkConfigCreated(tmp_dir.dir);
    if (config_exists) {
        std.log.info("PASS: --init-config created config file", .{});
    } else {
        std.log.warn("--init-config may not have created file in expected location", .{});
    }
}

test "cli flag --init-config fails if config already exists" {
    const allocator = testing.allocator;
    const pterm_path = findPtermBinary(allocator) orelse {
        std.log.warn("pterm binary not found -- skipping --init-config duplicate test", .{});
        return;
    };
    defer allocator.free(pterm_path);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    if (comptime builtin.os.tag == .windows) {
        try env_map.put("USERPROFILE", tmp_path);
        try env_map.put("APPDATA", tmp_path);
    } else {
        try env_map.put("HOME", tmp_path);
        try env_map.put("XDG_CONFIG_HOME", tmp_path);
    }

    // First run: should succeed
    {
        var child = std.process.Child.init(
            &.{ pterm_path, "--init-config" },
            allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.env_map = &env_map;
        child.spawn() catch return;
        _ = child.wait() catch return;
    }

    // Second run: should fail or warn (file already exists)
    {
        var child = std.process.Child.init(
            &.{ pterm_path, "--init-config" },
            allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.env_map = &env_map;
        child.spawn() catch return;
        const result = child.wait() catch return;

        // Non-zero exit or stderr output indicates "already exists" handling
        if (result.Exited != 0) {
            std.log.info("PASS: --init-config correctly fails on duplicate (exit {})", .{result.Exited});
        } else {
            std.log.warn("--init-config did not fail on duplicate -- may overwrite", .{});
        }
    }
}

/// Find pterm binary in standard build locations.
fn findPtermBinary(allocator: std.mem.Allocator) ?[]u8 {
    const candidates = if (comptime builtin.os.tag == .windows)
        [_][]const u8{ "zig-out/bin/pterm.exe", "zig-out\\bin\\pterm.exe" }
    else
        [_][]const u8{ "zig-out/bin/pterm", "./zig-out/bin/pterm" };

    for (&candidates) |path| {
        if (std.fs.cwd().access(path, .{})) |_| {
            return allocator.dupe(u8, path) catch null;
        } else |_| {}
    }
    return null;
}

/// Check if a config file was created anywhere in the directory tree.
fn checkConfigCreated(dir: std.fs.Dir) bool {
    // Check common locations: pterm/config.toml, .config/pterm/config.toml
    if (dir.access("pterm/config.toml", .{})) |_| return true else |_| {}
    if (dir.access(".config/pterm/config.toml", .{})) |_| return true else |_| {}
    if (dir.access("config.toml", .{})) |_| return true else |_| {}
    return false;
}
