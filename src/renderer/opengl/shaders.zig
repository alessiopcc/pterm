/// GLSL 330 core shader source strings for the OpenGL renderer.
///
/// Three render passes (D-04):
///   Pass 1: Cell backgrounds (bg_vertex_src / bg_fragment_src)
///   Pass 2: Glyph text (text_vertex_src / text_fragment_src)
///   Pass 3: Cursor overlay (cursor_vertex_src / cursor_fragment_src)

// ---------------------------------------------------------
// Shared GLSL helper: unpack RGBA from u32 (0xRRGGBBAA)
// ---------------------------------------------------------
const unpack_color_fn =
    \\vec4 unpackColor(uint rgba) {
    \\    return vec4(
    \\        float((rgba >> 24u) & 0xFFu) / 255.0,
    \\        float((rgba >> 16u) & 0xFFu) / 255.0,
    \\        float((rgba >>  8u) & 0xFFu) / 255.0,
    \\        float((rgba       ) & 0xFFu) / 255.0
    \\    );
    \\}
    \\
;

// ---------------------------------------------------------
// Pass 1: Cell Backgrounds
// ---------------------------------------------------------

pub const bg_vertex_src =
    \\#version 330 core
    \\
    \\// Per-vertex quad corner (0..1)
    \\layout (location = 0) in vec2 aQuadPos;
    \\
    \\// Per-instance attributes
    \\layout (location = 1) in uvec2 aGridPos;    // col, row
    \\layout (location = 2) in uvec4 aAtlasRect;  // unused for bg pass
    \\layout (location = 3) in ivec2 aBearing;     // unused for bg pass
    \\layout (location = 4) in uint  aFgColor;     // unused for bg pass
    \\layout (location = 5) in uint  aBgColor;     // packed RGBA
    \\layout (location = 6) in uint  aFlags;       // unused for bg pass
    \\
    \\uniform mat4 uProjection;
    \\uniform vec2 uCellSize;    // pixels per cell
    \\uniform vec2 uGridOffset;  // top-left padding
    \\
    \\flat out vec4 vBgColor;
    \\
    \\
++ unpack_color_fn ++
    \\void main() {
    \\    vec2 cellOrigin = uGridOffset + vec2(aGridPos) * uCellSize;
    \\    vec2 pos = cellOrigin + aQuadPos * uCellSize;
    \\    gl_Position = uProjection * vec4(pos, 0.0, 1.0);
    \\    vBgColor = unpackColor(aBgColor);
    \\}
    \\
;

pub const bg_fragment_src =
    \\#version 330 core
    \\
    \\flat in vec4 vBgColor;
    \\out vec4 FragColor;
    \\
    \\void main() {
    \\    FragColor = vBgColor;
    \\}
    \\
;

// ---------------------------------------------------------
// Pass 2: Glyph Text
// ---------------------------------------------------------

pub const text_vertex_src =
    \\#version 330 core
    \\
    \\// Per-vertex quad corner (0..1)
    \\layout (location = 0) in vec2 aQuadPos;
    \\
    \\// Per-instance attributes
    \\layout (location = 1) in uvec2 aGridPos;    // col, row
    \\layout (location = 2) in uvec4 aAtlasRect;  // x, y, w, h in atlas
    \\layout (location = 3) in ivec2 aBearing;     // glyph bearing offset
    \\layout (location = 4) in uint  aFgColor;     // packed RGBA
    \\layout (location = 5) in uint  aBgColor;     // unused for text pass
    \\layout (location = 6) in uint  aFlags;       // bit flags
    \\
    \\uniform mat4 uProjection;
    \\uniform vec2 uCellSize;       // pixels per cell
    \\uniform vec2 uAtlasSize;      // grayscale atlas texture dimensions
    \\uniform vec2 uColorAtlasSize; // color atlas texture dimensions
    \\uniform vec2 uGridOffset;     // top-left padding
    \\uniform float uTextScale;     // glyph scale factor (1.0 = normal)
    \\
    \\out vec2 vTexCoord;
    \\flat out vec4 vFgColor;
    \\flat out uint vFlags;
    \\
    \\
++ unpack_color_fn ++
    \\void main() {
    \\    vec2 cellOrigin = uGridOffset + vec2(aGridPos) * uCellSize * uTextScale;
    \\    vec2 glyphOffset = vec2(aBearing) * uTextScale;
    \\    vec2 glyphSize = vec2(aAtlasRect.zw) * uTextScale;
    \\
    \\    vec2 pos = cellOrigin + glyphOffset + aQuadPos * glyphSize;
    \\    gl_Position = uProjection * vec4(pos, 0.0, 1.0);
    \\
    \\    // Select atlas size based on whether this is a color glyph
    \\    uint COLOR_GLYPH = 0x0010u;
    \\    vec2 atlasSize = ((aFlags & COLOR_GLYPH) != 0u) ? uColorAtlasSize : uAtlasSize;
    \\    vTexCoord = (vec2(aAtlasRect.xy) + aQuadPos * vec2(aAtlasRect.zw)) / atlasSize;
    \\
    \\    vFgColor = unpackColor(aFgColor);
    \\    vFlags = aFlags;
    \\}
    \\
