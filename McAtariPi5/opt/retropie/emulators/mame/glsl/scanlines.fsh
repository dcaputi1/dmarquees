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
// Fix: use textureSize() to get the source texture height, then compute which
// source scanline row each output fragment belongs to.  Every other source row
// is dimmed by 30%, mirroring the visual intent of MAME's built-in
// "effect scanlines" artwork option.
//

uniform sampler2D color_texture;

void main()
{
    vec2 uv = gl_TexCoord[0].xy;
    vec4 color = texture2D(color_texture, uv);

    // Source texture height in pixels (e.g. 240 for Spy Hunter).
    float srcHeight = float(textureSize(color_texture, 0).y);

    // Integer source scanline row this fragment falls inside.
    float srcRow = floor(uv.y * srcHeight);

    // Dim every other source row by 30 % — even rows are full brightness,
    // odd rows simulate the dark gap between CRT phosphor lines.
    if (mod(srcRow, 2.0) >= 1.0)
    {
        color.rgb *= 0.70;
    }

    gl_FragColor = color;
}