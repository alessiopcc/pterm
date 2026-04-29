/// Background GitHub release version check.
///
/// Spawns a detached worker thread that fetches the latest release tag from
/// the GitHub API and, if it is newer than the running build, exposes the
/// new version via atomics so the render thread can paint a notification.
///
/// Network fetch is delegated to `curl` (ships in Windows 10+, macOS, and
/// every mainstream Linux distro) to avoid pulling TLS into the binary just
/// for a once-per-launch check. If curl is missing or the request fails the
/// flag simply stays false — it is best-effort.
const std = @import("std");
const builtin = @import("builtin");

pub const RELEASE_URL = "https://github.com/alessiopcc/pterm/releases/latest";
const API_URL = "https://api.github.com/repos/alessiopcc/pterm/releases/latest";

pub const VersionCheck = struct {
    update_available: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    latest_version_buf: [32]u8 = [_]u8{0} ** 32,
    latest_version_len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    thread: ?std.Thread = null,
    current_version: []const u8 = "",
    allocator: std.mem.Allocator = undefined,

    pub fn start(self: *VersionCheck, allocator: std.mem.Allocator, current_version: []const u8) void {
        self.allocator = allocator;
        self.current_version = current_version;
        const t = std.Thread.spawn(.{}, worker, .{self}) catch return;
        self.thread = t;
    }

    pub fn deinit(self: *VersionCheck) void {
        // Detach so app shutdown doesn't block on a stuck network fetch.
        if (self.thread) |t| {
            t.detach();
            self.thread = null;
        }
    }

    pub fn isUpdateAvailable(self: *const VersionCheck) bool {
        return self.update_available.load(.acquire);
    }

    pub fn latestVersion(self: *const VersionCheck) []const u8 {
        const len = self.latest_version_len.load(.acquire);
        return self.latest_version_buf[0..len];
    }

    fn worker(self: *VersionCheck) void {
        const json = fetch(self.allocator) catch return;
        defer self.allocator.free(json);

        const tag = parseTagName(json) orelse return;
        const stripped = if (tag.len > 0 and (tag[0] == 'v' or tag[0] == 'V')) tag[1..] else tag;

        if (compareSemver(self.current_version, stripped) != .lt) return;

        const copy_len = @min(stripped.len, self.latest_version_buf.len);
        @memcpy(self.latest_version_buf[0..copy_len], stripped[0..copy_len]);
        self.latest_version_len.store(@intCast(copy_len), .release);
        self.update_available.store(true, .release);
    }

    fn fetch(allocator: std.mem.Allocator) ![]u8 {
        var argv = [_][]const u8{
            "curl",
            "-s",
            "-L",
            "--max-time",
            "5",
            "-A",
            "pterm-version-check",
            "-H",
            "Accept: application/vnd.github+json",
            API_URL,
        };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.stdin_behavior = .Ignore;
        try child.spawn();
        const data = (child.stdout orelse {
            _ = child.wait() catch {};
            return error.NoStdout;
        }).readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            _ = child.wait() catch {};
            return err;
        };
        _ = child.wait() catch {};
        return data;
    }

    fn parseTagName(json: []const u8) ?[]const u8 {
        const key = "\"tag_name\"";
        const idx = std.mem.indexOf(u8, json, key) orelse return null;
        var i = idx + key.len;
        while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) : (i += 1) {}
        if (i >= json.len or json[i] != '"') return null;
        i += 1;
        const tag_start = i;
        while (i < json.len and json[i] != '"') : (i += 1) {}
        if (i >= json.len) return null;
        return json[tag_start..i];
    }

    fn compareSemver(a: []const u8, b: []const u8) std.math.Order {
        var ait = std.mem.splitScalar(u8, a, '.');
        var bit = std.mem.splitScalar(u8, b, '.');
        while (true) {
            const ap = ait.next();
            const bp = bit.next();
            if (ap == null and bp == null) return .eq;
            const an = parseLeadingInt(ap orelse "0");
            const bn = parseLeadingInt(bp orelse "0");
            if (an < bn) return .lt;
            if (an > bn) return .gt;
        }
    }

    /// Parse digits from the start of `s`. Stops at the first non-digit so
    /// "1-rc2" yields 1. Empty / no-leading-digit input returns 0.
    fn parseLeadingInt(s: []const u8) u32 {
        var n: u32 = 0;
        var saw_digit = false;
        for (s) |c| {
            if (c < '0' or c > '9') break;
            saw_digit = true;
            n = n *% 10 +% @as(u32, c - '0');
        }
        return if (saw_digit) n else 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "parseTagName extracts v-prefixed tag" {
    const json =
        \\{"url":"...","tag_name":"v1.2.3","name":"Release 1.2.3"}
    ;
    const tag = VersionCheck.parseTagName(json) orelse return error.MissingTag;
    try std.testing.expectEqualStrings("v1.2.3", tag);
}

test "parseTagName tolerates whitespace" {
    const json =
        \\{ "tag_name" :   "2.0.0" }
    ;
    const tag = VersionCheck.parseTagName(json) orelse return error.MissingTag;
    try std.testing.expectEqualStrings("2.0.0", tag);
}

test "parseTagName returns null when missing" {
    const json = "{\"foo\":\"bar\"}";
    try std.testing.expect(VersionCheck.parseTagName(json) == null);
}

test "compareSemver basic ordering" {
    try std.testing.expectEqual(std.math.Order.lt, VersionCheck.compareSemver("1.1.0", "1.2.0"));
    try std.testing.expectEqual(std.math.Order.gt, VersionCheck.compareSemver("1.2.0", "1.1.0"));
    try std.testing.expectEqual(std.math.Order.eq, VersionCheck.compareSemver("1.1.0", "1.1.0"));
}

test "compareSemver handles uneven length" {
    try std.testing.expectEqual(std.math.Order.lt, VersionCheck.compareSemver("1.1", "1.1.1"));
    try std.testing.expectEqual(std.math.Order.gt, VersionCheck.compareSemver("2", "1.9.9"));
}

test "compareSemver handles non-numeric suffix" {
    try std.testing.expectEqual(std.math.Order.lt, VersionCheck.compareSemver("1.0.0", "1.0.1-rc1"));
}
