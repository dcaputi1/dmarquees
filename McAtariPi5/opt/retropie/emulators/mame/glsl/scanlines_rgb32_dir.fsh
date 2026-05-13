#version 130
/*
 * scanlines_rgb32_dir.fsh -- Source-scanline-aligned scanlines for MAME GLSL
 *
 * Ported from crt-pi.glsl by davej (GPLv2+)
 * https://github.com/libretro/glsl-shaders/blob/master/crt/shaders/crt-pi.glsl
 *
 * Retained:  scanlines (parabolic weight), 3-tap anti-moire, bloom, fake gamma
 * Omitted:   curvature, shadow mask (MASK_TYPE), SHARPER horizontal filter
 */

uniform sampler2D color_texture;

// -- Scanline shape -----------------------------------------------------------
// Inverse scanline width -- higher = narrower bright band / wider dark gap.
//   3.0 = soft, fat lines     6.0 = crt-pi default     10.0 = thin, crisp
const float SCANLINE_WEIGHT         = 6.0;

// Brightness floor at the darkest point of the inter-line gap.
//   0.0 = pure black gap     0.12 = dark-grey (less moire risk)
const float SCANLINE_GAP_BRIGHTNESS = 0.12;

// Width boost applied to the scanline weight.  > 1.0 widens bright lines,
// compensating for average dimming.  Try 1.2 if 1.5 looks oversaturated.
// Set to 1.0 to disable.
const float BLOOM_FACTOR            = 1.5;

// 3-tap box-filter half-width in source-texel units.  Averages CalcScanLine at
// dy and dy +/- FILTER_WIDTH to suppress moire on non-integer scale factors.
// ~ (src_height / display_height) / 3  ->  ~0.067 for 240p @ 1200p.
const float FILTER_WIDTH            = 0.1;

// -- Gamma correction ---------------------------------------------------------
// Linearise the input before applying the scanline mask (so dark gaps are in
// linear light), then re-encode the output.
// FAKE_GAMMA: square/sqrt approximation of gamma ~2.0 -- much cheaper than pow(),
// visually indistinguishable for scanlines.  Comment out to use true gamma.
#define FAKE_GAMMA
const float INPUT_GAMMA  = 2.4;   // used only without FAKE_GAMMA
const float OUTPUT_GAMMA = 2.2;   // used only without FAKE_GAMMA

// -----------------------------------------------------------------------------

// Parabolic falloff from texel-row centre.  Cheaper than sin+pow, same feel.
float CalcScanLineWeight(float dist)
{
    return max(1.0 - dist * dist * SCANLINE_WEIGHT, SCANLINE_GAP_BRIGHTNESS);
}

// 3-tap box filter to tame moire at non-integer scale ratios.
float CalcScanLine(float dy)
{
    float w  = CalcScanLineWeight(dy);
    w += CalcScanLineWeight(dy - FILTER_WIDTH);
    w += CalcScanLineWeight(dy + FILTER_WIDTH);
    return w * 0.3333333;
}

// Actual game/source texture dimensions supplied by MAME at draw time.
// Using u_source_dims (e.g. 256x224 for most arcade games) ensures scanlines
// snap to real source-pixel rows rather than display-surface rows.
uniform vec2 u_source_dims;

void main()
{
    vec2 srcSize = u_source_dims;
    vec2 uv = gl_TexCoord[0].xy;

    // Convert UV to source-pixel coordinates.
    vec2 texcoordInPixels = uv * srcSize;

    // Snap to the nearest source-texel row centre.
    float tempY  = floor(texcoordInPixels.y) + 0.5;
    float yCoord = tempY / srcSize.y;

    // Distance from that row centre in source-texel units (-0.5 ... +0.5).
    float dy = texcoordInPixels.y - tempY;

    // -- Scanline weight ------------------------------------------------------
    float scanLineWeight = CalcScanLine(dy) * BLOOM_FACTOR;

    // -- Sub-pixel vertical displacement --------------------------------------
    // A 4th-power curve that nudges the texture sample toward the texel centre.
    // Eliminates hard row-boundary aliasing at non-integer scale factors
    // (e.g. 240p -> 1200p) without introducing visible blur.  Very cheap.
    float signY      = sign(dy);
    float dyDisplace = dy * dy * dy * dy * 8.0 / srcSize.y * signY;

    // -- Sample ---------------------------------------------------------------
    vec3 color = texture2D(color_texture, vec2(uv.x, yCoord + dyDisplace)).rgb;

    // -- Gamma / linearise -> apply scanline -> re-encode --------------------
#ifdef FAKE_GAMMA
    color = color * color;           // approx. gamma 2.0 -> linear
#else
    color = pow(color, vec3(INPUT_GAMMA));
#endif

    color *= scanLineWeight;

#ifdef FAKE_GAMMA
    color = sqrt(color);              // linear -> approx. gamma 2.0
#else
    color = pow(color, vec3(1.0 / OUTPUT_GAMMA));
#endif

    gl_FragColor = vec4(color, 1.0);
}
