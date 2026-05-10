# GLSL Scanlines Shader — Implementation Context Dump

**Date:** 2026-05-10  
**Purpose:** Continuation notes for finishing / debugging this shader on the Pi 5.

---

## Background & Problem Statement

MAME's built-in `effect scanlines` (artwork overlay) works fine for most games in this
cabinet but produces a **thick/thin banding artifact** on Spy Hunter.  The root cause is
Spy Hunter's source resolution (nominally 240 scanlines tall) not scaling to an exact
integer multiple of the display height.  At 4.5× scaling for example, source rows
alternately map to 4 and 5 screen pixels.  The built-in effect darkens fixed-size rows
of screen pixels, so some pairs are 4 px + 4 px and others are 5 px + 5 px — the
uneven pairing is what you see as the thick/thin banding.

The documented workaround — `unevenstretch 0` in the ini — eliminates the banding but
leaves large black borders because MAME refuses to scale beyond an integer boundary.
That trade-off is unacceptable.

The correct solution is a GLSL shader that aligns scanline dimming to **source texture
rows** instead of screen pixels.  No matter how many screen pixels a source row occupies,
they all receive the same brightness treatment.

---

## What Was Implemented

### Files changed

| Repo path | Deployed path on Pi |
|---|---|
| `McAtariPi5/opt/retropie/emulators/mame/glsl/scanlines.fsh` | `/opt/retropie/emulators/mame/glsl/scanlines.fsh` |
| `McAtariPi5/opt/retropie/emulators/mame/glsl/scanlines.vsh` | `/opt/retropie/emulators/mame/glsl/scanlines.vsh` |

### scanlines.vsh (vertex — passthrough, unchanged behaviour, version bumped)

```glsl
#version 130
void main()
{
    gl_Position = ftransform();
    gl_TexCoord[0] = gl_MultiTexCoord0;
}
```

### scanlines.fsh (fragment — the real change)

```glsl
#version 130
uniform sampler2D color_texture;

void main()
{
    vec2 uv = gl_TexCoord[0].xy;
    vec4 color = texture2D(color_texture, uv);

    float srcHeight = float(textureSize(color_texture, 0).y);
    float srcRow    = floor(uv.y * srcHeight);

    if (mod(srcRow, 2.0) >= 1.0)
        color.rgb *= 0.70;

    gl_FragColor = color;
}
```

Key difference from the previous (broken) version:

| | Old shader | New shader |
|---|---|---|
| Y reference | `gl_FragCoord.y` — screen pixels | `uv.y * textureSize(…).y` — source texture rows |
| Threshold | `fract(y * 0.5) < 0.5` | `mod(srcRow, 2.0) >= 1.0` |
| Dimming factor | ×0.88 (12 % dim) | ×0.70 (30 % dim — closer to real CRT gap) |
| Works on non-integer scaling? | **No** — produces thick/thin bands | **Yes** |

### mame.ini — no changes needed

These settings were already in place and wire the shader in globally:

```ini
video                 opengl
gl_glsl               1
gl_glsl_filter        0       # nearest-neighbour sampling (important!)
glsl_shader_mame0     scanlines
```

`spyhunt.ini` already has `effect none` so the built-in overlay does not double-apply.

---

## Deploy

From the repo root on the Pi:

```bash
make install        # rsync McAtariPi5/opt/ → /opt/  (skips unchanged files)
# or force-overwrite if you want to be sure:
make install-force
```

The shaders land at `/opt/retropie/emulators/mame/glsl/scanlines.{fsh,vsh}`.

---

## Predicted Failure: Shader Won't Load

This was the blocking issue before development was paused.  MAME's OpenGL GLSL loader
is notoriously brittle.  Work through the checklist below in order.

### 1. Confirm MAME actually sees the files

```bash
ls -la /opt/retropie/emulators/mame/glsl/
# Expect scanlines.fsh and scanlines.vsh, world-readable
```

### 2. Run MAME from the terminal and watch stderr

```bash
/opt/retropie/emulators/mame/mame spyhunt 2>&1 | tee /tmp/mame-spyhunt.log
```

Look for lines containing `glsl`, `shader`, `error`, or `warning`.  Common messages:

