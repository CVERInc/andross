# Phone-first shell — UX overhaul spec

> Drafted 2026-07-15 from a full-surface audit (every screen walked, screenshots
> + code). Trigger: the maintainer — the app's own author — deleted their phone
> to test starting over, and got stuck rebuilding it. The empty→running journey
> is the product's spine and it doesn't carry you. Everything below serves one
> sentence: **andross is a phone, not an emulator frontend.**
>
> Acceptance test for the whole spec: wipe everything, hand the app to someone
> who has never seen it, and they reach a running phone without meeting a single
> emulator/dev word (AVD, API level, adb, Homebrew) or a dead end. The
> maintainer's own "delete everything and start over" run is the regression test.

## Phase 1 — Truth & safety (small diffs, do first)

Stop the app lying or destroying; no redesign yet.

1. **Ghost cache.** `cachedPackages` renders a deleted phone's apps forever.
   Purge the cache when its phone is deleted; never show tiles for a phone that
   doesn't exist. (Today: tapping one tries to boot a ghost and fails into a
   log the user can't see.)
2. **Clipped caption.** The home status line ("Phone is off — tap an app…")
   sits half-under the island. Give the grid's header real clearance below the
   64pt strip.
3. **Deleting a phone must be recoverable.** `avdmanager delete` vaporises the
   `.avd` dir. Replace with: shut down if running, then move `<name>.avd` +
   `<name>.ini` to the **Trash** (`NSWorkspace.recycle`). Dialog rewrites
   itself: "moves this phone and its data to the Trash — recoverable until you
   empty it." (Third guard was missing; it cost a phone today.)
4. **Disarm the uninstall section.** It sits permanently open with "Delete all
   virtual phones and their data" **pre-checked**. Collapse to one quiet
   "Uninstall andross…" row that opens a sheet; destructive boxes start
   unchecked; the sheet lists exactly what will be removed.
5. **Kill lying/stale copy.**
   - "the phone lives in the Screen view (a few frames per second)" → it's
     60fps H.264 now; drop the parenthetical and the "Beta" tag.
   - "Beta · Click screen to type · Streams over adb" → implementation details
     off the UI; if a hint is needed: "Click the screen to type."
   - "Shut Down All Phones" → "Shut Down Phone" (one runs at a time).
   - "Zero KB" → "—".

## Phase 2 — One name per thing

The same object is called Devices / Your Virtual Phones / virtual device / AVD
/ phone depending on the screen. Lock the vocabulary:

| concept | the one name | banned |
|---|---|---|
| the virtual Android machine | **phone** | device, AVD, virtual device |
| the surface listing them | **Phones** | Devices, Your Virtual Phones |
| per-phone Android users | **Profiles** | Sandboxes, Identity Sandboxes, identities |
| Android version in UI | **Android 16** (release name) | API level 36 |
| image flavor | "with Google Play" / "without Google (Aurora Store)" / "bare Android" | Play Store / AOSP+Aurora / Blank AOSP |

## Phase 3 — The shell: dissolve the dock, power to the island

The dock mixes one *action* (Power) with three *places*, hides its labels, and
its 4-across rhythm fights the grid's 3-across (maintainer's catch). A real
phone has neither: places are apps, power is hardware.

1. **Power moves to the island** — the island is andross's hardware chrome
   (same reasoning that gave it the traffic lights). Home island, trailing
   side: when a phone exists and is off → a power button that boots it; when
   running → the existing screen/pop-out controls (power-off lives in the
   Phones surface and the ✕ flow, shutdown-while-using is rare).
2. **Places become system tiles.** "Phones" and "Settings" join the app grid
   as its last tiles, visually system-flavored (outlined green, like the dock
   icons today) but on the same 3-column rhythm. Dock deleted. The bottom pill
   (Android's own gesture bar) stays as the one way back from any surface —
   that's the phone metaphor working for us.
3. **Sandboxes surface deleted**; Profiles render as a section inside a
   phone's page in Phones. (A profile is a property of a phone, not a place.)

## Phase 4 — The journey: empty → running, one path

The flow that stuck the maintainer. Home is the only stage; no surface-hopping.

1. **First-run / empty state**: no phone → the grid area shows a single hello
   card: "Set up your phone" + one button. No hunting through Phones → Add.
2. **Creation defaults**: one primary "Create" — auto name, newest Android,
   Google Play flavor, phone-portrait. Every current form field (version,
   flavor, tablet/landscape) survives behind an "Advanced" disclosure, worded
   per the Phase-2 table.
3. **Progress with a story**: the hello card itself narrates ("Downloading
   Android 16 (2.1 GB)…", "First boot takes a minute…") — no modal overlay, no
   console. Ends by booting straight into the embedded screen: the reward for
   setting up a phone is *holding it*.
4. **Failure has a face**: if a step fails, the card says what and offers
   retry — never a silent return to an empty grid.

## Phase 5 — The phone feels real (independent tracks, any order)

1. **Chinese input (flagship).** The keyDown monitor swallows keys before
   macOS IME composes — 注音 never engages; the phone can't be typed at in
   Chinese. Needs investigation: candidates are making the panel key-able for
   text sessions, or an invisible NSTextInputClient proxy that lets IME
   compose and forwards committed strings via `sendText`. Spec: composing
   Chinese in LINE works; escape/arrow keys still reach Android.
2. **Real app icons.** Pull each launcher app's icon from its APK (extract on
   install/refresh, cache by package+version); letter tile stays as fallback.
3. **Launcher filter.** Grid shows only apps with a launcher intent —
   Contactkeys/Safetycore-class plumbing never appears.
4. **Pinch to zoom.** Trackpad magnify → two synthetic fingers about the
   cursor (the scroll-finger machinery generalised to two pointers).
5. **Volume.** Island bloom gains volume up/down (Android VOLUME keycodes).
6. **Secure screens get a face.** FLAG_SECURE blanks the stream (platform
   floor). Detect (poll current window flags) and overlay a quiet card: "This
   screen is protected (password/payment). Type blind, or use the phone
   window." — instead of dead black.
7. **Pop-out without losing your place.** Today's toggle cold-reboots (~1min,
   session lost). Investigate emulator snapshot save → relaunch windowed from
   snapshot (seconds, same session). If snapshots prove unreliable, at least
   warn before rebooting.
8. **Clipboard comes back.** Phone→Mac copy sync (scrcpy control channel
   supports clipboard events both ways).

## Settings, rewritten by the above

- System Status hides when healthy; a broken row surfaces with a fix action
  (invisible elegance — the checkmarks were chrome).
- Storage speaks human ("Phones · 8.2 GB"), no `~/.android` paths.
- The Recent Activity console leaves Settings. Errors surface where they
  happen (Phase 4.4); a diagnostics log stays reachable for bug reports via
  option-click on the version row — instrumented for humans, hidden from them.
- Remaining rows: window position toggle, embedded/windowed default, uninstall
  row (Phase 1.4), version.

## Notes

- Phases 1–2 are mechanical and land together fine. Phase 3 before Phase 4 so
  the hello card is built once, on the final shell.
- 5.1 (IME) and 5.7 (snapshots) start with an investigation spike each; don't
  promise until proven.
- Nothing here touches the touch-first island spec — the two compose.
