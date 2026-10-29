# Compatibility policy for 1.0.0

Deskriptions 1.0.0 supports macOS 15 or later and its bundled Manifest V3 adapter for Google Chrome, Brave Browser, and Microsoft Edge. The adapter requires a browser version that supports Manifest V3, native messaging, and the `favicon` permission. Only environments recorded in release verification reports are claimed as exercised; compatible versions are not automatically claimed as fully verified.

Four versions are independent:

- App/extension release version: `1.0.0`.
- Adapter protocol: v1 only. A different protocol version is rejected with `incompatible_protocol`; commands are not executed.
- Adapter-owned saved state: v1 only. A saved Desktop retains the adapter state version so a future adapter can migrate or reject its own data.
- Saved Desktop format: v1 only. Unknown versions and corrupt files are skipped and reported without overwriting or deleting the original.

API v1 remains provisional. Patch releases may add optional fields and capabilities. Receivers must ignore unknown capabilities and optional fields. They must reject an unsupported required protocol or state version before a destructive command. No downgrade compatibility is claimed.

Updating the app does not alter `~/Library/Application Support/Deskriptions/`. Reinstalling the bridge atomically replaces the one user-level native-host manifest. Updating the unpacked extension in place retains its `chrome.storage.local` installation identity; removing and loading it as a new extension can create a new identity and requires profile association again.

## Signing and local updates

macOS privacy grants are associated with an application's code identity, not only its bundle identifier or Team ID. The notarized public app is signed with **Developer ID Application** for team `9ZGCDZ7YNN`. An Apple Development or ad-hoc build has a different designated requirement, so installing it over the public app can cause Accessibility, Automation, and Screen Recording to request approval again.

- `scripts/build-app.sh` and the default `scripts/build-release.sh` create quick Apple Development-signed test builds. Run them from `.build`; do not install them over the trusted public app.
- `scripts/build-distribution.sh` creates a Developer ID-signed, timestamped package without contacting Apple's notarization service. This is the correct local update identity when permission continuity must be tested.
- `scripts/install-trusted-update.sh` refuses ad-hoc or Apple Development candidates, verifies the bundle ID, Team ID, Hardened Runtime, embedded signatures, and exact designated-requirement match, then preserves the prior `/Applications` app as a versioned backup.
- `scripts/notarize-release.sh` is the explicit public-distribution workflow. It builds with Developer ID, submits using the Keychain notary profile, waits for acceptance, staples, validates, and runs Gatekeeper assessment. It must not be used for ordinary development builds.

Signing continuity improves permission stability but cannot guarantee it: moving between different designated requirements, changing entitlements, TCC policy changes, or installing/running a different copy of the app can still require approval. Always grant permissions to the exact `/Applications/Deskriptions.app` copy intended for regular use.

There is no saved-data migration in 1.0.0 because format v1 remains the only supported format. Format-v1 records created before Finder, Preview, Notes, and application-only fields were introduced decode those fields as empty. A future format migration must write a new record, retain the recoverable original, validate the result, and only then offer cleanup.
