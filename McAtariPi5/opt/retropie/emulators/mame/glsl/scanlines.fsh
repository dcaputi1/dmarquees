#version 120

uniform sampler2D color_texture;

varying vec2 v_texcoord0;

void main()
{
    vec4 color = texture2D(color_texture, v_texcoord0);

    /*
        Lightweight scanline effect.

        Darken every other output row slightly.

        0.88 is intentionally subtle:
        - preserves brightness
        - avoids crushed blacks
        - looks more authentic on LCD
        - minimizes shader artifacts
    */

    if (mod(gl_FragCoord.y, 2.0) < 1.0)
    {
        color.rgb *= 0.88;
    }

    gl_FragColor = color;
}
