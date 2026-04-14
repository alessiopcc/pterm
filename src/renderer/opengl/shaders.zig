/// GLSL 330 core shader source strings for the OpenGL renderer.
///
/// Four render passes:
///   Pass 1: Cell backgrounds (bg_vertex_src / bg_fragment_src)
///   Pass 2: Glyph text (text_vertex_src / text_fragment_src)
///   Pass 3: Block elements (block_vertex_src / block_fragment_src)
///           Procedural rendering of box-drawing, block elements, braille (D-01/D-02)
///   Pass 4: Cursor overlay (cursor_vertex_src / cursor_fragment_src)

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

// ---------------------------------------------------------
// Pass 4 (new): Block Elements (box-drawing, blocks, braille, Powerline)
// Procedural rendering — no atlas texture sampling (D-02).
// Codepoint is passed via aAtlasRect.x from the instance buffer.
// ---------------------------------------------------------

pub const block_vertex_src =
    \\#version 330 core
    \\
    \\// Per-vertex quad corner (0..1)
    \\layout (location = 0) in vec2 aQuadPos;
    \\
    \\// Per-instance attributes (same layout as all passes)
    \\layout (location = 1) in uvec2 aGridPos;    // col, row
    \\layout (location = 2) in uvec4 aAtlasRect;  // .x = codepoint for block pass
    \\layout (location = 3) in ivec2 aBearing;     // unused for block pass
    \\layout (location = 4) in uint  aFgColor;     // packed RGBA
    \\layout (location = 5) in uint  aBgColor;     // packed RGBA
    \\layout (location = 6) in uint  aFlags;       // unused for block pass
    \\
    \\uniform mat4 uProjection;
    \\uniform vec2 uCellSize;    // pixels per cell
    \\uniform vec2 uGridOffset;  // top-left padding
    \\
    \\flat out uint vCodepoint;
    \\flat out vec4 vFgColor;
    \\flat out vec4 vBgColor;
    \\out vec2 vQuadUV;
    \\
    \\
++ unpack_color_fn ++
    \\void main() {
    \\    vec2 cellOrigin = uGridOffset + vec2(aGridPos) * uCellSize;
    \\    vec2 pos = cellOrigin + aQuadPos * uCellSize;
    \\    gl_Position = uProjection * vec4(pos, 0.0, 1.0);
    \\    vCodepoint = aAtlasRect.x;
    \\    vFgColor = unpackColor(aFgColor);
    \\    vBgColor = unpackColor(aBgColor);
    \\    vQuadUV = aQuadPos;
    \\}
    \\
;