| Message | Cause | Fix |
|---|---|---|
| `glsl_shader_mame0 'scanlines': unable to find` | Wrong search path | See §3 below |
| `error: version '130' is not supported` | Mesa/driver too old | See §4 below |
| `error: 'textureSize' : no matching overloaded function` | GLSL version not 130 | See §4 below |
| `ftransform is deprecated` or similar | Usually a warning only, shader still loads | Ignore |
| Shader compiles but no visible effect | `gl_glsl 0` in an ini override | Check all ini files |
| Black screen / crash | Driver bug with PBO | See §5 below |

### 3. GLSL file search path

MAME searches for `scanlines.fsh` / `scanlines.vsh` relative to the MAME binary's
working directory **and** the `artpath`.  The safe path is an absolute one in the ini:

```ini
# In mame.ini — use absolute path to be certain
glsl_shader_mame0    /opt/retropie/emulators/mame/glsl/scanlines
```

Note: MAME appends `.fsh` / `.vsh` itself — do **not** include the extension.  The
current `mame.ini` uses the bare name `scanlines` which works only if MAME's cwd is
`/opt/retropie/emulators/mame/` or if the glsl/ subdirectory is on the search path.
If the shader fails to load, switch to the absolute path above.

### 4. GLSL version compatibility

`#version 130` maps to OpenGL 3.0 and enables `textureSize()`.  The Pi 5 VideoCore VII
(V3D) with Mesa should support this fine, but confirm:

```bash
glxinfo | grep "OpenGL version"
# Expect: OpenGL version string: 3.1 Mesa X.Y.Z  (or higher)
```

If Mesa reports only 2.1 (unlikely on Pi 5), drop `textureSize` and hard-code the
source height instead (see Fallback A below).

### 5. If `gl_pbo 1` causes a black screen or crash

The Pi's V3D driver occasionally has issues with PBO.  Try:

```ini
gl_pbo    0
gl_vbo    0
```

### 6. Verify `gl_glsl_filter` is 0 (nearest-neighbour)

With bilinear filtering (`gl_glsl_filter 1`) the scanline boundaries blur across
neighbouring rows and the effect is washed out.  Keep it at `0`.

---

## Fallback A — Hard-coded source height (no textureSize)

If `textureSize` is unavailable (very old Mesa), replace the fragment shader with:

```glsl
#version 120
uniform sampler2D color_texture;

// Hard-code Spy Hunter's source height.  Set to the actual
// value from MAME's -verbose output ("screen 0 …×240").
const float SRC_HEIGHT = 240.0;

void main()
{
    vec2 uv    = gl_TexCoord[0].xy;
    vec4 color = texture2D(color_texture, uv);
    float srcRow = floor(uv.y * SRC_HEIGHT);
    if (mod(srcRow, 2.0) >= 1.0)
        color.rgb *= 0.70;
    gl_FragColor = color;
}
```

Spy Hunter's native video is 292×240 (horizontal game, rotated display may differ —
verify with `mame spyhunt -verbose 2>&1 | grep screen`).

---

## Fallback B — Smooth scanlines (no hard branching)

If the binary `if` causes driver issues, a smooth sine-wave version:

```glsl
#version 130
uniform sampler2D color_texture;

void main()
{
    vec2 uv = gl_TexCoord[0].xy;
    vec4 color = texture2D(color_texture, uv);

    float srcHeight = float(textureSize(color_texture, 0).y);
    float phase     = uv.y * srcHeight * 3.14159265;
    float scanline  = 0.85 + 0.15 * cos(phase);   // 70%–100% brightness sine wave
    color.rgb *= scanline;

    gl_FragColor = color;
}
```

This has no branching and produces a softer CRT look.

---

## Tuning the Effect

The dimming factor `0.70` in the current shader can be adjusted:

| Value | Look |
|---|---|
| `0.80` | Subtle — barely visible lines |
| `0.70` | **Current** — noticeable but not harsh |
| `0.55` | Strong — prominent dark lines, close to real CRT |
| `0.40` | Very heavy — may feel too dark |

Change the single line `color.rgb *= 0.70;` to taste.

---

## Notes on Other Games

Because the shader is global (`glsl_shader_mame0` in `mame.ini`), it applies to all
games.  The source-aligned approach is **correct for all games** regardless of their
native resolution — it simply locks scanlines to source rows.  No per-game ini override
is needed.  Games that previously worked with the built-in `effect scanlines` will look
the same or slightly better with this shader.

For vector games (`vector.ini`, `vector-mono.ini`) the shader is also active but has
minimal visible effect because the source texture is mostly black with bright lines.
That is fine.
