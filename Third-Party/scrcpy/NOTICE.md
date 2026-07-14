# scrcpy-server

andross vendors the prebuilt `scrcpy-server` binary from
[Genymobile/scrcpy](https://github.com/Genymobile/scrcpy), used unmodified to
stream the embedded device screen (video + touch input) over a local ADB
socket. It runs entirely on the emulated device (via `app_process`), not on
the host.

- Version: v4.0
- Source: https://github.com/Genymobile/scrcpy/releases/download/v4.0/scrcpy-server-v4.0
- SHA-256: `84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a`
  (matches the project's own `SHA256SUMS.txt` for the v4.0 release, and
  independently matches the sha256 pinned in Homebrew's `scrcpy.rb` formula)
- License: Apache License 2.0 — see `LICENSE` in this directory.
