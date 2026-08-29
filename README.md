<p align="center">
  <img src="icon.png" alt="Peaklight icon" width="160" height="160">
</p>

<h1 align="center">Peaklight</h1>

<p align="center">
  Raise the peak, keep the floor.
</p>

Peaklight is a lightweight macOS menu-bar app for boosting SDR peak brightness on XDR-capable displays without gamma-table hacks. The first implementation uses a low-overhead EDR Metal overlay with multiply compositing, capped at about 800 nits by default.

## What It Does

- Adds menu-bar presets for native SDR, 600 nits, 700 nits, and 800 nits.
- Uses one click-through, borderless `MTKView` overlay per EDR-capable display.
- Renders in `rgba16Float` with extended linear Display P3 and `CAMetalLayer.wantsExtendedDynamicRangeContent`.
- Uses multiply compositing so pure black remains black.
- Provides an opt-in, capture-free compositor mask with a 0–100% attenuation
  slider. Saturated colors and non-highlight pixels pass through unchanged.
- Caps boost using current EDR headroom, battery state, and thermal pressure.
- Keeps launch-at-login off and unimplemented by default.
- Provides an opt-in brightness-key event tap for the extended range.

## Important Limits

Peaklight does not write gamma tables, install display presets, change reference modes, or use private CoreDisplay brightness control.

The current boost mode is a clean multiply overlay:

```text
output = input x boost
```

That preserves true black, but near-black values still become brighter. The planned Shadow-Safe mode is shown in the menu as an experimental future feature because a real soft-toe curve needs access to the underlying pixel values, which the constant overlay does not have.

A white-only physical-dimming mode with unchanged final RGB is not available.
On the tested macOS 26.5.2 build, no audited deployable API exposed per-pixel
luminance control independent of final RGB. Every audited spatial path changed
composited RGB; application-accessible brightness controls were display-wide.
See
[White-only physical dimming with unchanged final RGB](WHITE_DIMMING_FEASIBILITY.md) for
the colorimetric boundary, API audit, and host validation evidence.

Peaklight also offers a clearly separate, opt-in RGB white-dimming mode on the
qualified macOS build. A WindowServer backdrop filter uses a static 3D LUT to
select neutral highlights during composition, then composites a black
attenuation mask over only the selected pixels:

```text
gain = 1 - dimmingAmount x nearWhiteNeutralMask
outputRGB = inputRGB x gain
0.0 <= gain <= 1.0
```

The affected RGB values are reduced; this is not an independent hardware-light
channel. The pure-white endpoint is transfer-function calibrated: 50% targets
half the linear-light output, while 100% maps a fully selected white to black.
The graph is evaluated by the
compositor against the current frame, so Peaklight neither captures nor replays
the desktop, needs no Screen Recording permission, and has no trailing frame
mask. Transient overlay behavior removes it from Mission Control.

The nits labels are approximate. Peaklight treats 500 nits as SDR reference white on MacBook Pro XDR displays and maps:

```text
600 nits = 1.2x
700 nits = 1.4x
800 nits = 1.6x
```

Actual luminance depends on display mode, hardware brightness, ambient behavior, power state, thermal state, and macOS EDR headroom.

## Build

This repository is implemented as a Swift Package:

```sh
swift build
swift run PeaklightPolicyTests
```

Those commands build and test the source only. They do not install Peaklight, register launch-at-login, launch the app, or modify your system display configuration.

To build a release app bundle and install it at the canonical local path
`~/Applications/Peaklight.app`:

```sh
Scripts/package-app.sh
```

The script intentionally rejects `INSTALL_DIR` overrides.
The packaging script generates `Peaklight.icns` from `icon.png` and embeds it in the app bundle.

To build a local installer package (the app is ad-hoc signed and the package
is unsigned):

```sh
Scripts/package-pkg.sh
```

## Current Scope

Implemented:

- Menu-bar app shell.
- EDR display detection through `NSScreen`.
- Metal overlay engine.
- 500 to 800 nit virtual brightness model.
- Battery and thermal caps.
- Screen-change and wake recovery.
- A per-user process lock that prevents duplicate overlays.
- Kill switch.
- Opt-in brightness-key interception, requiring Accessibility permission at runtime.
- Opt-in, compositor-side neutral-highlight attenuation, adjustable to 100%.
- Runnable policy checks for the brightness model.
- App bundle and installer package generation.

Not implemented yet:

- Native 0 to 500 nit brightness control.
- A real pixel-aware Shadow-Safe boost curve.
- HDR-video detection or auto-disable.
- Notarization, DMG, Homebrew cask, or launch-at-login registration.

Not supported by the tested platform contract:

- Per-pixel physical white dimming with unchanged final RGB. Reconsider only
  if macOS exposes a documented, deployable spatial light-output API.

## Safety Model

Peaklight intentionally keeps the invasive pieces out of v0.1:

- No gamma/color-table modification.
- No display preset installation.
- No private hardware brightness writes.
- No launch-at-login registration.
- White dimming uses a compositor backdrop filter and does not capture or
  retain desktop frames.

The menu kill switch sets the virtual target back to native SDR and removes all
overlay windows.