;

pub const text_fragment_src =
    \\#version 330 core
    \\
    \\in vec2 vTexCoord;
    \\flat in vec4 vFgColor;
    \\flat in uint vFlags;
    \\
    \\uniform sampler2D uAtlasTexture;       // texture unit 0: grayscale
    \\uniform sampler2D uColorAtlasTexture;  // texture unit 1: RGBA color
    \\
    \\out vec4 FragColor;
    \\
    \\void main() {
    \\    uint COLOR_GLYPH = 0x0010u;
    \\    if ((vFlags & COLOR_GLYPH) != 0u) {
    \\        // Color emoji: sample RGBA directly from color atlas
    \\        vec4 texel = texture(uColorAtlasTexture, vTexCoord);
    \\        if (texel.a < 0.01) discard;
    \\        FragColor = texel;
    \\    } else {
    \\        // Grayscale text: use red channel as alpha, tint with fg color
    \\        float alpha = texture(uAtlasTexture, vTexCoord).r;
    \\        if (alpha < 0.01) discard;
    \\        FragColor = vec4(vFgColor.rgb, vFgColor.a * alpha);
    \\    }
    \\}
    \\
;

// ---------------------------------------------------------
// Pass 3: Cursor Overlay
// ---------------------------------------------------------

pub const cursor_vertex_src =
    \\#version 330 core
    \\
    \\// Per-vertex quad corner (0..1)
    \\layout (location = 0) in vec2 aQuadPos;
    \\
    \\// Per-instance attributes
    \\layout (location = 1) in uvec2 aGridPos;    // cursor col, row
    \\layout (location = 2) in uvec4 aAtlasRect;  // unused for cursor
    \\layout (location = 3) in ivec2 aBearing;     // unused for cursor
    \\layout (location = 4) in uint  aFgColor;     // cursor color
    \\layout (location = 5) in uint  aBgColor;     // unused for cursor
    \\layout (location = 6) in uint  aFlags;       // cursor style flags
    \\
    \\uniform mat4 uProjection;
    \\uniform vec2 uCellSize;
    \\uniform vec2 uGridOffset;
    \\
    \\flat out vec4 vCursorColor;
    \\flat out uint vFlags;
    \\out vec2 vQuadUV;
    \\
    \\
++ unpack_color_fn ++
    \\void main() {
    \\    vec2 cellOrigin = uGridOffset + vec2(aGridPos) * uCellSize;
    \\    vec2 pos = cellOrigin + aQuadPos * uCellSize;
    \\    gl_Position = uProjection * vec4(pos, 0.0, 1.0);
    \\    vCursorColor = unpackColor(aFgColor);
    \\    vFlags = aFlags;
    \\    vQuadUV = aQuadPos;
    \\}
    \\
;

pub const cursor_fragment_src =
    \\#version 330 core
    \\
    \\flat in vec4 vCursorColor;
    \\flat in uint vFlags;
    \\in vec2 vQuadUV;
    \\
    \\uniform vec2 uCellSize;
    \\
    \\out vec4 FragColor;
    \\
    \\void main() {
    \\    uint style = vFlags & 0xFFu;
    \\    float alpha = 0.7;
    \\
    \\    if (style == 1u) {
    \\        // ibeam: 2px wide left edge
    \\        float px = vQuadUV.x * uCellSize.x;
    \\        if (px > 2.0) discard;
    \\    } else if (style == 2u) {
    \\        // underline: 2px tall bottom edge
    \\        float py = (1.0 - vQuadUV.y) * uCellSize.y;
    \\        if (py > 2.0) discard;
    \\    } else if (style == 3u) {
    \\        // hollow: 1px outline rectangle
    \\        float px = vQuadUV.x * uCellSize.x;
    \\        float py = vQuadUV.y * uCellSize.y;
    \\        float maxX = uCellSize.x;
    \\        float maxY = uCellSize.y;
    \\        bool onEdge = (px < 1.5 || px > maxX - 1.5 || py < 1.5 || py > maxY - 1.5);
    \\        if (!onEdge) discard;
    \\        alpha = 0.9;
    \\    }
    \\    // style == 0: block (full fill)
    \\
    \\    FragColor = vec4(vCursorColor.rgb, vCursorColor.a * alpha);
    \\}
    \\
;
