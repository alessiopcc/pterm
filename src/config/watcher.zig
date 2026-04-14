/// File watcher for config hot-reload.
///
/// Implements polling-based file change detection with debouncing.
/// Watches config.toml and all imported files. Fires callback when
/// changes are detected after debounce period.
///
/// Platform-specific watchers (inotify, FSEvents, ReadDirectoryChangesW)
/// are a future optimization; polling at 1.5s intervals is sufficient for v1.
const std = @import("std");

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    paths: [][]const u8,
    mtimes: []i128,
    poll_interval_ns: i128,
    last_poll: i128,
    debounce_ns: i128,
    last_change: i128,
    callback: *const fn () void,

    /// Initialize a file watcher for the given paths.
    /// The callback fires when any watched file changes (after debounce).
    pub fn init(
        allocator: std.mem.Allocator,
        paths: []const []const u8,
        callback: *const fn () void,
    ) !FileWatcher {
        const owned_paths = try allocator.alloc([]u8, paths.len);
        errdefer allocator.free(owned_paths);

        var initialized: usize = 0;
        errdefer {
            for (owned_paths[0..initialized]) |p| allocator.free(p);
        }

        for (paths, 0..) |path, i| {
            owned_paths[i] = try allocator.dupe(u8, path);
            initialized = i + 1;
        }

        const mtimes = try allocator.alloc(i128, paths.len);
        errdefer allocator.free(mtimes);

        // Initialize mtimes to current values
        for (0..paths.len) |i| {
            mtimes[i] = getFileMtime(owned_paths[i]) orelse 0;
        }

        const now = std.time.nanoTimestamp();

        return FileWatcher{
            .allocator = allocator,
            .paths = @ptrCast(owned_paths),
            .mtimes = mtimes,
            .poll_interval_ns = 1_500_000_000, // 1.5 seconds
            .last_poll = now,
            .debounce_ns = 200_000_000, // 200ms debounce pitfall 6
            .last_change = 0,
            .callback = callback,
        };
    }

    /// Release all owned memory.
    pub fn deinit(self: *FileWatcher) void {
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);
        self.allocator.free(self.mtimes);
    }

    /// Call from main event loop. Checks if enough time has passed, then polls mtimes.
    /// If any file changed and debounce period elapsed, fires callback.
    pub fn poll(self: *FileWatcher) void {
        const now = std.time.nanoTimestamp();

        // Rate-limit polling
        if (now - self.last_poll < self.poll_interval_ns) return;
        self.last_poll = now;

        // Check each watched file for mtime changes
        var changed = false;
        for (self.paths, 0..) |path, i| {
            const mtime = getFileMtime(path) orelse continue;
            if (mtime != self.mtimes[i]) {
                self.mtimes[i] = mtime;
                changed = true;
            }
        }

        if (changed) {
            self.last_change = now;
        }

        // Debounce: fire callback only if change detected AND debounce elapsed
        if (self.last_change > 0 and now - self.last_change >= self.debounce_ns) {
            self.last_change = 0;
            self.callback();
        }
    }

    /// Update the set of watched paths (e.g., after config reload discovers new imports).
    pub fn updatePaths(self: *FileWatcher, new_paths: []const []const u8) !void {
        // Free old paths
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);
        self.allocator.free(self.mtimes);

        // Allocate new
        const owned = try self.allocator.alloc([]u8, new_paths.len);
        for (new_paths, 0..) |path, i| {
            owned[i] = try self.allocator.dupe(u8, path);
        }
        self.paths = @ptrCast(owned);
        self.mtimes = try self.allocator.alloc(i128, new_paths.len);
        for (0..new_paths.len) |i| {
            self.mtimes[i] = getFileMtime(self.paths[i]) orelse 0;
        }
    }
};

/// Get the modification time of a file, or null if the file cannot be accessed.
fn getFileMtime(path: []const u8) ?i128 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    return stat.mtime;
}
