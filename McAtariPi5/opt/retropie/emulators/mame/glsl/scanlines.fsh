//
// Ultra-light scanline shader for MAME GLSL
//

uniform sampler2D color_texture;

void main()
{
    vec2 uv = gl_TexCoord[0].xy;

    vec4 color = texture2D(color_texture, uv);

    // alternating scanlines
    if (fract(gl_FragCoord.y * 0.5) < 0.5)
    {
        color.rgb *= 0.88;
    }

    gl_FragColor = color;
}