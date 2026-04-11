const std = @import("std");
const App = @import("app").App;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args
    var perf_logging = false;
    var debug_keys = false;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip exe name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--perf")) perf_logging = true;
        if (std.mem.eql(u8, arg, "--debug-keys")) debug_keys = true;
    }

    var app = try App.init(allocator, .{ .perf_logging = perf_logging, .debug_keys = debug_keys });
    defer app.deinit();

    try app.start();
    try app.run();
}