// ---------------------------------------------------------
// Pass 3: Block Elements — inline dispatch fragment shader
// ---------------------------------------------------------
pub const block_fragment_src =
    \\#version 330 core
    \\
    \\flat in uint vCodepoint;
    \\flat in vec4 vFgColor;
    \\flat in vec4 vBgColor;
    \\in vec2 vQuadUV;
    \\
    \\uniform vec2 uCellSize;
    \\
    \\out vec4 FragColor;
    \\
    \\void main() {
    \\    uint cp = vCodepoint;
    \\    vec2 uv = vQuadUV;
    \\    float csX = max(uCellSize.x, 1.0);
    \\    float csY = max(uCellSize.y, 1.0);
    \\    float pxX = 0.5 / csX;
    \\    float pxY = 0.5 / csY;
    \\    // Line thickness in UV space — separate for each axis so lines
    \\    // appear the same pixel width regardless of cell aspect ratio.
    \\    float ltX = max(1.0, round(csX / 8.0)) / csX;  // vertical line width
    \\    float ltY = max(1.0, round(csY / 8.0)) / csY;  // horizontal line height
    \\    float htX = max(2.0, round(csX / 4.0)) / csX;  // heavy vertical
    \\    float htY = max(2.0, round(csY / 4.0)) / csY;  // heavy horizontal
    \\    // For convenience in non-axis-specific code, use the smaller
    \\    float lt = ltX;
    \\    float ht = htX;
    \\
    \\    // ---- Block Elements U+2580-259F ----
    \\    if (cp >= 0x2580u && cp <= 0x259Fu) {
    \\        uint idx = cp - 0x2580u;
    \\        // U+2580 upper half
    \\        if (idx == 0u) {
    \\            if (uv.y < 0.5) { FragColor = vFgColor; return; }
    \\            discard;
    \\        }
    \\        // U+2581-2588 lower N/8 blocks
    \\        if (idx >= 1u && idx <= 8u) {
    \\            float t = 1.0 - float(idx) / 8.0;
    \\            if (uv.y >= t) { FragColor = vFgColor; return; }
    \\            discard;
    \\        }
    \\        // U+2589-258F left N/8 blocks
    \\        if (idx >= 9u && idx <= 15u) {
    \\            float t = float(16u - idx) / 8.0;
    \\            if (uv.x < t) { FragColor = vFgColor; return; }
    \\            discard;
    \\        }
    \\        // U+2590 right half
    \\        if (idx == 16u) {
    \\            if (uv.x >= 0.5) { FragColor = vFgColor; return; }
    \\            discard;
    \\        }
    \\        // U+2591-2593 shades
    \\        if (idx == 17u) { FragColor = vec4(vFgColor.rgb, 0.25); return; }
    \\        if (idx == 18u) { FragColor = vec4(vFgColor.rgb, 0.50); return; }
    \\        if (idx == 19u) { FragColor = vec4(vFgColor.rgb, 0.75); return; }
    \\        // U+2594 upper 1/8
    \\        if (idx == 20u) {
    \\            if (uv.y < 0.125) { FragColor = vFgColor; return; }
    \\            discard;
    \\        }
    \\        // U+2595 right 1/8
    \\        if (idx == 21u) {
    \\            if (uv.x >= 0.875) { FragColor = vFgColor; return; }
    \\            discard;
    \\        }
    \\        // U+2596-259F quadrants
    \\        if (idx >= 22u && idx <= 31u) {
    \\            int lut[10] = int[10](2,1,8,11,9,14,13,4,6,15);
    \\            int bits = lut[idx - 22u];
    \\            bool tl = uv.x < 0.5 && uv.y < 0.5;
    \\            bool tr = uv.x >= 0.5 && uv.y < 0.5;
    \\            bool bl = uv.x < 0.5 && uv.y >= 0.5;
    \\            bool br = uv.x >= 0.5 && uv.y >= 0.5;
    \\            bool filled = (tl && (bits & 8) != 0)
    \\                        || (tr && (bits & 4) != 0)
    \\                        || (bl && (bits & 2) != 0)
    \\                        || (br && (bits & 1) != 0);
    \\            if (filled) { FragColor = vFgColor; return; }
    \\            discard;
    \\        }
    \\        discard;
    \\    }
    \\
    \\    // ---- Box Drawing U+2500-257F ----
    \\    if (cp >= 0x2500u && cp <= 0x257Fu) {
    \\        uint idx = cp - 0x2500u;
    \\        float cx = 0.5, cy = 0.5;
    \\
    \\        // Decode edges: L,R,U,D weights (0=none, 1=light, 2=heavy)
    \\        int eL=0, eR=0, eU=0, eD=0;
    \\
    \\        // Basic lines
    \\        if (idx==0u){eL=1;eR=1;}else if(idx==1u){eL=2;eR=2;}
    \\        else if(idx==2u){eU=1;eD=1;}else if(idx==3u){eU=2;eD=2;}
    \\        // Dashed (treat as solid) — 4-5 horiz light, 6-7 vert light, 8-9 horiz light, 10-11 vert light
    \\        else if(idx>=4u&&idx<=5u){eL=1;eR=1;}
    \\        else if(idx>=6u&&idx<=7u){eU=1;eD=1;}
    \\        else if(idx>=8u&&idx<=9u){eL=1;eR=1;}
    \\        else if(idx>=10u&&idx<=11u){eU=1;eD=1;}
    \\        // Corners: down+right
    \\        else if(idx==12u){eR=1;eD=1;}else if(idx==13u){eR=1;eD=2;}
    \\        else if(idx==14u){eR=2;eD=1;}else if(idx==15u){eR=2;eD=2;}
    \\        // Corners: down+left
    \\        else if(idx==16u){eL=1;eD=1;}else if(idx==17u){eL=1;eD=2;}
    \\        else if(idx==18u){eL=2;eD=1;}else if(idx==19u){eL=2;eD=2;}
    \\        // Corners: up+right
    \\        else if(idx==20u){eR=1;eU=1;}else if(idx==21u){eR=1;eU=2;}
    \\        else if(idx==22u){eR=2;eU=1;}else if(idx==23u){eR=2;eU=2;}
    \\        // Corners: up+left
    \\        else if(idx==24u){eL=1;eU=1;}else if(idx==25u){eL=1;eU=2;}
    \\        else if(idx==26u){eL=2;eU=1;}else if(idx==27u){eL=2;eU=2;}
    \\        // T right
    \\        else if(idx==28u){eR=1;eU=1;eD=1;}else if(idx==29u){eR=1;eU=2;eD=1;}
    \\        else if(idx==30u){eR=1;eU=1;eD=2;}else if(idx==31u){eR=1;eU=2;eD=2;}
    \\        else if(idx==32u){eR=2;eU=1;eD=1;}else if(idx==33u){eR=2;eU=2;eD=1;}
    \\        else if(idx==34u){eR=2;eU=1;eD=2;}else if(idx==35u){eR=2;eU=2;eD=2;}
    \\        // T left
    \\        else if(idx==36u){eL=1;eU=1;eD=1;}else if(idx==37u){eL=1;eU=2;eD=1;}
    \\        else if(idx==38u){eL=1;eU=1;eD=2;}else if(idx==39u){eL=1;eU=2;eD=2;}
    \\        else if(idx==40u){eL=2;eU=1;eD=1;}else if(idx==41u){eL=2;eU=2;eD=1;}
    \\        else if(idx==42u){eL=2;eU=1;eD=2;}else if(idx==43u){eL=2;eU=2;eD=2;}
    \\        // T down
    \\        else if(idx==44u){eL=1;eR=1;eD=1;}else if(idx==45u){eL=1;eR=2;eD=1;}
    \\        else if(idx==46u){eL=2;eR=1;eD=1;}else if(idx==47u){eL=2;eR=2;eD=1;}
    \\        else if(idx==48u){eL=1;eR=1;eD=2;}else if(idx==49u){eL=1;eR=2;eD=2;}
    \\        else if(idx==50u){eL=2;eR=1;eD=2;}else if(idx==51u){eL=2;eR=2;eD=2;}
    \\        // T up
    \\        else if(idx==52u){eL=1;eR=1;eU=1;}else if(idx==53u){eL=1;eR=2;eU=1;}
    \\        else if(idx==54u){eL=2;eR=1;eU=1;}else if(idx==55u){eL=2;eR=2;eU=1;}
    \\        else if(idx==56u){eL=1;eR=1;eU=2;}else if(idx==57u){eL=1;eR=2;eU=2;}
    \\        else if(idx==58u){eL=2;eR=1;eU=2;}else if(idx==59u){eL=2;eR=2;eU=2;}
    \\        // Crosses
    \\        else if(idx==60u){eL=1;eR=1;eU=1;eD=1;}
    \\        else if(idx==61u){eL=1;eR=2;eU=1;eD=1;}
    \\        else if(idx==62u){eL=2;eR=1;eU=1;eD=1;}
    \\        else if(idx==63u){eL=1;eR=1;eU=2;eD=1;}
    \\        else if(idx==64u){eL=1;eR=1;eU=1;eD=2;}
    \\        else if(idx==65u){eL=1;eR=2;eU=2;eD=1;}
    \\        else if(idx==66u){eL=2;eR=1;eU=1;eD=2;}
    \\        else if(idx==67u){eL=1;eR=2;eU=1;eD=2;}
    \\        else if(idx==68u){eL=2;eR=1;eU=2;eD=1;}
    \\        else if(idx==69u){eL=2;eR=2;eU=2;eD=1;}
    \\        else if(idx==70u){eL=2;eR=2;eU=1;eD=2;}
    \\        else if(idx==71u){eL=1;eR=2;eU=2;eD=2;}
    \\        else if(idx==72u){eL=2;eR=1;eU=2;eD=2;}
    \\        else if(idx==73u){eL=2;eR=2;eU=2;eD=2;}
    \\        // Double lines U+2550-256C — treat as edges (simplified, no parallel gap)
    \\        else if(idx==80u){eL=2;eR=2;}       // ═
    \\        else if(idx==81u){eU=2;eD=2;}       // ║
    \\        else if(idx==84u){eR=2;eD=2;}       // ╔
    \\        else if(idx==87u){eL=2;eD=2;}       // ╗
    \\        else if(idx==90u){eR=2;eU=2;}       // ╚
    \\        else if(idx==93u){eL=2;eU=2;}       // ╝
    \\        else if(idx==96u){eR=2;eU=2;eD=2;}  // ╠
    \\        else if(idx==99u){eL=2;eU=2;eD=2;}  // ╣
    \\        else if(idx==102u){eL=2;eR=2;eD=2;} // ╦
    \\        else if(idx==105u){eL=2;eR=2;eU=2;} // ╩
    \\        else if(idx==108u){eL=2;eR=2;eU=2;eD=2;} // ╬
    \\        // Mixed single/double — approximate as heavy edges
    \\        else if(idx>=82u&&idx<=83u){eR=1;eD=2;} // ╒╓
    \\        else if(idx>=85u&&idx<=86u){eL=1;eD=2;} // ╕╖
    \\        else if(idx>=88u&&idx<=89u){eR=1;eU=2;} // ╘╙
    \\        else if(idx>=91u&&idx<=92u){eL=1;eU=2;} // ╛╜
    \\        else if(idx>=94u&&idx<=95u){eR=1;eU=2;eD=2;} // ╞╟
    \\        else if(idx>=97u&&idx<=98u){eL=1;eU=2;eD=2;} // ╡╢
    \\        else if(idx>=100u&&idx<=101u){eL=1;eR=1;eD=2;} // ╤╥
    \\        else if(idx>=103u&&idx<=104u){eL=1;eR=1;eU=2;} // ╧╨
    \\        else if(idx>=106u&&idx<=107u){eL=1;eR=1;eU=2;eD=2;} // ╪╫
    \\        // Arc corners U+256D-2570
    \\        else if(idx>=109u&&idx<=112u){
    \\            uint ai = idx - 109u;
    \\            // 0=╭(D+R) 1=╮(D+L) 2=╯(U+L) 3=╰(U+R)
    \\            // Corner is the opposite quadrant from where the arc curves toward
    \\            vec2 corner;
    \\            if(ai==0u) corner=vec2(1.0,1.0);      // ╭ arc in bottom-right
    \\            else if(ai==1u) corner=vec2(0.0,1.0);  // ╮ arc in bottom-left
    \\            else if(ai==2u) corner=vec2(0.0,0.0);  // ╯ arc in top-left
    \\            else corner=vec2(1.0,0.0);              // ╰ arc in top-right
    \\            float radius=0.5;
    \\            float d=abs(length(uv-corner)-radius)-ltX*0.5;
    \\            // Only draw arc in the correct quadrant
    \\            bool inQ=true;
    \\            if(ai==0u) inQ=(uv.x>=cx&&uv.y>=cy);
    \\            else if(ai==1u) inQ=(uv.x<=cx&&uv.y>=cy);
    \\            else if(ai==2u) inQ=(uv.x<=cx&&uv.y<=cy);
    \\            else inQ=(uv.x>=cx&&uv.y<=cy);
    \\            // Arc only — adjacent cells provide the straight connecting lines.
    \\            // No straight segments needed; they caused a visible rectangle behind the arc.
    \\            float fcov=inQ?(1.0-smoothstep(-pxX,pxX,d)):0.0;
    \\            if(fcov<0.01) discard;
    \\            FragColor=vec4(vFgColor.rgb,vFgColor.a*fcov);return;
    \\        }
    \\        // Diagonals U+2571-2573
    \\        else if(idx==113u||idx==115u){
    \\            float d=abs(uv.x+uv.y-1.0)/1.4142-lt*0.5;
    \\            float a2=1.0-smoothstep(-pxX,pxX,d);
    \\            if(idx==115u){
    \\                float d2=abs(uv.x-uv.y)/1.4142-lt*0.5;
    \\                a2=max(a2,1.0-smoothstep(-pxX,pxX,d2));
    \\            }
    \\            if(a2<0.01)discard;
    \\            FragColor=vec4(vFgColor.rgb,vFgColor.a*a2);return;
    \\        }
    \\        else if(idx==114u){
    \\            float d=abs(uv.x-uv.y)/1.4142-lt*0.5;
    \\            float a2=1.0-smoothstep(-pxX,pxX,d);
    \\            if(a2<0.01)discard;
    \\            FragColor=vec4(vFgColor.rgb,vFgColor.a*a2);return;
    \\        }
    \\        // Half-lines U+2574-257F
    \\        else if(idx==116u){eL=1;}else if(idx==117u){eU=1;}
    \\        else if(idx==118u){eR=1;}else if(idx==119u){eD=1;}
    \\        else if(idx==120u){eL=2;}else if(idx==121u){eU=2;}
    \\        else if(idx==122u){eR=2;}else if(idx==123u){eD=2;}
    \\
    \\        // Draw edges — signed distance per arm, directional AA
    \\        if(eL==0&&eR==0&&eU==0&&eD==0) discard;
    \\        float cov = 0.0;
    \\        // Left arm: overshoot right only if eR exists (seamless join)
    \\        if(eL>0){float tY=(eL==2)?htY:ltY; float tX=(eL==2)?htX:ltX;
    \\            float clipR=(eR>0)?cx+tX*0.5:cx;
    \\            float s=max(uv.x-clipR,abs(uv.y-cy)-tY*0.5);
    \\            cov=max(cov,1.0-smoothstep(-pxY,pxY,s));}
    \\        // Right arm: overshoot left only if eL exists
    \\        if(eR>0){float tY=(eR==2)?htY:ltY; float tX=(eR==2)?htX:ltX;
    \\            float clipL=(eL>0)?cx-tX*0.5:cx;
    \\            float s=max(clipL-uv.x,abs(uv.y-cy)-tY*0.5);
    \\            cov=max(cov,1.0-smoothstep(-pxY,pxY,s));}
    \\        // Up arm: overshoot down only if eD exists
    \\        if(eU>0){float tX=(eU==2)?htX:ltX; float tY=(eU==2)?htY:ltY;
    \\            float clipD=(eD>0)?cy+tY*0.5:cy;
    \\            float s=max(uv.y-clipD,abs(uv.x-cx)-tX*0.5);
    \\            cov=max(cov,1.0-smoothstep(-pxX,pxX,s));}
    \\        // Down arm: overshoot up only if eU exists
    \\        if(eD>0){float tX=(eD==2)?htX:ltX; float tY=(eD==2)?htY:ltY;
    \\            float clipU=(eU>0)?cy-tY*0.5:cy;
    \\            float s=max(clipU-uv.y,abs(uv.x-cx)-tX*0.5);
    \\            cov=max(cov,1.0-smoothstep(-pxX,pxX,s));}
    \\        if(cov<0.01) discard;
    \\        FragColor = vec4(vFgColor.rgb, vFgColor.a * cov);
    \\        return;
    \\    }
    \\
    \\    // ---- Braille U+2800-28FF ----
    \\    if (cp >= 0x2800u && cp <= 0x28FFu) {
    \\        uint dots = cp & 0xFFu;
    \\        if (dots == 0u) discard;
    \\        float dotR = 0.06;
    \\        float pxAA = 0.5 / max(uCellSize.x, 1.0);
    \\        float minD = 999.0;
    \\        float cX0=0.30, cX1=0.70;
    \\        float rY0=0.125, rY1=0.375, rY2=0.625, rY3=0.875;
    \\        if((dots& 1u)!=0u) minD=min(minD,distance(uv,vec2(cX0,rY0)));
    \\        if((dots& 2u)!=0u) minD=min(minD,distance(uv,vec2(cX0,rY1)));
    \\        if((dots& 4u)!=0u) minD=min(minD,distance(uv,vec2(cX0,rY2)));
    \\        if((dots& 8u)!=0u) minD=min(minD,distance(uv,vec2(cX1,rY0)));
    \\        if((dots&16u)!=0u) minD=min(minD,distance(uv,vec2(cX1,rY1)));
    \\        if((dots&32u)!=0u) minD=min(minD,distance(uv,vec2(cX1,rY2)));
    \\        if((dots&64u)!=0u) minD=min(minD,distance(uv,vec2(cX0,rY3)));
    \\        if((dots&128u)!=0u) minD=min(minD,distance(uv,vec2(cX1,rY3)));
    \\        float a2 = 1.0 - smoothstep(dotR-pxAA, dotR+pxAA, minD);
    \\        if(a2<0.01) discard;
    \\        FragColor = vec4(vFgColor.rgb, vFgColor.a * a2);
    \\        return;
    \\    }
    \\
    \\    // Powerline (U+E0A0-E0D4) not handled here — stays in text pass
    \\    // for full-cell fg+bg rendering via font glyphs.
    \\
    \\    // Unknown codepoint — discard (transparent)
    \\    discard;
    \\}
    \\
;

// NOTE: A full procedural shader with helper functions (drawBoxDrawing,
// drawBlockElement, drawBraille, drawPowerline, drawBoxDouble, drawFallback)
// was developed but function calls with out parameters did not produce output
// on some GPU drivers (Windows/ANGLE). The working version above uses inline
// dispatch in main() which is compatible with all tested drivers.
