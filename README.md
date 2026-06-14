# Peaklight

Raise the peak, keep the floor.

Peaklight is a lightweight macOS menu-bar app for boosting SDR peak brightness on XDR-capable displays without gamma-table hacks. The first implementation uses a low-overhead EDR Metal overlay with multiply compositing, capped at about 800 nits by default.

## What It Does

- Adds menu-bar presets for native SDR, 600 nits, 700 nits, and 800 nits.
- Uses one click-through, borderless `MTKView` overlay per EDR-capable display.
- Renders in `rgba16Float` with extended linear Display P3 and `CAMetalLayer.wantsExtendedDynamicRangeContent`.
- Uses multiply compositing so pure black remains black.
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

To build a release app bundle and install it into `~/Applications`:

```sh
Scripts/package-app.sh
```

Set `INSTALL_DIR=/Applications` if you want a system-wide install instead.

## Current Scope

Implemented:

- Menu-bar app shell.
- EDR display detection through `NSScreen`.
- Metal overlay engine.
- 500 to 800 nit virtual brightness model.
- Battery and thermal caps.
- Screen-change and wake recovery.
- Kill switch.
- Opt-in brightness-key interception, requiring Accessibility permission at runtime.
- Runnable policy checks for the brightness model.

Not implemented yet:

- Native 0 to 500 nit brightness control.
- A real pixel-aware Shadow-Safe boost curve.
- HDR-video detection or auto-disable.
- App bundle packaging, notarization, DMG, Homebrew cask, or launch-at-login registration.

## Safety Model

Peaklight intentionally keeps the invasive pieces out of v0.1:

- No gamma/color-table modification.
- No display preset installation.
- No private hardware brightness writes.
- No launch-at-login registration.
- No screen capture or desktop re-rendering.

The menu kill switch sets the virtual target back to native SDR and removes all overlay windows.
