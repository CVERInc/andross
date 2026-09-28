# 🤖 andross

A lightweight, native Android container for macOS on Apple Silicon (M1/M2/M3/M4).

andross gives you a clean Android phone that lives inside a Mac window — no
physical device required. Use it to run isolated accounts for any app that ties
one account to one device (LINE, messengers, games…), or to safely try out
`.apk` files. It deliberately skips the multi-gigabyte Android Studio install
and drives Google's official emulator engine directly through
`Hypervisor.framework`.

> **Status: v0.1.0 — early, GUI-only.** The app builds and runs; the
> identity lifecycle on an existing virtual phone (boot, sandboxes, install,
> clone, storage stats, uninstall an app) is exercised by an integration test.
> The in-window phone screen streams over scrcpy — hardware H.264, live touch,
> ~60fps on an Apple-silicon host — and the phone's audio streams with it
> (with a mute switch). Not yet signed/notarized for distribution.

---

## ✨ Features

* **Featherweight** — no Android Studio. Just Homebrew pulling Google's official
  command-line tools and emulator.
* **Native acceleration** — the emulator runs on `Hypervisor.framework`,
  mapping straight onto the M-series silicon.
* **Sandboxes** — built on Android's native multi-user system. Create fully
  isolated identities inside one virtual phone, clone an app into a new identity
  with one click, and sign into each separately.
* **Your choice of base image:**
  * Google Play image — for apps that need Google Mobile Services.
  * AOSP image — 100% open source, no Google services; install Play-store apps
    via the bundled Aurora Store.
  * Blank AOSP — local `.apk` drag-and-drop only.

---

## 🚀 Quick start

### 1. Build andross.app (no Xcode required)

```bash
./scripts/build-app.sh
```

This produces a double-clickable app at `/Applications/andross.app`. On first
launch macOS may warn it is unsigned — right-click → Open.

### 2. Do everything inside the app

* **Home** — shows the apps installed for the current identity; click one to
  open it on the virtual phone. Drop an `.apk` anywhere in the window to install.
* **Phones** (dock) — create your first virtual phone (it checks for and guides
  you through installing Java and the Android engine), then start or delete it.
  While a phone runs, its sandboxes live here too: create, switch, and delete
  isolated identities, and add installed apps to a new identity in one click.
* **Storage** (dock) — disk usage on this Mac, installed Android versions (remove
  the ones you don't use), and a clean-uninstall wizard (including the Homebrew
  components).
* **System** (dock) — engine status (Java, Android engine, Homebrew) and recent
  activity.
* **Settings** (dock) — window preferences and **Shut Down Phone**.

---

## 🛠 Development

```bash
./scripts/test.sh              # hermetic preflight + release build + unit tests
./scripts/test.sh integration  # boots a real AVD headless and walks the
                               # identity lifecycle (needs SDK + an existing AVD)
./scripts/check-hermetic.sh    # build-prerequisite preflight (run on a new Mac)
./scripts/make-icon.sh         # regenerate the app icon (assets/andross.icns)
```

CI runs `./scripts/test.sh` on every push and pull request, then packages the
app with `./scripts/build-app.sh` and runs its `--verify-resources` self-check.

### Reproducible build on a fresh Apple-silicon Mac

andross builds from a clean checkout with **no Xcode and no Android Studio** —
only Apple's Command Line Tools. The build is reproducible because the single
external dependency (the [Signet](https://github.com/CVERInc/signet) design
system) is pinned to a fixed revision in `Package.resolved`; SwiftPM resolves
that exact commit rather than whatever `main` happens to be.

Prerequisites on a brand-new machine:

1. **Apple silicon (arm64).** The emulator runs on `Hypervisor.framework` and
   maps onto M-series silicon.
2. **Command Line Tools** — `xcode-select --install` (provides `swift`). Full
   Xcode is *not* required.
3. **Network, once.** The first build fetches the pinned Signet revision from
   GitHub into `.build/checkouts/`. After that the build is offline-capable.

Verify all three before building:

```bash
./scripts/check-hermetic.sh    # exits non-zero if a prerequisite is missing
./scripts/build-app.sh         # → /Applications/andross.app
```

The Android engine itself (Google's `emulator` + `platform-tools`) is **not** a
build dependency — the app installs it for you at runtime via Homebrew the first
time you create a device, so it is never baked into the build.

---

## 📌 Honest boundaries

* Registering for services like LINE **still requires a phone number that can
  receive a verification code** — andross removes the need for an extra
  *handset*, not the phone number itself.
* LINE allows only one logged-in device per account. andross is for running
  **new/secondary** accounts, not for migrating an account off your existing
  phone.

---

## License

MIT © CVER Inc. See [LICENSE](LICENSE).

Vendors [scrcpy-server](https://github.com/Genymobile/scrcpy) (Apache License
2.0) to stream the embedded device screen — see
[Third-Party/scrcpy](Third-Party/scrcpy).
