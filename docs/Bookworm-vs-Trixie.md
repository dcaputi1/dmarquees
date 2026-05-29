# Bookworm vs Trixie for IvarArcade Pi 5 Baselines

This note is a parking spot for the distro decision around the Pi 5 arcade baseline.
The current plan is still to finish the Trixie baseline first, but Bookworm remains the fallback path.

## Short Answer

The current `RetroPie-Setup` + `IvarArcade` workspace still looks viable on both:

- `Trixie` is the active in-progress baseline.
- `Bookworm` looks like the lower-risk fallback if Trixie keeps causing platform-level issues.

## Why Bookworm Still Looks Safe

Evidence in the current workspace:

- `RetroPie-Setup` still ships Raspberry Pi OS `bookworm` image definitions for `rpi5`.
- Helper/package logic in `RetroPie-Setup` already handles Pi 5 package naming for Bookworm-era Raspberry Pi OS.
- The custom `mame.sh` changes made for current MAME builds should still be compatible with Bookworm:
  - explicit `qmake6` dependency for Qt debugger builds
  - forced `-std=c++20`
  - `REGENIE=1`
  - custom mapdevice duplicate-ID patch flow

None of those changes are Trixie-only.

## Why Trixie Has Been Harder

Observed from local notes and recent work:

- Trixie needed at least one explicit sound workaround: `set_asound.sh`.
- Notes mention Trixie-specific friction around EmulationStation autostart.
- Notes also mention Pi Connect / screen-share issues after RetroPie setup on the Trixie attempt.
- Recent MAME build failures on Trixie were caused by newer distro/toolchain behavior, not by the basic IvarArcade layout.

That does not mean Trixie is a dead end. It just means it is the noisier baseline right now.

## Current Recommendation

Keep trying to finish the `Trixie` baseline first.

If that effort stalls because of OS-level issues rather than project-level issues, fall back to `Bookworm` and reuse the same high-level install flow:

1. Clone `IvarArcade`.
2. Clone the patched `RetroPie-Setup` you want to use for the MAME changes.
3. Run `sudo env IVAR_MAME_PROFILE=full ./retropie_setup.sh`.
4. Build/install the experimental `mame` package from source.
5. Continue with the normal IvarArcade deployment steps.

## What Likely Changes on Bookworm

Keep:

- the current patched `RetroPie-Setup/scriptmodules/emulators/mame.sh`
- the `IVAR_MAME_PROFILE=full` first-build path
- the rest of the IvarArcade deployment flow

Re-check or skip:

- `set_asound.sh` unless Bookworm shows the same sound issue
- any Trixie-specific EmulationStation autostart workaround
- any Trixie-specific desktop/service quirks

## Open Questions for Later

- Should the baseline docs explicitly split Pi 5 setup into `Bookworm` and `Trixie` sections?
- Should `McAtariPi5/readme.txt` name the exact `RetroPie-Setup` repo/branch to use for each distro?
- If Trixie succeeds, are there any remaining reasons to prefer Bookworm besides lower churn?

## Next Time

When resuming this discussion, useful follow-ups would be:

- convert this note into a tighter checklist
- update `McAtariPi5/readme.txt` with a clean distro split
- decide whether the default fallback baseline should officially be Bookworm on Pi 5