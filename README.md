# 🤖 andross

A lightweight, native Android container for macOS on Apple Silicon (M1/M2/M3/M4).

andross gives you a clean Android phone that lives inside a Mac window — no
physical device required. Use it to run isolated accounts for any app that ties
one account to one device (LINE, messengers, games…), or to safely try out
`.apk` files. It deliberately skips the multi-gigabyte Android Studio install
and drives Google's official emulator engine directly through
`Hypervisor.framework`.

> **Status: v0.1.0 — early, GUI-only.** The app builds and runs; core flows
> (create device, sandboxes, install/launch apps, clean uninstall) are
> exercised by an integration test. The in-window phone screen is a **beta**
> (raw-frame streaming over adb). Not yet signed/notarized for distribution.

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
* **Devices** (dock) — create your first virtual phone (it checks for and guides
  you through installing Java and the Android engine), then start or delete it.
* **Sandboxes** (dock) — create, switch, and delete isolated identities, and add
  installed apps to a new identity in one click.
* **Settings** (dock) — system status, disk usage, recent activity, shut down
  all phones, and a clean-uninstall wizard (including the Homebrew components).

---

## 🛠 Development

```bash
./scripts/test.sh              # release build + unit tests (zero-dependency runner)
./scripts/test.sh integration  # boots a real AVD headless and walks the
                               # identity lifecycle (needs SDK + an existing AVD)
./scripts/make-icon.sh         # regenerate the app icon (assets/andross.icns)
```

CI runs `./scripts/test.sh` on every push and pull request.

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
