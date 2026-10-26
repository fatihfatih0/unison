# Changelog

## 0.1.0 — Preview

- Bluetooth return stays saved until routing and audio startup succeed; transient failures retry, while explicit stop/selection cancels the return. Menu-bar quit preserves it across restart.
- Stopping the virtual output falls back to an available physical speaker if the previous output was unplugged.
- Native volume readback accounts for per-device calibration, preventing repeated attenuation during polling and mute/unmute.
- Linked DDC monitor volume follows shared controls during software audio and native system-volume changes.
- Software dimming is reapplied when an external display reconnects.
- DDC display selection rejects zero, negative, empty and overflowing numeric indices.
- Hardware-independent model regression tests cover recovery, route completion, shutdown, calibration, linked DDC and display reconnection.
- SwiftUI menu bar panel for shared and per-device volume/brightness.
- Refined compact panel with sound/display tabs, visible percentages, selection marks and consistent blue/amber controls.
- Sliders support keyboard arrows, visible focus and reduced-motion preferences.
- Native output and shared volume sliders update together immediately; system volume notifications replace waiting for the device polling cycle.
- Pending macOS output routing gets a bounded grace period; regression checks exercise repeated multi-output / HDMI-only transitions.
- Bluetooth headsets temporarily suspend the configured outputs and preserve pending route recovery across app restarts.
- Delayed AirPods case disconnects no longer expire pending recovery after three seconds. Device availability changes trigger recovery even with a stale or missing system default; a native fallback is selected before group startup.
- Bluetooth disconnects return managed audio to the Mac speaker together with currently available HDMI/DisplayPort audio, preserving the group's mode and shared volume. Without a previous group or display audio, the native Mac speaker remains active; explicitly remembered macOS multi-output devices are restored directly.
- F10/F11/F12 follow the active Bluetooth output immediately, even when a stopped multi-output group remains saved; device refreshes and route notifications keep the selection and native controls synchronized.
- Saved, stopped output groups no longer swallow native volume keys or Apple's volume indicator. Function-key mode forwards F10/F11/F12 as native media keys when system volume is available; native-key checks avoid full device scans inside the event tap.
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
- Native speakers retain their hardware volume curve in multi-output mode; HDMI applies the shared scalar level once in DSP.
- Physical volume and mute settings are saved before processing and restored on exit/recovery.
- Audio regression checks measure isolated tone amplitudes, native volume parity and HDMI-only gain after multi-output transitions.
- Optional Unison HAL audio output and installer.
- English README and installation documentation, plus local/CI tests.

Early release: Apple Silicon, macOS 14.4+. Interface currently Turkish. Intel, broad device compatibility, acoustic synchronization and sleep/reconnection behavior remain unverified. Distributed builds are not currently Apple-notarized.
