/// Search module barrel file.
/// Re-exports SearchState, SearchOverlay, and matcher for use by App.zig.
pub const SearchState = @import("SearchState.zig");
pub const SearchOverlay = @import("SearchOverlay.zig");
pub const matcher = @import("matcher.zig");
