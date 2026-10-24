# Milestone 2 report — 2026-10-23

Environment: macOS 26.6.2 (25G83), Apple Silicon; Xcode 26.6 (17F113), Swift 6.3.3; Google Chrome 155.0.8059.85.

## Verified working

- The Swift package and signed app bundle compile. Eleven automated tests pass: durable round trip, duplicate preservation, non-overwrite, corrupt/future-file isolation, tri-state selection, protocol coding, persisted incomplete attempts, operation deduplication, and unique/unresolved/ambiguous matching.
- The signed Save Desktop dialog ran against the real extension. It requested fresh state, displayed application/profile/window/tab hierarchy, partial selection controls, current-desktop uncertainty, the full profile-path locator, and unsupported native windows as disabled.
- A disposable Chrome tree was launched with `--user-data-dir=/tmp/deskriptions-m2-chrome --profile-directory=Default`. Its extension installation identity was `8a59729b-da40-44ff-921e-be3b1467bce8`. The separately observed personal Chrome profile was excluded before Save and was not closed or navigated.
- UI Save durably wrote Desktop `DE3D85B5-65E8-43FB-8ABE-39EA25AC23EF` before closure. It contains three verified native/extension windows and five tabs. The extension closed those three disposable windows; unrelated Chrome content stayed open.
- UI Load displayed the exact current-desktop fallback, restored the saved Desktop, and reported `Profile 8a59729b: complete.` A fresh inventory confirmed three window groups, five tabs, tab order, the pinned tab, active tabs, and saved bounds. The saved Desktop file remained present.
- Retrying operation `m2-desktop-load-1` returned the prior three window identifiers; a fresh inventory showed no duplicate windows or tabs from that retry. Starting a distinct load from the UI intentionally created a second copy.
- Selected-tab closure left unselected tabs open. Moving a selected tab between windows before closure produced `identity_changed`/partial rather than closing a stale identifier.
- Identical test URLs were preserved as distinct tab records. Multi-window grouping was preserved.
- The native host accepts only the fixed unpacked-extension origin and uses a mode-0700 local spool; it opens no network listener.
- Missing-extension behavior is bounded and explicit: the Save dialog has no eligible Chrome content, and a load reports the missing connection/launch mapping instead of choosing another profile.

## Working with limitations

- The first real save closed the final selected Chrome window but the service worker stopped before its acknowledgement reached the app, so the app conservatively reported a timeout. The adapter now creates a temporary adapter-owned holding popup when every normal window is selected, journals and sends the result, then removes the popup. That final-window fix is implemented and syntax-checked but has not yet had a second destructive UI save.
- Public window APIs provide current onscreen visibility, not a stable macOS Space identifier. Unique geometry associations worked in the signed app; uncertain/ambiguous records are exposed and cannot authorize whole-window closure.
- Safe creation, switching, removal, and destination verification for macOS Spaces are not available through the selected public approach. The app never silently restores elsewhere and never removes a Space; its explicit current-desktop fallback was verified.
- Profile launch requires the complete `chrome://version` Profile Path. The saved Desktop used for the running-Chrome test predates the full-path field and therefore cannot prove cold launch. The schema and UI now store both the user-data root and profile directory.
- A visible command-line integration mode now uses normal app activation so modal Save/Desktops dialogs cannot become hidden accessory-app dialogs. Ordinary menu-bar launches remain accessory-only.

## Not yet verified

- Cold Chrome launch using the newly added complete profile locator.
- Two fully disposable Chrome profiles restored in one Desktop. Connection identities for two profiles were observed and kept separate, but the non-disposable profile was deliberately not modified.
- Cross-macOS-Space selection, desktop movement, connection loss at every individual phase, cancellation after partial creation, and browser before-unload prompts.
- Final-window acknowledgement after the holding-popup fix.
- Existing live preview behavior on this run because Screen Recording permission was not enabled; the Milestone 1 source remains in the app and builds.

## Evidence and reproduction

Environment: macOS 26.6.2 (25G83), Apple Silicon; Xcode 26.6 (17F113), Swift 6.3.3; Google Chrome 155.0.8059.85.

1. Load `extension/` unpacked into the disposable profile and install the native host.
2. Open disposable `example.com`, `example.org`, and `example.net` pages in multiple windows, including a pinned tab and duplicated URLs.
3. Open Save Desktop, exclude every non-disposable profile, enter the complete Profile Path, and save. Inspect the JSON under `~/Library/Application Support/Deskriptions/Desktops/` before allowing closure.
4. Open Desktops, select the saved record, choose Load selected, then choose Restore here at the explicit Space fallback.
5. Request `freshInventory` and compare window groups, URLs, order, pinning, active tabs, and bounds. Repeat the same operation identity and confirm the returned browser identifiers and inventory do not change.
6. Run the documented `swift test --disable-sandbox` command. On this environment all 11 tests passed in 0.022 seconds with zero failures.

## Known issues

- The file-spool bridge is appropriate for the local prototype but should become signed XPC/app-group IPC before distribution.
- MV3 worker shutdown can make a successfully completed action appear indeterminate. Durable operation journals and reconciliation prevent blind retries; the final-window holding-popup path still needs one real retest.
- A display name, extension installation ID, or `Default`/`Profile 1` string is not sufficient to relaunch a profile. Onboarding must capture and validate the full profile locator.

## Recommendation

Milestone 3 should begin with cold-launch and disposable two-profile automation, then replace the spool with signed XPC/app-group IPC and add dedicated profile onboarding. Do not add other adapters until cancellation, reconnect reconciliation, final-window acknowledgement, and profile launch pass end to end. Product text must not promise automatic macOS Space placement or removal.
