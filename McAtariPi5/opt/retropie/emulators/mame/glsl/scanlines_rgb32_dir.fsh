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
// Modulation shape: pow(sin(srcFrac * PI), SCANLINE_POWER)
//   - sin(srcFrac * PI) is a half-sine: 0 at row boundaries, 1 at centre.
//   - Raising to SCANLINE_POWER < 1.0 widens the bright plateau and narrows
//     the dark gap, approximating the MAME "effect scanlines" art overlay.
//   - Raising to SCANLINE_POWER > 1.0 widens the dark gap (thicker lines).
//   - PEAK_BRIGHTNESS > 1.0 boosts the phosphor-line centre to mimic the
//     slight bloom of real CRT phosphor; compensates for the average dimming.
//   - GAP_FLOOR is the brightness at the darkest point of the inter-line gap.

uniform sampler2D color_texture;

const float PI = 3.14159265;

// Tune these to taste:
//   SCANLINE_POWER: 0.25 = very thin gap / wide bright line (subtle effect)
//                  0.50 = moderate gap (matches MAME art overlay feel)
//                  1.50 = thick gap / thinner bright line (heavy effect)
const float SCANLINE_POWER   = 0.40;   // < 1 = thin gap, > 1 = thick gap
const float PEAK_BRIGHTNESS  = 1.20;   // boost at phosphor centre (1.0 = no boost)
const float GAP_FLOOR        = 0.0;    // darkness at gap bottom (0.0 = black)

void main()
{
    vec2 uv = gl_TexCoord[0].xy;
    vec4 color = texture2D(color_texture, uv);

    // Source texture height in pixels (e.g. 240 for Spy Hunter).
    float srcHeight = float(textureSize(color_texture, 0).y);

    // Fractional position within the current source scanline row (0.0–1.0).
    float srcFrac = fract(uv.y * srcHeight);

    // Half-sine raised to SCANLINE_POWER: 0 at row boundary, 1 at centre.
    // Power < 1 keeps most of the scanline near full brightness with a narrow
    // dark notch at the boundary — the characteristic "effect scanlines" look.
    float scanline = pow(sin(srcFrac * PI), SCANLINE_POWER);
    color.rgb *= GAP_FLOOR + scanline * (PEAK_BRIGHTNESS - GAP_FLOOR);

    gl_FragColor = color;
}
