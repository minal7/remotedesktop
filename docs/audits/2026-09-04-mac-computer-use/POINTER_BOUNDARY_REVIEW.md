# Separate pointer intent from coordinate clamping

Source repair; compilation and native gestures remain unverified. This follows the [capture/video placement repair](CAPTURE_CONTENT_PLACEMENT_REVIEW.md) and preserves the existing [input-source ownership](INPUT_SOURCE_OWNERSHIP_REVIEW.md). No build, typecheck, test/assertion execution, app/device/browser operation, native capture, model run or SSH retry was performed.

## Findings and resulting behavior

[RemoteScreenUIView](../../../ios/RemoteDesktop/Session/RemoteScreenView.swift) previously clamped every pointer position onto the advertised display. A click in a letterbox margin could therefore press a desktop control at the nearest edge. A press that started outside could become a down event when its later movement entered the content. The view also converted scroll deltas to integers without checking finite/ranged representation, retained an invented initial pointer position at zero, and handled failed scroll recognizers incompletely. Move-screen mode explicitly ended only touch scrolling.

`RemoteScreenInputRouting` now separates new button presses, held movement and release. A new absolute press needs a point inside both the content rectangle and the viewport. Hover/moved events cannot introduce buttons; an ignored outside begin cannot turn into a press on reentry. An existing drag can move to the visible boundary, but cannot add a button there. Releasing some or all held buttons outside, including with missing/nonfinite coordinates or unavailable geometry, uses the last admitted position and introduces no movement. Deduplication retains only the last admitted pointer message.

The visible rectangle is the intersection of the logical display rectangle and the viewport converted into the content view's current coordinates. This accounts for zoom/pan clipping: being inside the full desktop image is insufficient when that part is outside the viewport. Clamped held movement stays just inside the visible maximum edges before coordinate conversion.

This does not make finger input absolute. The existing finger interface is a relative trackpad with a floating cursor. New taps and long presses act at that visible cursor. [TouchCursorLayer](../../../ios/RemoteDesktop/Session/TouchCursor.swift) now distinguishes an unpositioned cursor from a positioned origin, stays strictly inside visible maximum edges, and rejects invalid rectangles/motion. The view centers a previously unpositioned/offscreen cursor within the visible content and clamps it after layout or zoom changes. Fingers may operate the relative trackpad from margins; that is distinct from turning an absolute mouse press in a margin into a desktop click.

## Scroll and lifecycle ownership

One scroll owner is retained at a time, identified as touch or indirect input. Only a valid inside begin establishes it. A different source cannot take over or end that gesture, and changed/momentum messages without an owned begin are ignored. Missing/nonfinite/oversized deltas or movement outside visible content ends the owned scroll once, with zero deltas at its last admitted point. Reentry requires a fresh begin. End/cancel/failed cleanup does not depend on receiving a valid final point or delta.

Scroll values are rounded as before, then converted with the exact signed-32-bit initializer. The code no longer performs a trapping unrestricted `Int` conversion. Subpixel changed events remain suppressed. An end is always zero-delta cleanup; residual movement is not added during termination.

Indirect scrolling requires an observed pointer location. The view retains that location in view coordinates and projects it through the current zoom when needed. It does not invent `(0, 0)` before hover/button evidence. A first indirect scroll without that position is ignored. Native pointer/recognizer ordering must still establish when the expected position becomes available.

Failed recognizers now follow the end path. Switching to move-screen mode ends whichever scroll source is actually owned before clearing recognizer generations. Indirect hover/button/scroll input first cancels an existing finger touch and ends its touch-scroll owner, then removes its recognizer generation; later finger callbacks cannot finish the indirect successor. Source retirement clears the routing state and pending touch/button/scroll fields before calling the existing SessionModel cleanup. A changed display publication also retires the old view source before rebinding. A view whose source was replaced cannot retain it merely because the broader input generation stayed the same.

