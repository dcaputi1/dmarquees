#version 130
//
// Scanline shader for MAME GLSL — source-pixel aligned
//
// Applies scanlines that are locked to the source (emulated) scanline rows
// rather than to screen pixels.  This is the correct approach when the game's
// native resolution does not scale to an exact integer multiple of the display
// height.  The naive alternative — darkening every other *screen* pixel — works
// by coincidence for games that happen to scale evenly, but produces a
// thick/thin banding artifact for games like Spy Hunter whose video geometry
// results in alternating 4-pixel and 5-pixel output rows per source row.
//
// Fix: use textureSize() to get the source texture height, then compute the
// fractional position within each source scanline row.  A thin dark "gap" is
// drawn at the boundary between rows, mimicking the unlit space between CRT
// phosphor lines.  This produces ~240 thin gaps rather than 120 thick bands,
// which is far more faithful to the original CRT appearance.
//
// GAP_DIM: brightness at the darkest point of each scanline gap (0.0=black,
//          1.0=no effect).  0.45 matches the feel of MAME's built-in effect
//          scanlines art without the scaling artefacts.
//
// The modulation is a full cosine wave locked to each source row, so:
//   srcFrac = 0.0 or 1.0  → boundary between rows → dim (GAP_DIM)
//   srcFrac = 0.5          → centre of row         → full brightness
// This produces a smooth, symmetric gradient identical to a real CRT phosphor
// gap — no hard edge, no thick/thin banding on non-integer scales.

uniform sampler2D color_texture;

// 3.14159265 * 2.0
const float TWO_PI = 6.28318530;

void main()
{
    vec2 uv = gl_TexCoord[0].xy;
    vec4 color = texture2D(color_texture, uv);

    // Source texture height in pixels (e.g. 240 for Spy Hunter).
    float srcHeight = float(textureSize(color_texture, 0).y);

    // Fractional position within the current source scanline row (0.0–1.0).
    float srcFrac = fract(uv.y * srcHeight);

    // Cosine modulation: peaks at srcFrac=0.5 (row centre), troughs at
    // srcFrac=0 and 1.0 (row boundaries — the dark inter-line gap).
    // mix(GAP_DIM, 1.0, t) maps the cosine [0,1] range onto [GAP_DIM, 1.0].
    const float GAP_DIM = 0.45;
    float t = 0.5 + 0.5 * cos((srcFrac - 0.5) * TWO_PI);
    color.rgb *= mix(GAP_DIM, 1.0, t);

    gl_FragColor = color;
}
