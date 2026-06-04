subject: fix for Stable Controller IDs with duplicate <mapdevice> IDs

I’ve been using an AI generated patch for MAME input module applied to the Git master in a custom RetroPie-Setup build from source. It fixes a deficiency with the Stable Controller IDs mapdevice feature that I believe could be a useful contribution to the mamedev project.

My cabinet has:
1 XinMo encoder board with a USB connection that exposes two controllers (players 1-2) having duplicate IDs
1 iCode Retro Atari to USB converter with an old CX30 paddle set that also shows up as 2 duplicate IDs
4 additional USB controllers with unique IDs that map without any trouble

The failure scenario appears in <mapdevice> handling: when multiple entries share the same device ID, only one survives config loading, so the 2nd mapping is effectively lost. After that, the controller assignment in ioport.cpp mixes the devices up.

In practice, the old behavior fails to keep stable JOYCODE assignment for these duplicate-ID devices. The AI-generated fix preserves all <mapdevice> entries in config order instead of storing them in a unique-key container. With that change, both mappings are applied and the devices land in the intended slots.

I currently work around this in production with a Lua plugin that rewrites ioport sequences in memory on first frame, but I’d rather contribute the real fix upstream than keep maintaining a runtime workaround in RetroPie.

If a MAME dev is willing to take a look, I can provide:

- a minimal patch (2 lines of code)
- my exact <mapdevice> config
- evidence showing old behavior mixing the XinMo/iCode devices up, and patched behavior working correctly