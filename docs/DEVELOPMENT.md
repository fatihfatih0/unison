# Development

Open `Package.swift` in Xcode 26 or newer, or run the scripts from the repository root with those developer tools selected. The macOS 26 SDK is required for the capture exclusion fallback, while the deployment target remains macOS 14.4. No remote Swift Package dependencies are fetched: m1ddc and libASPL source snapshots are included.

```sh
./Scripts/test.sh
./Scripts/build.sh
./Scripts/build-installer.sh
```

`build/Products.noindex` holds the app. Installer builds produce a unique package path in `build/latest-installer-path.txt`. `build` and `.build` are excluded from Git. Installer preparation directories use `.noindex` to avoid duplicate app search results.

Local signing prefers an installed Apple Development identity. Set `UNISON_SIGN_IDENTITY=-` to force ad-hoc signing, or set it to a specific codesigning identity. Do not add credentials to Git.

CI explicitly selects Xcode 26.3 from the [macOS runner software inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).

## Optional hardware test

Quit the normal Unison instance first. This integration test requires two physical audio outputs, including a built-in volume-capable speaker and an external output. Allow capture permission if asked. It plays a quiet tone, temporarily changes routing/volume and restores previous state.

```sh
./Scripts/build.sh
./Scripts/test-audio.sh
```

The current smoke fixture was designed around a MacBook and HDMI monitor. It is opt-in and not run on CI. Hardware buffering checks do not prove matched acoustic latency or DDC backlight behavior.

The selection smoke run also simulates a departed Bluetooth headset without changing Bluetooth settings, including repeated early system fallbacks and a missing model default, then checks that automatic recovery starts the real Mac speaker and display outputs and delivers audio to both. A physical headset power-off remains a separate manual check. For AirPods, check with the panel closed: start speaker/display audio, switch to AirPods, put both earbuds in the case and close it, then wait for disconnection. Audio should return without opening the panel. Repeat with only the native speaker available. Optional `--audio-status <path>` diagnostics include the current/default UIDs and pending Bluetooth return.

## Updating bundled dependencies

The vendored libASPL contains the runtime headers, generated C++ sources and licenses needed by `build-driver.sh`. Upstream examples, generator tooling, documentation and Git metadata are omitted. For an upstream upgrade, use a separate checkout, preserve license notices, replace the runtime snapshot and update the revision in `THIRD_PARTY_NOTICES.md`. m1ddc contains local DDC packet validation changes; preserve them when upgrading.
