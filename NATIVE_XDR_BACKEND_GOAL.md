# Native XDR Backend Goal

Peaklight should keep the public EDR overlay as the default backend and treat native/private XDR display-pipeline control as a separate research track.

## Default Backend

Use the public EDR overlay path by default.

- Low risk.
- Low latency.
- No screen capture.
- No gamma/LUT distortion.
- Good black preservation.
- Known limitation: Mission Control, Spaces animations, and some system compositor transitions may not be covered reliably.

## Research Backend

Explore a native/private XDR backend only as an experimental option.

Goal:

```text
whole-system brightness boost
no screen capture
no gamma-table hacks
no framebuffer readback
no meaningful input latency
minimal compute overhead
```

Strict acceptance criteria:

- Applies through Mission Control, Spaces, fullscreen transitions, and desktop overview.
- Does not require screen capture or Screen Recording permission.
- Does not require disabling SIP.
- Does not alter gamma/LUT curves as the primary mechanism.
- Preserves black level better than gamma-table approaches.
- Fails closed back to normal SDR behavior.
- Recovers cleanly after sleep, wake, display changes, and power-state changes.
- Is clearly labeled experimental until it proves stable across macOS updates.

## Rejected Defaults

Do not make these the default behavior:

- Gamma/LUT boosting, because it trades color and tone accuracy for perceived brightness.
- Screen capture and re-rendering, because it is expensive, invasive, latency-prone, and creates privacy/copyright edge cases.

## Product Position

Peaklight should be honest about the tradeoff:

```text
Default: safe public EDR overlay
Experimental: native XDR display-pipeline research
Rejected by default: gamma hacks and screen capture
```
