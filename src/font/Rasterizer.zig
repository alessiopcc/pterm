/// Platform-dispatched glyph rasterizer.
///
/// FreeType on Linux/Windows, CoreText on macOS.
/// Both backends implement an identical interface for glyph rasterization
/// and font metric computation.
const builtin = @import("builtin");

pub const Rasterizer = switch (builtin.os.tag) {
    .macos => @import("rasterizer_coretext.zig").CoreTextRasterizer,
    else => @import("rasterizer_freetype.zig").FreeTypeRasterizer,
};
