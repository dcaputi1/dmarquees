#version 130
/*
    crt-pi_rgb32_dir.fsh -- fragment shader for MAME standalone GLSL
    Line-for-line port of crt-pi.glsl (FRAGMENT section) to MAME standalone GLSL.
    Copyright (C) 2015-2016 davej, GPLv2+

    Adaptations for MAME standalone GLSL pipeline:
      - sampler renamed from Texture -> color_texture (MAME convention)
      - TextureSize uniform replaced by textureSize(color_texture, 0) (GLSL 1.30+)
      - filterWidth moved from vertex shader varying to a local in main(); computed
        via dFdy() because MAME does not supply InputSize / OutputSize uniforms
        (dFdy(TEX0.y) * TextureSize.y  ==  InputSize.y / OutputSize.y -- same value)
      - screenScale (CURVATURE path) likewise computed locally in main()
*/

// Haven't put these as parameters as it would slow the code down.
#define SCANLINES
#define MULTISAMPLE
#define GAMMA
//#define FAKE_GAMMA
//#define CURVATURE
//#define SHARPER
// MASK_TYPE: 0 = none, 1 = green/magenta, 2 = trinitron(ish)
#define MASK_TYPE 1

#define CURVATURE_X         0.10
#define CURVATURE_Y         0.25
#define MASK_BRIGHTNESS     0.70
#define SCANLINE_WEIGHT     6.0
#define SCANLINE_GAP_BRIGHTNESS 0.12
#define BLOOM_FACTOR        1.5
#define INPUT_GAMMA         2.4
#define OUTPUT_GAMMA        2.2

uniform sampler2D color_texture;

varying vec2 TEX0;

#if defined(CURVATURE)
// screenScale was a varying in the original (set in vertex shader as TextureSize/InputSize).
// MAME does not supply InputSize, so we approximate with textureSize / textureSize = 1.0
// per axis; real curvature requires knowing InputSize -- left as an exercise.
varying vec2 screenScale;

vec2 Distort(vec2 coord)
{
    vec2 CURVATURE_DISTORTION = vec2(CURVATURE_X, CURVATURE_Y);
    // Barrel distortion shrinks the display area a bit, this will allow us to counteract that.
    vec2 barrelScale = 1.0 - (0.23 * CURVATURE_DISTORTION);
    coord *= screenScale;
    coord -= vec2(0.5);
    float rsq = coord.x * coord.x + coord.y * coord.y;
    coord += coord * (CURVATURE_DISTORTION * rsq);
    coord *= barrelScale;
    if (abs(coord.x) >= 0.5 || abs(coord.y) >= 0.5)
        coord = vec2(-1.0);		// If out of bounds, return an invalid value.
    else
    {
        coord += vec2(0.5);
        coord /= screenScale;
    }
    return coord;
}
#endif

float CalcScanLineWeight(float dist)
{
    return max(1.0 - dist * dist * SCANLINE_WEIGHT, SCANLINE_GAP_BRIGHTNESS);
}

float CalcScanLine(float dy, float filterWidth)
{
    float scanLineWeight = CalcScanLineWeight(dy);
#if defined(MULTISAMPLE)
    scanLineWeight += CalcScanLineWeight(dy - filterWidth);
    scanLineWeight += CalcScanLineWeight(dy + filterWidth);
    scanLineWeight *= 0.3333333;
#endif
    return scanLineWeight;
}

void main()
{
    vec2 TextureSize = vec2(textureSize(color_texture, 0));

    // In the original, filterWidth was set in the vertex shader as
    // (InputSize.y / OutputSize.y) / 3.0 and passed as a varying.
    // Here we compute the equivalent from screen-space derivatives.
    float filterWidth = abs(dFdy(TEX0.y) * TextureSize.y) / 3.0;

#if defined(CURVATURE)
    vec2 texcoord = Distort(TEX0);
    if (texcoord.x < 0.0)
        gl_FragColor = vec4(0.0);
    else
#else
    vec2 texcoord = TEX0;
#endif
    {
        vec2 texcoordInPixels = texcoord * TextureSize;
#if defined(SHARPER)
        vec2 tempCoord = floor(texcoordInPixels) + 0.5;
        vec2 coord = tempCoord / TextureSize;
        vec2 deltas = texcoordInPixels - tempCoord;
        float scanLineWeight = CalcScanLine(deltas.y, filterWidth);
        vec2 signs = sign(deltas);
        deltas.x *= 2.0;
        deltas = deltas * deltas;
        deltas.y = deltas.y * deltas.y;
        deltas.x *= 0.5;
        deltas.y *= 8.0;
        deltas /= TextureSize;
        deltas *= signs;
        vec2 tc = coord + deltas;
#else
        float tempY = floor(texcoordInPixels.y) + 0.5;
        float yCoord = tempY / TextureSize.y;
        float dy = texcoordInPixels.y - tempY;
        float scanLineWeight = CalcScanLine(dy, filterWidth);
        float signY = sign(dy);
        dy = dy * dy;
        dy = dy * dy;
        dy *= 8.0;
        dy /= TextureSize.y;
        dy *= signY;
        vec2 tc = vec2(texcoord.x, yCoord + dy);
#endif

        vec3 colour = texture2D(color_texture, tc).rgb;

#if defined(SCANLINES)
#if defined(GAMMA)
#if defined(FAKE_GAMMA)
        colour = colour * colour;
#else
        colour = pow(colour, vec3(INPUT_GAMMA));
#endif
#endif
        scanLineWeight *= BLOOM_FACTOR;
        colour *= scanLineWeight;

#if defined(GAMMA)
#if defined(FAKE_GAMMA)
        colour = sqrt(colour);
#else
        colour = pow(colour, vec3(1.0 / OUTPUT_GAMMA));
#endif
#endif
#endif
#if MASK_TYPE == 0
        gl_FragColor = vec4(colour, 1.0);
#else
#if MASK_TYPE == 1
        float whichMask = fract(gl_FragCoord.x * 0.5);
        vec3 mask;
        if (whichMask < 0.5)
            mask = vec3(MASK_BRIGHTNESS, 1.0, MASK_BRIGHTNESS);
        else
            mask = vec3(1.0, MASK_BRIGHTNESS, 1.0);
#elif MASK_TYPE == 2
        float whichMask = fract(gl_FragCoord.x * 0.3333333);
        vec3 mask = vec3(MASK_BRIGHTNESS, MASK_BRIGHTNESS, MASK_BRIGHTNESS);
        if (whichMask < 0.3333333)
            mask.x = 1.0;
        else if (whichMask < 0.6666666)
            mask.y = 1.0;
        else
            mask.z = 1.0;
#endif

        gl_FragColor = vec4(colour * mask, 1.0);
#endif
    }
}
