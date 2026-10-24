# Milestone 1 report — 2026-10-23

Environment: macOS 26.6.2 (25G83), Apple Silicon; Xcode 26.6 (17F113), Swift 6.3.3; Google Chrome 155.0.8059.85. Repository automated test run: 4 tests, 0 failures.

Status terms below distinguish observed behavior from compilation and documentation evidence.

## A. Live window preview — Not yet verified

Implemented a ScreenCaptureKit `desktopIndependentWindow` stream into a nonactivating, floating, movable/resizable `NSPanel`. The panel uses `canJoinAllSpaces` and `fullScreenAuxiliary`; selection requests shareable content with `onScreenWindowsOnly: false`; dismissal stops the stream and releases UI resources. Prototype shortcut: Control-Option-P.

Actual run reached macOS Screen & System Audio Recording settings. The initial raw executable lacked a permission identity; a signed `.app` with bundle ID `org.deskriptions.lab` was added. Permission was not toggled because that is a user-controlled security setting. Consequently inactive-Space frames, fullscreen overlay, movement/resizing, and clean shutdown remain manually unverified—not claimed from compilation.

Expected limitations requiring measurement: minimized or app-suspended windows may freeze or produce placeholder/empty frames; DRM/protected content may be black; apps may reduce background rendering. ScreenCaptureKit reports capture availability, not a promise that an app continues producing meaningful pixels.

## B. Inventory and browser matching — Working with limitations

Verified by automated tests: unique geometry produces one association; no candidate remains unresolved; identical geometry stays ambiguous; completed/in-flight operation IDs deduplicate. The native executable also compiled successfully.

Not yet verified against the requested real Chrome matrix because installing an unpacked extension and granting native messaging require user interaction. The runnable diagnostic preserves duplicate titles/URLs as separate records, uses unique geometry only when unambiguous, exposes unresolved/ambiguous results, and provides explicit user association as fallback. It never assumes Chrome and Core Graphics window IDs match.

Current-desktop finding: `kCGWindowIsOnscreen`/`optionOnScreenOnly` can report current visibility. No used public API provides a stable macOS Space identifier or reliable complete per-Space membership. Off-Space windows can be enumerated with `.optionAll`/ScreenCaptureKit, but membership must not be inferred merely from absence onscreen.

Manual matrix: create only disposable Chrome windows, then run `deskriptions-diagnose` after (1) two macOS Spaces, (2) multiple same-Space windows, (3) identical test URLs/titles, (4) each disposable profile, and after move/resize/close/reopen and extension reload. Save JSON outputs as evidence. Existing personal windows must not be changed.

## C. Mission Control automation — Blocked

There is no public API used here to create/remove macOS Spaces. The isolated AppleScript uses Accessibility UI automation, creates a disposable TextEdit window, and fails explicitly if the Mission Control add control or AX-visible destination window cannot be found. It does not modify preferences or use private frameworks.

This is blocked on Accessibility permission and human visual verification of the Space indicator. AX visibility of the disposable window is necessary but not sufficient proof that the intended Space was reached. Automated removal is intentionally absent until identity/emptiness can be verified; the prototype must never risk removing a nonempty or last Space. The product fallback copy is: “A new desktop couldn’t be created. Restore this Desktop in your current desktop?” with Cancel and Restore here.

## D. Browser lifecycle — Not yet verified

Implemented: persisted logical profile identity, per-connection session identity, bounded 20-second caller timeout, reconnect backoff, new-window-only disposable restore, completion acknowledgement, and operation-ID deduplication. The CLI refuses to guess when multiple profiles are connected. Automated ledger retry behavior passed.

Real scenarios (Chrome closed/running, extension disabled, interrupted bridge, retry) require the unpacked extension/native host setup and were not performed. Note that macOS launching Chrome is separate from selecting a profile: the extension cannot reveal a trustworthy profile-directory launch locator. The main app must retain a user-confirmed locator and validate the reconnecting `installationID` before issuing restore.

## Primary documentation findings

Apple documents ScreenCaptureKit shareable content and desktop-independent window filters, and documents `canJoinAllSpaces`/`fullScreenAuxiliary` as window collection behaviors. Chrome documents that window IDs are session-unique, native messaging is extension-to-host with framed JSON, and native hosts must allow the exact extension origin. These support the architecture but not the unverified runtime claims above.

## Recommendation for Milestone 2

Proceed with the capture panel and versioned adapter boundary, but do not promise universal live content, exact Space membership, or reliable automatic Space creation/removal. Make Space creation best-effort with the specified current-desktop fallback. Add a user-confirmed browser-profile launch locator during onboarding. Treat ambiguous browser/native joins as a blocking state for closing. Before product UI work, complete the manual test matrix on at least two macOS releases and record screen/video plus structured diagnostic output.
