# Touch-first island — spec

> Locked and **shipped** 2026-07-15 (commit 2254b88); hand-verified by the
> maintainer — dwell-to-bloom and touch-everywhere both feel right. The
> island's morph IS the mode switch. Do not add chrome (no toggle button, no
> border tell, no second bar, no pushing the phone down). Supersedes the
> touch-mode toggle from 0dd0f4c.
>
> If you revisit: the ~150ms dwell (`ChipHostView.dwellDelay`) is the one feel
> knob; it landed right on the first try, so change it only on a real complaint.

## The one idea

The island already has two forms. Each form owns one input world:

- **Idle notch = the phone's.** The island is purely visual — it never touches
  the mouse. Every press on the window, top edge and dead center included, is
  a finger on the phone (reaches `InteractionView`). Touch is the default;
  there is no mode to enter.
- **Bloomed bar = the Mac's.** Dwell the cursor on the notch (~150ms, no
  button down) and the island blooms into the black status bar — now it is
  window chrome: drag anywhere on it to move the window, buttons and traffic
  lights clickable. Cursor leaves the strip → collapses back to the phone.

Fast pull-through (crossing the notch in under the dwell) never blooms — a
quick press-drag from the very top pulls the notification shade. The bloom
animation is the affordance: when you see it grow, it is telling you "now I'm
the handle".

## Behaviour spec

1. Phone screen, island idle: chip host hit-tests to **nil** — everything
   passes through to the touch layer. No window drag from the island.
2. Dwell-to-bloom: cursor inside the notch rect (90×26, top pad 18, centered;
   ±4pt slop) for `DWELL ≈ 150ms` with `NSEvent.pressedMouseButtons == 0` →
   expand (existing spring). While expanded, chip host hit-tests normally.
3. Collapse: cursor leaves the 64pt strip (mouseExited / mouseMoved outside)
   → collapse. AppKit doesn't deliver enter/exit during drags, so a window
   drag in progress never collapses mid-drag.
4. Home screen: unchanged — `alwaysExpanded` bar, drags the window as today.
5. **⌘-drag anywhere on the streamed screen moves the window** — hidden power
   path, no UI. `InteractionView.mouseDown`: if `.command` held →
   `window?.performDrag(with: event)`, skip touch tracking.

## Removals (dissolve touch mode entirely)

- `AppModel.touchMode`, the `hand.tap` toggle button, the green border tell,
  the island's forced-expanded touch state — all deleted.

## Implementation notes

- Subclass the chip host: `ChipHostView: NSHostingView<ChipBarView>`,
  override `hitTest(_:)` → nil when `activeApp == .screen && !islandExpanded`,
  else `super`.
- Hover cannot ride SwiftUI `.onHover` (it respects hit-testing, which idle
  turns off). Use an `NSTrackingArea` on `ChipHostView` (`.mouseMoved`,
  `.mouseEnteredAndExited`, `.activeAlways`, `.inVisibleRect`) — tracking
  areas are geometry-based and ignore hitTest. Drive a new
  `AppModel.islandExpanded` `@Published` from a dwell `DispatchWorkItem`.
- `Island` drops `@State hovering` + `.onHover`; `expanded = alwaysExpanded
  || model.islandExpanded`. The idle notch loses its `windowDrag` gesture
  (pure visual — unreachable anyway once hitTest passes through).
- Verify `NSHostingView.isFlipped` at runtime when computing the notch rect;
  compute defensively from the top edge.

## Accepted trade-offs (maintainer-approved)

- Island buttons cost ~150ms dwell before the bar blooms (was instant).
- If the bar is already bloomed, a press at top-center drags the window —
  visible and self-explaining; move away to collapse and pull again.
