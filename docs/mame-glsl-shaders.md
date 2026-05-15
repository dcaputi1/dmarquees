# MAME Standalone GLSL Shaders

## Location

```
/opt/retropie/emulators/mame/glsl/
```

Shader pairs loaded by MAME are set in `mame.ini` (`glsl_shader_mame0`, etc.).  
Current active shader:

```ini
glsl_shader_mame0  /opt/retropie/emulators/mame/glsl/crt-pi
```

MAME loads `crt-pi.vsh` (vertex) and `crt-pi_rgb32_dir.fsh` (fragment) as a pair.

---

## crt-pi shader

A port of [crt-pi.glsl](https://github.com/libretro/glsl-shaders/blob/master/crt/shaders/crt-pi.glsl)
(Copyright © 2015-2016 davej, GPLv2+) to the MAME standalone GLSL pipeline.

### How to change parameters

All parameters are `#define` constants at the top of `crt-pi_rgb32_dir.fsh`.
Edit the file and restart the game to apply. There is no runtime adjustment from
the MAME Tab menu — `#pragma parameter` is a LibRetro/RetroArch convention that
MAME ignores.

### Numeric constants

| `#define` | Default | Effect |
|---|---|---|
| `SCANLINE_WEIGHT` | `6.0` | Inverse scanline width. Higher = thinner bright band, wider dark gap. `3.0` = soft/fat, `10.0` = thin/crisp |
| `SCANLINE_GAP_BRIGHTNESS` | `0.12` | Brightness floor in the dark gap. `0.0` = pure black (more moiré risk), `0.20`+ = lighter gap |
| `BLOOM_FACTOR` | `1.5` | Widens bright scanlines to compensate for average dimming. `1.0` = off |
| `MASK_TYPE` | `1` | Shadow mask: `0` = none, `1` = green/magenta alternating columns, `2` = trinitron-style RGB stripe |
| `MASK_BRIGHTNESS` | `0.70` | How much the mask darkens pixels. `1.0` = no darkening, `0.5` = heavy |
| `INPUT_GAMMA` | `2.4` | Input gamma for linearisation (only active without `FAKE_GAMMA`) |
| `OUTPUT_GAMMA` | `2.2` | Output re-encoding gamma (only active without `FAKE_GAMMA`) |
| `CURVATURE_X` | `0.10` | Horizontal barrel distortion amount (only active with `#define CURVATURE`) |
| `CURVATURE_Y` | `0.25` | Vertical barrel distortion amount (only active with `#define CURVATURE`) |

### Feature toggles

Comment or uncomment the `#define` line to enable/disable each feature.

| `#define` | Default | Effect |
|---|---|---|
| `SCANLINES` | on | The entire scanline effect. Comment out for a flat image |
| `MULTISAMPLE` | on | 3-tap anti-moiré filter. Disabling is faster but moiré appears at non-integer scales |
| `GAMMA` | on | Gamma correction around the scanline blend |
| `FAKE_GAMMA` | off | Faster square/sqrt approximation instead of `pow()`. Enable if performance is tight (requires `GAMMA`) |
| `SHARPER` | off | Sharper horizontal sub-pixel displacement instead of soft linear blend |
| `CURVATURE` | off | Barrel distortion. Requires `InputSize` uniform which MAME does not supply — `screenScale` will be incorrect; leave off |

### Tab menu (Slider Controls)

Tab → Slider Controls exposes MAME-level `brightness`, `contrast`, and `gamma`.
These are applied by MAME *after* the shader output — useful for a quick global
brightness tweak, but separate from the shader's own gamma path.

---

## mame.ini OpenGL options

```ini
gl_glsl          1          # enable GLSL shader pipeline
gl_glsl_filter   0          # texture sampling before shader: 0=nearest, 1=bilinear, 2=bicubic
```

`gl_glsl_filter` controls how MAME samples the game texture before handing it to
the shader. `0` (nearest-neighbor) is the sharpest source; `1` (bilinear) softens
the source pixels before the scanline effect runs — a significant visual difference
worth experimenting with.
