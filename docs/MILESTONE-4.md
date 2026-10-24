# Milestone 4 report — 2026-10-23

Environment: macOS 26.6.2 (25G83), Apple Silicon; Xcode 26.6 (17F113), Swift 6.3.3; Google Chrome 155.0.8059.85.

## Readiness decision

**Ready for personal testing. Not ready for external beta or public release.**

The release candidate builds reproducibly, launches after being moved outside the development directory, embeds its bridge, installs that bridge into an isolated home, preserves the existing v1 Desktop store, restores disposable Chrome content, and has redacted diagnostics. It is not notarized, has no owner-approved open-source license, and still lacks human verification for cold Chrome launch, two disposable profiles, VoiceOver, preview/fullscreen/Space behavior, and the full interruption matrix.

## Test matrix

| Area | Result | Evidence or limitation |
|---|---|---|
| Release build and checksums | Verified working | Production Swift build, app and bridge ad-hoc signature verification, three archives, and SHA-256 verification succeeded. |
| Launch after moving app | Verified working | `Deskriptions.app` was copied to `/tmp/Deskriptions-RC.app` and launched from there. |
| Bridge path outside source tree | Verified working | Bridge is under `Contents/Resources`; isolated-home install generated one exact-origin manifest pointing to the moved app. Reinstallation is an atomic replacement. |
| Missing/incomplete installation | Verified by controlled test | Installer rejects a missing app/bridge with the expected path and recovery instruction. Runtime disconnected state remains non-destructive. |
| Save/load with Chrome running | Verified working in Milestone 2 | Three grouped disposable windows/five tabs restored; pin, order, active tab, bounds, and deliberate-new-load behavior were observed. |
| Retry without duplicates | Verified working in Milestone 2 | Reusing `m2-desktop-load-1` returned prior browser identifiers and created no additional content. |
| Stale selection | Verified working in Milestone 2 | Moving a selected tab before closure returned stale/partial and did not close the moved content. |
| Two profile locators | Fixed; not integration-verified | Save now provides a separate complete Profile Path field for each connected profile. |
| Chrome initially closed | Not yet verified | Full locator storage/launch exists, but the retained real record predates the user-data-root field. |
| Space creation/removal | Limited | No safely verifiable public implementation. Explicit current-desktop fallback is verified; no automatic removal occurs. |
| Live preview | Not yet verified this milestone | Source builds; Screen Recording permission and human Space/fullscreen observation are still required. |
| Interruption/cancellation matrix | Partially verified | Durable attempts, corrupt/future isolation, stale identity, timeout, protocol rejection, and reconciliation are covered. Chrome/app exits at every stage and partial user cancellation remain manual tests. |
| Update/compatibility | Working with limitations | v1 files/settings remain in user Application Support; protocol 0 and 2 are rejected by the packaged host. Extension update in place and clean-account update are unverified. |
| Keyboard/accessibility/appearance | Not yet verified | Default/Escape actions and keyboard shortcuts exist. VoiceOver, larger text, keyboard traversal, and dark/light appearance need a human pass. |
| Diagnostic export | Verified by regression test | Export includes aggregate counts/versions/statuses and excludes a fixture URL, Desktop name, installation ID, and session ID. |

## Fixes made

- Embedded the production native host in the app instead of registering a `.build/debug` executable.
- Added a repeatable release builder, isolated user-level bridge installer, uninstall helper, complete beta kit, and checksums.
- Fixed the Save UI to capture a distinct full Chrome Profile Path for each profile rather than incorrectly applying one locator to every profile.
- Added a user-initiated, preview-described diagnostic export containing no private browsing content by default.
- Added normal activation for command-line UI verification while retaining accessory behavior for ordinary menu-bar launch.
- Renamed/versioned the Chrome adapter for the 0.4.0 candidate and added explicit compatibility, tester, recovery, uninstall, release-note, known-issue, and publication documents.
- Added regression coverage for diagnostic privacy and packaged-host tests for older/current/newer protocol behavior.

## Automated results

- 13 Swift tests: 0 failures in 0.026 seconds (last full run).
- Native messaging framing: passed against the bridge embedded in the release app.
- Protocol compatibility: v1 accepted; v0 and v2 rejected with `incompatible_protocol` and supported version `[1]`.
- Extension JavaScript syntax and JSON manifest parsing: passed.
- `codesign --verify --deep --strict`: passed for the ad-hoc signed app. This is not Developer ID signing or notarization.
- All three recorded SHA-256 checksums verified.

## Resource measurements

Measurements used `ps` at two-second intervals for ten seconds on the environment above. The moved, idle release app held 41.4–43.8 MiB resident memory and reported 0.0% CPU in every sample. Four development native-host processes associated with two observed Chrome extension connections held 6.1–10.6 MiB each and reported 0.0–0.1% CPU. The seven-window disposable inventory was connected during sampling.

These numbers are observations, not platform-wide targets. Preview static/dynamic load, replacement leak testing, repeated save/load growth, and a substantially larger inventory were not measured because preview permission/human interaction and additional destructive disposable cycles were unavailable. Acceptance for the next pass: idle CPU should return to effectively 0%, app resident memory should not grow monotonically after ten preview replacement/dismiss cycles, and bridge process count should converge to one per live extension connection.

## Release artifact inspection

The app reports version 0.4.0/build 4 and bundle ID `org.deskriptions.app`. The extension reports 0.4.0. Binary string inspection found no developer home-directory or disposable-profile path in the two app executables. The staged extension contains only its manifest and service worker. No profiles, saved Desktop records, operation journals, credentials, or private URL fixtures are bundled.

The release is ad-hoc signed only. Signing/notarization credentials were not available or authorized, so notarization was not attempted or claimed.

## Human actions blocking a broader readiness level

1. Choose and authorize an open-source license.
2. Supply/authorize Apple Developer ID signing and notarization for public distribution.
3. Run the manual clean-account, cold-profile, two-disposable-profile, accessibility, appearance, and preview/fullscreen/Space matrix.
4. Repeat the interruption tests with disposable content and record outcomes.

No external repository, tester contact, upload, Web Store submission, or publication occurred.