[SessionModel](../../../ios/RemoteDesktop/SessionModel.swift) remains responsible for transport cleanup and exact source-lease checks. This repair does not give the pure routing state independent authority to send after retirement. Actual transport callbacks, reentrant UIKit behavior and lifecycle ordering remain unexecuted.

## Coordinate representation

`RemoteScreenGeometry` now rejects missing/invalid display dimensions, unsupported density, nonfinite/empty bounds and nonfinite points. Mapping returns an optional result rather than fabricating coordinates when display information is unavailable. Clamping is an explicit option used only after intent admission or by dedicated geometry fixtures.

The normalized surface spans all `w` and `h` logical cells; coordinates use `floor(normalized * dimension)` and are bounded to the last cell. The old `dimension - 1` multiplier shifted the cell boundaries across the displayed rectangle. [Protocol documentation](../../../protocol/PROTOCOL.md#pointer-client--host) records the mapping and boundary behavior. This still uses integer logical coordinates: subpoint precision and native hit testing are not proved by the arithmetic.

## Prepared regression evidence

Nine methods are authored and **unrun** in [RemoteScreenInteractionTests](../../../ios/RemoteDesktopTests/RemoteScreenInteractionTests.swift). They cover margin presses/movement, owned drag clipping and outside releases, routing-state reset, scroll ownership, boundary/invalid-delta termination, missing initial position, full-cell mapping and invalid geometry, zoom clipping, and cursor edge/invalid-motion behavior. Three existing mapping methods now explicitly unwrap optional mapping and request clamping where the fixture intentionally tests it.

The fixtures exercise pure geometry/routing and a cursor CALayer. They do not instantiate the Metal renderer, synthesize native UITouch/recognizer callbacks, post desktop events or run the application. The state-reset case models value retirement and explicitly leaves real source cleanup to the existing SessionModel contract; it is not an end-to-end source-lifecycle test.

The [boundary client inventory](pointer-boundary-client-inventory.json) retains all 36 placement/capture-input cases, adds the nine named cases and explicitly selects four existing geometry/cursor cases. Client-core expectations extend the committed 39 identifiers with the same nine new methods. Host source is unchanged.

Three changed Swift files pass parse-only checks. Static inventories select **48 client-core / 49 boundary-client** methods; host inventories remain **1981 default / 1298 focused browser-host**. Documentation validation checks **232 Markdown files / 1953 local targets / zero broken paths**. Whitespace validation is clean. The effective `.git/hooks` directory was inspected and contains **zero executable non-sample hooks**. These checks are not compilation, runtime XCTest discovery, passing assertions or native behavior evidence.

## Remaining qualification and repair

1. **Bind input to actual current presentation.** Layout/viewport arithmetic does not prove the exact frame drawn by the owning renderer. Preserve the [remaining codec, renderer and freshness work](CAPTURE_CONTENT_PLACEMENT_REVIEW.md#remaining-repair-and-qualification-sequence), including queued frames/layouts and phone foreground return.
2. **Qualify native gesture delivery after permission.** Exercise mouse/trackpad/Pencil, relative touch, button chords, margins, clipping, rotation, zoom/pan, simultaneous gestures, failed/cancelled recognizers and initial scroll without prior hover. Check that ignored outside presses never become downs on reentry and that every actual hold/scroll terminates exactly once. Evaluate source replacement while UIKit callbacks or layout are in progress.
3. **Validate coordinate limits with native hit testing.** Check all edges and small controls on primary/fallback and scaled/rotated displays. Integer logical cells, viewport transforms and release locations need native evidence; decide whether a later protocol needs subpoint precision. Boundary cleanup cannot retract input already posted to macOS.
4. **Finish fresh-image, account handoff and real task qualification.** Retain the exact paused login task until explicit Resume and fresh native account/page verification. Run the app's travel/concert/movie goals only after explicit permission. Model quality, the RTX3080 option and 8 GB/thermal qualification remain later measured work.
