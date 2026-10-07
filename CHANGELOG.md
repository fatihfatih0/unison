# Changelog

## 0.1.0 — Preview

- SwiftUI menu bar panel for shared and per-device volume/brightness.
- Refined compact panel with sound/display tabs, visible percentages, selection marks and consistent blue/amber controls.
- Sliders support keyboard arrows, visible focus and reduced-motion preferences.
- HDMI and simultaneous audio through a local Core Audio Process Tap.
- Aggregate stream readiness uses cancellable asynchronous polling; stopping/restarting retires pending startup safely.
- DSP tests cover all 16 outputs, independent gains/mute and silent unconfigured channels.
- Built-in display brightness, compatible DDC displays and software dimming fallback.
- The built-in display slider follows macOS keyboard brightness changes; shared brightness stays independent.
- External SDR displays use verified gamma-table dimming, independent of fullscreen windows; overlay dimming remains a fallback.
- Draggable slider handles, hover feedback, mouse wheel control and horizontal trackpad gestures.
- Media keys and bidirectional macOS system volume integration.
- Shared mute preserves the native volume level; raising volume clears hardware mute.
- Native output selection follows changes made in macOS Sound settings.
- Slow DDC writes are verified after the final queued value; hardware brightness clears software dimming.
- Physical volume and mute settings are saved before normalization and restored on exit/recovery.
- Optional Unison HAL audio output and installer.
- English README and installation documentation, plus local/CI tests.

Early release: Apple Silicon, macOS 14.4+. Interface currently Turkish. Intel, broad device compatibility, acoustic synchronization and sleep/reconnection behavior remain unverified. Distributed builds are not currently Apple-notarized.
