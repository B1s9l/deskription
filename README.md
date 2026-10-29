# Deskriptions

Deskriptions is a free, open-source macOS menu-bar application for keeping useful windows close at hand and returning to a group of work later.

Its two main features are:

- **Live window previews:** Pin a movable, resizable, always-on-top preview of another application's window. A preview can remain visible while you work in another macOS desktop or a fullscreen app—for example, to watch a build, reference a document, or keep a dashboard in view.
- **Saved Desktops:** Save a collection of supported applications and content, then reopen it later. A Desktop can include Chromium browser windows and tabs, Finder folders, Preview documents, selected Apple Notes, and application-only entries. This is useful when switching projects or resuming a task without reconstructing the same working set by hand.

Deskriptions restores only what each supported integration can identify safely. It does not promise to reproduce every application's internal state, unsaved work, or macOS Space placement. All data stays local, and there are no accounts, cloud services, or telemetry.

Copyright © 2026 [B1s9l](https://github.com/B1s9l). Deskriptions is licensed under [GNU GPL version 3 only](LICENSE) (`GPL-3.0-only`). See [Third-party notices](THIRD-PARTY-NOTICES.md) for platform and asset attribution.

## Components

- `Deskriptions`: menu-bar app with Save Desktop, Desktops, privacy-conscious diagnostics, and ScreenCaptureKit previews.
- `deskriptions-bridge`: browser-specific native-messaging host; validates protocol and browser identity and journals messages per browser/profile.
- `extension/`: unpacked Manifest V3 Chromium extension that inventories windows/tabs and performs idempotent restores.
- `deskriptions-diagnose`: prints native Chrome windows, extension observations, and explicit match status.

## Build and run

Requirements: macOS 15+, Xcode 16+, and at least one supported Chromium browser (Google Chrome, Brave Browser, or Microsoft Edge). Build the local release kit with:

```sh
./scripts/build-release.sh
```

Artifacts and SHA-256 checksums are written under `.build/release-artifacts/`. The release app embeds its native bridge; the included `install-release-bridge.sh` registers that stable embedded path after the app is moved to `/Applications`.

Every app build requires a signing certificate so macOS can retain Screen
Recording authorization across rebuilt binaries. Development builds select an
`Apple Development` certificate for team `9ZGCDZ7YNN`; public distribution
builds select `Developer ID Application` for that team. On the first build of
each mode, the signing script pins the selected certificate fingerprint in
`~/Library/Application Support/Deskriptions/signing-identity-development` or
`signing-identity-distribution` and
reuses it for every development and release build. Set
`DESKRIPTIONS_SIGNING_IDENTITY` to a certificate fingerprint to override that
selection deliberately. Builds fail instead of silently falling back to ad-hoc
signing when the required identity is unavailable. Create or download the
certificates once in Xcode under Settings > Accounts > Manage Certificates.

For development:

```sh
./scripts/build-app.sh
open '.build/Deskriptions-1.0.7-build44.app'
```

### Developer ID distribution and notarization

Local development builds and public-distribution builds are separate. A distribution build requires the repository's configured Developer ID Application identity for team `9ZGCDZ7YNN`, enables Hardened Runtime, securely timestamps every embedded bridge and the outer application, and verifies each signature:

```sh
./scripts/build-distribution.sh
```

Notarization credentials belong in the login Keychain, never in the repository or an environment file. Create the default profile interactively using an Apple-supported Apple ID or App Store Connect authentication method:

```sh
xcrun notarytool store-credentials 'Deskriptions-Notarization' --team-id 9ZGCDZ7YNN
```

After that one-time setup, build, submit, wait for acceptance, save the notarization log, staple and validate the app, run Gatekeeper assessment, and create a metadata-preserving final ZIP with:

```sh
./scripts/notarize-release.sh
```

Pass another Keychain profile name as the first argument when needed. The script stops on missing credentials, rejection, failed stapling, invalid signatures, or Gatekeeper rejection. It never stores authentication secrets in the source tree.

Grant **Screen & System Audio Recording** when macOS asks. Apple’s current sample notes that a first-time grant can require quitting and reopening the app. Settings → Diagnostics provides the functional ScreenCaptureKit checks. The default shortcuts are Save Desktop `Control-Option-S`, Load Desktop `Control-Option-L`, and Pin focused window `Control-Option-P`; they can be changed or cleared in Settings → Keyboard Shortcuts.

The global event monitor may require **Input Monitoring** on some macOS configurations. The menu command remains available without it. Accessibility is optional and used only for exact Preview-document discovery; Deskriptions does not use Mission Control automation. Finder folder support requires **Automation → Finder**: open Save Desktop once and allow the focused Deskriptions prompt. If denied, enable Finder for Deskriptions in System Settings → Privacy & Security → Automation. Notes requests its own Automation permission only when its selected-note integration is used.

Finder rows contain exact folder locations obtained from Finder, not paths guessed from window titles. Selected folders are persisted and reopened in verified Finder windows during load. Finder does not expose every tab in a window through its supported scripting interface, so Deskriptions deliberately leaves Finder windows open after saving rather than risk closing an unselected tab.

Preview and Microsoft PowerPoint use the shared exact-document restoration path. Preview discovers public `AXDocument` file URLs with Accessibility permission. PowerPoint uses its public Automation dictionary to discover saved presentations by exact full path. Each file is reopened explicitly with its original application and verified; unsaved, inaccessible, or unidentified content falls back to application-only restoration. Apple Notes has a privacy-limited built-in adapter using its supported scripting dictionary: it saves only the stable identifier and name of the currently selected note and reopens that exact note without reading its body. Notes remains open after saving because selective closure cannot be verified safely.

Live previews use ScreenCaptureKit with bounded automatic recovery for stream interruptions, display changes, and unambiguous window recreation during fullscreen transitions. Capture recovery cannot force browsers or other source applications to generate new video frames when they deliberately throttle background rendering; protected content can remain blank.

Ordinary foreground applications without a dedicated adapter appear once per application in Save Desktop. Loading launches or activates that application and verifies that it is running; it does not restore the application’s previous windows or internal content. These application-only entries remain open after saving. Chrome and Finder use their dedicated content-aware integrations instead and are not duplicated in this fallback list.

Application-only restoration reuses an already-running application and brings
it to the foreground. When launch is required, Deskriptions validates the saved
bundle identity, launches with activation, and waits for the matching application
to be observed as running and active. Generic applications remain
open after saving even in “Close supported content” mode: an application-level
record cannot prove which windows are unrelated or contain unsaved work.

Settings → General can delete all saved Desktop records after two confirmations,
or retain only the newest configured number after successful saves. These
operations never alter source content, browser profiles, settings, or the
monotonic Desktop naming counter.

The Desktops window uses a scrollable list with a detail pane showing included applications and supported content. Load progress and results use a coalescing, non-activating in-app banner instead of Notification Center: the banner dismisses automatically and creates no system notification history. Detailed outcomes remain available under **Settings → Diagnostics → Recent Status…**.

### Chromium extension and bridges

1. Open `chrome://extensions`, `brave://extensions`, or `edge://extensions`, enable Developer mode, choose **Load unpacked**, and select `extension/`. Its fixed development ID is `agimibdhlfgliioagkdaefkddfenhmfe`.
2. Install the native-host manifest:

   ```sh
   ./scripts/install-native-host.sh agimibdhlfgliioagkdaefkddfenhmfe
   ```

3. Reload the extension and click its toolbar action. In the browser’s version page, copy the complete **Profile Path** (for example, `/Users/me/Library/Application Support/Google/Chrome/Profile 1`) into Settings → Extensions. Deskriptions stores the user-data directory and profile-directory components separately so it can launch and validate the intended profile. A profile display name or extension installation identifier alone is not a launch locator.
4. Inspect combined observations:

   ```sh
   swift run --disable-sandbox deskriptions-diagnose
   ```

If an association says `ambiguous`, visually identify the pair and record it explicitly; automatic closing must remain disabled until this is done:

```sh
swift run --disable-sandbox deskriptions-diagnose --associate EXTENSION_WINDOW_ID:NATIVE_WINDOW_ID
```

Run a disposable restore (exactly one connected profile is required so the profile choice is never guessed):

```sh
node scripts/lifecycle-lab.js
```

It queues two `example.com` test pages, waits at most 20 seconds, and uses a durable `operationID` so retrying the same ID returns the prior result instead of creating another window:

```sh
node scripts/lifecycle-lab.js lab-fixed-id
node scripts/lifecycle-lab.js lab-fixed-id
```

Saved Desktops are under `~/Library/Application Support/Deskriptions/Desktops/`; load attempts are under `Operations/`. The private local bridge spool is under `$TMPDIR/deskriptions-lab/`. URLs are not written to normal logs.

### Restore destination

Deskriptions restores into the current macOS desktop. It never creates, switches, or removes macOS Spaces. Public APIs do not expose a stable Space identifier, so the app reports that placement cannot be independently verified instead of claiming it succeeded.

## Tests

```sh
mkdir -p .build/cache .build/home
HOME="$PWD/.build/home" CLANG_MODULE_CACHE_PATH="$PWD/.build/cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/cache" swift test --disable-sandbox
```

The tests cover persistence, corrupt/incompatible data, duplicate preservation, naming counters, retention, redacted diagnostics, selection, matching, protocol coding, and retry identity. `node scripts/test-native-host.js` also checks native-message framing and rejects both older and newer unsupported protocols. See `docs/TESTER-GUIDE.md`, `docs/API.md`, `docs/DESKTOP-FORMAT.md`, and `docs/COMPATIBILITY.md`.

