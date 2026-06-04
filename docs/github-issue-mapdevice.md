Title: Duplicate <mapdevice> device IDs lose later mappings during config load

I believe there is a bug in MAME's `<mapdevice>` handling when multiple entries share the same `device` ID.

My cabinet has:
- one XinMo USB encoder that exposes two player controllers under the same device ID
- one iCode Retro Atari USB converter with a CX30 paddle set that also presents duplicate device IDs
- four additional USB controllers with unique IDs that map correctly

The failure mode appears to be that when multiple `<mapdevice>` entries use the same `device` ID, only one survives config loading, so the later mapping is lost. After that, the duplicate-ID devices do not keep stable JOYCODE assignment and the controller assignment path mixes them up.

Representative config:

```xml
<mapdevice device="0300d582c0160000e105000010010000" controller="JOYCODE_2" />
<mapdevice device="0300d582c0160000e105000010010000" controller="JOYCODE_3" />

<mapdevice device="030083a08f0e00001330000011010000" controller="JOYCODE_6" />
<mapdevice device="030083a08f0e00001330000011010000" controller="JOYCODE_7" />
```

My understanding is that the issue is caused by storing the parsed `<mapdevice>` entries in a unique-key container, so later duplicate `device` IDs are discarded during config load.

I have a small local fix that preserves `<mapdevice>` entries in config order instead of storing them in a unique-key container. With that change, both mappings are applied and the devices land in the intended JOYCODE slots.

The patch is effectively two source-line changes across:
- `src/emu/input.h`
- `src/emu/ioport.cpp`

I currently work around this in production with a Lua plugin that rewrites ioport sequences in memory on first frame, but I would rather contribute the actual source fix upstream than maintain a runtime workaround.

If this looks like a valid issue, I can provide:
- a minimal patch
- the exact config I am using
- specific before/after evidence showing the old behavior mixing the XinMo and iCode devices up, and the patched behavior working correctly
- testing details from a custom RetroPie-Setup source build against current MAME
