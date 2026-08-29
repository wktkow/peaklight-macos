# White-only physical dimming with unchanged final RGB: feasibility

## Required behavior

The investigated mode had a strict requirement: lower the emitted nits of
selected white desktop pixels while leaving both the applications' source RGB
and WindowServer's final composited RGB values unchanged. RGB multiplication,
alpha blending, color transforms, gamma/LUT changes, capture/replay, and
display-wide brightness changes were explicitly out of scope.

## Result

On the tested Apple-silicon host running macOS 26.5.2 (25F84), no documented
or otherwise deployable application API exposing such a channel was
identified. Peaklight therefore does not ship a mode that claims unchanged
final RGB. The earlier experimental backdrop/black-alpha implementation was
removed because it changed broad areas of the final RGB values and did not
meet the requirement.

This is a colorimetric constraint as well as an API limitation. Let `F` be the
fixed display pipeline, including encoding, metadata, display state, and
transfer behavior. For composited frame `C`, emitted tristimulus at pixel `p`
is `XYZ_p = F_p(C)`, and luminance is the `Y` component. A bit-identical final
frame under the same `F` produces the same `XYZ` and nits. Reducing `Y`
requires changing RGB or changing the mapping or hardware drive. A spatial
light-output plane, such as per-pixel emissive drive or local-backlight
control, could provide the latter in principle, but no documented or
deployable application interface to one was identified.

Scaling display-linear RGB by a common positive scalar `0 < g < 1` preserves
chromaticity for fixed primaries and absent clipping, but the channel
amplitudes still change. Peaklight's separately labeled compositor mode now
implements that different feature: it classifies neutral near-whites with a
static LUT and applies a grayscale gain adjustable from `1` to `0`. It does not
satisfy, and does not claim to satisfy, the strict unchanged-final-RGB
requirement audited in this document.

## Paths audited

| Candidate | What it actually controls | Why it fails |
| --- | --- | --- |
| EDR float values / PQ / HLG | Color components and transfer behavior | EDR linear values carry luminance in their magnitude; PQ/HLG define transfer behavior. Different output requires different components or a different declared rendering transform, neither of which is an independent luminance plane. |
| `CAEDRMetadata` | One tone-mapping description per `CAMetalLayer` | It is not a per-pixel control field. One metadata object describes the receiving layer and does not reinterpret desktop layers behind it. |
| `contentsHeadroom`, `CGColor` headroom, `kIOSurfaceContentHeadroom` | A scalar declaration of used dynamic range | `0` means unknown or untagged. Supported specified values are at least `1`; sub-1 values are undefined, normalized, or treated as unknown depending on the API. |
| HDR/ISO gain maps | Per-pixel image-reconstruction metadata | Applying the map derives different rendered color components. It is image-reconstruction data, not a second scanout luminance plane. |
| Private `kIOSurfaceEDRFactor` | One scalar per IOSurface | On build 25F84, QuartzCore's shipped shader applies the factor to `out.rgb`; it is an RGB multiplier. |
| Private `CALayer.gain`, `CAFilter` `edrGain`, and `edrGainMultiply` | Compositor image filters | On build 25F84, tests and shipped shader code show RGB replacement or multiplication. |
| Private SkyLight window brightness | One scalar per whole window | On build 25F84, the compositor shader adds brightness to RGB and applies an HDR RGB scale. It is not a physical-light plane. |
| Backdrop/LUT/black-alpha overlay | A destination-aware composited mask | Source-over blending lowers final RGB. It was the rejected prototype. |
| CoreDisplay, DisplayServices, IOKit brightness/reference modes | Display-wide panel/reference-white controls | They are display-scoped rather than selected-pixel controls; depending on the path, they alter backlight, reference white, or tone mapping. |
| Internal mini-LED local dimming / IOMFB gain data | Firmware/DCP/TCON processing or privileged image gain | No documented or deployable application API was identified. A mini-LED zone can also affect non-white neighboring pixels unless RGB is compensated. |

