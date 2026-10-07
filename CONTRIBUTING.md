# Contributing

Bug reports and pull requests are welcome in English or Turkish. Check existing issues first.

For a bug, include macOS version, Mac chip family, monitor/audio device model, connection type, selected outputs, expected behavior and reproduction steps. Explain whether the issue affects native brightness, DDC or software dimming. Remove personal identifiers and unrelated log entries before attaching diagnostics.

Build with `./Scripts/build.sh`; run `./Scripts/test.sh` before opening a pull request. Keep changes focused. Audio callbacks must not allocate memory, log, access files or take blocking locks. Preserve original third-party notices and describe dependency changes.

Physical audio integration is opt-in: see `docs/DEVELOPMENT.md`. Do not claim hardware support based solely on unit tests. Include hardware used and practical limits when reporting results.
