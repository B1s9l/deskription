# Compatibility policy for 0.11.1

Deskriptions 0.11.1 supports macOS 15 or later and its bundled Manifest V3 adapter for Google Chrome, Brave Browser, and Microsoft Edge. The adapter requires a browser version that supports Manifest V3, native messaging, and the `favicon` permission. Only environments recorded in release verification reports are claimed as exercised; compatible versions are not automatically claimed as fully verified.

Four versions are independent:

- App/extension release version: `0.11.1`.
- Adapter protocol: v1 only. A different protocol version is rejected with `incompatible_protocol`; commands are not executed.
- Adapter-owned saved state: v1 only. A saved Desktop retains the adapter state version so a future adapter can migrate or reject its own data.
- Saved Desktop format: v1 only. Unknown versions and corrupt files are skipped and reported without overwriting or deleting the original.

API v1 remains provisional. Patch releases may add optional fields and capabilities. Receivers must ignore unknown capabilities and optional fields. They must reject an unsupported required protocol or state version before a destructive command. No downgrade compatibility is claimed.

Updating the app does not alter `~/Library/Application Support/Deskriptions/`. Reinstalling the bridge atomically replaces the one user-level native-host manifest. Updating the unpacked extension in place retains its `chrome.storage.local` installation identity; removing and loading it as a new extension can create a new identity and requires profile association again.

There is no saved-data migration in 0.11.1 because format v1 remains the only supported format. Format-v1 records created before Finder, Preview, Notes, and application-only fields were introduced decode those fields as empty. A future format migration must write a new record, retain the recoverable original, validate the result, and only then offer cleanup.
