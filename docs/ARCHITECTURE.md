# Architecture

Unison is a Swift Package executable with an AppKit/SwiftUI menu bar interface and a small C realtime audio target. The optional HAL driver is a separate C++ bundle.

| Path | Responsibility |
| --- | --- |
| `Sources/Unison/UnisonApp.swift` | Panel, accessible sliders, hover and scoped mouse-wheel/trackpad scroll handling |
| `ControlModel.swift` | Device state, selections, routing and lifecycle |
| `AudioOutputSelection.swift` | Native selection follows the active output, including temporary Bluetooth routes |
| `BluetoothRouteRecovery.swift` | Remembered output group and automatic return after a temporary Bluetooth route |
| `SoftwareAudio.swift` | Core Audio Process Tap and private multi-device aggregate |
| `Sources/RealtimeAudio` | Stereo distribution and atomic per-device/master gain; no allocation or logging in the callback |
| `CoreAudioControl.swift` | Devices, legacy/modern volume controls and native aggregates |
| `SystemVolumeBridge.swift` | Bidirectional system volume, avoiding double gain and restoring routing |
| `MediaKeys.swift` | Media/function keys, repeat handling and native key pass-through |
| `DDC.swift`, `LatestValueQueue.swift` | DDC helper and coalesced writes |
| `NativeBrightness.swift`, `DisplayGamma.swift`, `ScreenShade.swift` | Native brightness, verified gamma dimming and overlay fallback |
| `Driver/UnisonAudio.cpp` | Two-channel Float32/48 kHz virtual output with volume/mute controls |

The audio engine starts without muting the source. It activates forwarding only after detecting a non-silent input signal. Separate physical outputs use separate stereo buffers (`stacked=0`). The native multi-output group uses shared stereo (`stacked=1`). The app excludes its own audio process from capture.

Aggregate stream readiness is polled asynchronously on the main actor with a 500 ms deadline. Each startup owns its tap, aggregate and DSP resources; cancellation or a newer session prevents a suspended startup from registering a callback or cleaning up the replacement session. Stopping the engine cancels pending readiness/activation work. Realtime output channels outside the configured device layout remain silent.

The virtual driver exposes an output and a clock; it does not forward audio by itself. The app forwards captured audio to physical outputs. With the named endpoint, native speakers apply the shared level through their hardware volume controls and DSP passes their samples without a second gain. HDMI outputs apply the shared scalar level in DSP. The virtual endpoint's nominal dB curve is not used for physical attenuation. Normal exit restores physical levels, mute settings and the previous route. After a forced termination, reopening attempts recovery.

Switching from a configured software/native group to a separate Bluetooth output saves that group's device UIDs, mode and shared volume/mute before stopping it. An existing macOS multi-output device is remembered by UID and selected again directly. The pending return survives app restarts. Once the headset disconnects and all saved outputs are available, the app resumes the group. Default-output notifications may precede headset departure by many seconds, so the return stays armed while the headset is available, regardless of elapsed time or interim system fallbacks. A system switch while the headset remains available is left alone; the saved return runs on its eventual disconnect. Explicit selection/start/stop actions in Unison cancel the pending return, as does another system route change while waiting for missing group members after departure. Devices reported as no longer alive are excluded from available outputs. Per-device Bluetooth availability listeners refresh this state even when the device list and default have not changed; processing aggregates are excluded from these subscriptions. A missing or stale default does not block recovery; the app selects a native fallback before starting forwarding asynchronously.

If Bluetooth takes over without an active group, an automatic return saves the built-in speaker's native volume/mute. On disconnect it resolves the live built-in speaker and HDMI/DisplayPort audio endpoints by Core Audio transport type, including a display attached while the headset was in use. Managed software/native groups also return to this live speaker/display combination when display audio is available, preserving their mode and shared volume/mute; an explicitly remembered macOS aggregate returns to that device. Multiple automatic targets start software forwarding; a speaker alone uses native routing. Aggregate devices, Bluetooth, USB speakers and the separate built-in headphone jack are excluded from automatic membership. This return is also armed when the app launches with Bluetooth already active. Repeated refreshes of the same headset do not re-arm a canceled return.

HAL default-output and device-list notifications, manual device refreshes and volume-key handling share the same routing refresh. A stopped group's saved members cannot keep F10/F11/F12 attached to the speaker while a separate Bluetooth output is active. Each key checks the current route before deciding between native media-key pass-through and Unison's function-key handling. Nested refreshes during group shutdown/recovery are suppressed.

Audio is processed in local memory, without recording or uploading. Preferences store device IDs and levels. There is no telemetry. DDC and built-in brightness use private Apple interfaces, so OS changes may affect support.

Third-party source snapshots and all relevant notices are in `Vendor` and `THIRD_PARTY_NOTICES.md`.

Software dimming prefers the display gamma table on SDR screens. The original per-channel calibration is scaled and restored on normal exit; writes are read back before accepting gamma control. Unsupported/HDR outputs use an overlay. Other apps that adjust gamma may conflict with software dimming.
