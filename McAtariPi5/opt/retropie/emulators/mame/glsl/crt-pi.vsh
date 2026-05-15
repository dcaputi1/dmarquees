#version 130
/*
    crt-pi.vsh -- vertex shader for MAME standalone GLSL
    Port of crt-pi.glsl (VERTEX section) to MAME standalone GLSL.
    Copyright (C) 2015-2016 davej, GPLv2+

    MAME does not supply InputSize / OutputSize / MVPMatrix / VertexCoord /
    TexCoord uniforms, so:
      - gl_MultiTexCoord0  replaces  TexCoord
      - ftransform()       replaces  MVPMatrix * VertexCoord
      - filterWidth is computed in the fragment shader via dFdy() instead
      - screenScale (CURVATURE path) likewise cannot be computed here
*/

#pragma parameter CURVATURE_X         "Screen curvature - horizontal" 0.10  0.0 1.0  0.01
#pragma parameter CURVATURE_Y         "Screen curvature - vertical"   0.15  0.0 1.0  0.01
#pragma parameter MASK_BRIGHTNESS     "Mask brightness"                0.70  0.0 1.0  0.01
#pragma parameter SCANLINE_WEIGHT     "Scanline weight"                6.0   0.0 15.0 0.1
#pragma parameter SCANLINE_GAP_BRIGHTNESS "Scanline gap brightness"   0.12  0.0 1.0  0.01
#pragma parameter BLOOM_FACTOR        "Bloom factor"                   1.5   0.0 5.0  0.01
#pragma parameter INPUT_GAMMA         "Input gamma"                    2.4   0.0 5.0  0.01
#pragma parameter OUTPUT_GAMMA        "Output gamma"                   2.2   0.0 5.0  0.01

varying vec2 TEX0;

void main()
{
    TEX0 = gl_MultiTexCoord0.xy;
    gl_Position = ftransform();
}