Apple's public model is consistent with these results: public onscreen HDR
controls expose color textures and layer/content metadata, while gain maps
reconstruct different rendered color values instead of supplying a separate
physical-output plane. Relevant primary
references are [Metal HDR content](https://developer.apple.com/documentation/metal/hdr-content),
[performing your own tone mapping](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping),
[`CAEDRMetadata`](https://developer.apple.com/documentation/quartzcore/caedrmetadata),
and [Apple HDR gain maps](https://developer.apple.com/videos/play/wwdc2024/10177/).

## Host validation evidence

The checks were run on a Mac14,5 with Apple M2 Max, macOS 26.5.2
(25F84), Xcode 26.6 (17F113), and the macOS 26.5 SDK.

The static shader evidence can be inspected again on that exact OS build:

```sh
shasum -a 256 \
  /System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib \
  /System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib

xcrun metal-objdump -ml -d \
  /System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib \
  | rg -n -C 12 'edr_gain_filter|edr_factors|fc_has_edr_factor'

xcrun metal-objdump -ml -d \
  /System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib \
  | rg -n -C 12 'UberCompositeFragment|enable_bright|_brightness|_hdr_scale'
```

The expected SHA-256 values are
`5c676a9344bd1d013459d239051f621ef4f1fc14aa7da95b2fd285bb2d1607dd`
for QuartzCore and
`ccdb4d166f066d0b6d6a57a084ac0a31da2c84e7fa5ae873acc628e4e5dcaf77`
for SkyLight.

The live compositor probes used ScreenCaptureKit's
`.captureHDRScreenshotLocalDisplay` preset, `.hdrLocalDisplay` dynamic range,
`kCVPixelFormatType_64RGBAHalf`, and extended Display P3. Samples below are
therefore half-float capture-space components:

- A private SkyLight brightness value of `-0.5` changed white
  `(1, 1, 1)` to `(0.5, 0.5, 0.5)` and blue `(0, 0, 1)` to
  `(-0.5, -0.5, 0.5)`. Gray `(0.5, 0.5, 0.5)` became `(0, 0, 0)`, and orange
  `(1, 0.5, 0.1)` became `(0.5, 0, -0.4)`, within `0.01`. Brightness `0`
  matched baseline within `0.003`. This matches SkyLight's additive RGB
  shader, not RGB-independent physical-light control.
- QuartzCore's `IOSurfaceEDRFactor` shader path loads a scalar, optionally
  linearizes the sampled color, computes `out.rgb = factor * in.rgb`, and
  re-encodes it. Alpha is retained.
- `CALayer.gain = 0.25` changed an extended-linear sample `(2, 1, 0.5)` to
  `(0.5, 0.25, 0.125)` with unchanged alpha.
- `CAEDRMetadata.hdr10` probes used minimum luminance `0.005`, maximum
  luminance `1000`, and optical output scales 25, 50, 100, and 200. With the
  same source patches, all four captured approximately `0.736` for SDR white
  `(1, 1, 1)` and `0.98` for the active component of HDR blue `(0, 0, 2)`.
  No-metadata baselines were approximately `1.0` and greater than `1.5`,
  respectively. The metadata altered layer tone mapping but did not supply an
  independently adjustable per-pixel output.
- The probed display registry advertised 2-D backlight capability but exposed
  only scalar brightness/nits controls to the application process; no
  writable spatial control was identified.

The private live-probe harness and raw logs were research-only and were removed
with the rejected implementation; they are not linked into the application.
The numeric live results above are approximate. The static shader commands and
hashes are retained so the decisive RGB data paths remain independently
inspectable on the tested build.

## Revisit gate

This feature should only be reconsidered if macOS adds a documented,
deployable spatial luminance or local-dimming API. A candidate must pass all
of these checks:

1. Application source textures remain bit-identical.
2. HDR capture of final WindowServer RGB remains bit-identical.
3. A colorimeter measures lower luminance only on selected neutral pixels.
4. Colored and dark neighboring pixels remain physically unchanged.
5. No RGB filter, blend, LUT, capture/replay, or global brightness fallback is
   involved.

No audited path passes those requirements.
