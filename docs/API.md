# Provisional adapter API v1

This is the first working API, but remains provisional until the real two-profile and reconnection matrix passes.

## Authorization and transport

Chrome, Brave, or Edge starts its browser-specific `deskriptions-bridge-*` through native messaging. Separate manifest directories and host executable names establish the browser bundle identity; the bridge overwrites the extension's untrusted browser claim before journaling. Its manifest allow-lists only `chrome-extension://agimibdhlfgliioagkdaefkddfenhmfe/`. There is no TCP/HTTP listener.

The host creates a mode-0700 spool under `$TMPDIR/deskriptions-lab`. The app writes a command for a connected installation; the host returns it over the authorized native port and atomically journals the correlated result. Distribution should replace this prototype spool with app-group/XPC IPC and code-signing validation.

## Envelope and identity

Messages contain `type`, `protocolVersion`, and caller UUID `requestID`. State also contains `savedStateVersion`, browser-scoped `installationID`, `sessionID`, verified `browser`, `browserIdentitySource`, `capabilities`, and `windows`.

- `installationID`: adapter UUID persisted in `chrome.storage.local`; logical profile/extension installation identity.
- `sessionID`: connection epoch; changes after adapter restart and revalidates destructive operations.
- Chrome window/tab IDs: browser-session identifiers only.
- `nativeWindowID`: Core Graphics identifier; never equated with a Chrome window ID.
- launch profile directory: separately confirmed from `chrome://version`. Installation identity, extension ID, and display name are not launch locators.

## Registration and capabilities

Inventory on connection registers identity and advertises `inventory.windows`, `inventory.tabs`, `inventory.fresh`, `close.selected.v1`, `restore.reconciled.v1`, `restore.startup-window.v1`, and `cancel.v1`. Unknown capabilities are ignored. Protocol mismatch returns `incompatible_protocol`; adapter state migration uses `savedStateVersion`.

Compatibility is determined by the numeric adapter protocol, verified native-host browser identity, supported browser bundle ID, and required `inventory.windows`, `inventory.tabs`, and `inventory.fresh` capabilities. `adapterVersion` is the independently versioned extension release and is diagnostic only: for example, extension release 1.0.0 remains compatible with app release 1.0.5 when both speak protocol v1 and provide the required capabilities. Optional capability absence disables only its related enhancement.

## Inventory and association

`freshInventory` returns ordered tabs with URL, title, active/pinned state and window bounds/state. Save requests freshness again at commit and aborts if selected identities disappear or move.

Native and extension windows merge only from a unique geometry candidate or explicit user association. Zero candidates are `unresolved`; multiple are `ambiguous`; title/URL never silently breaks a tie. Whole-window closure requires verified native association. Selecting every tab in an unverified window returns `unverified_window_identity` without closing it.

## Commands

`closeSelected` includes `operationID` and targets with window ID, expected connection session, full expected tab set, selected tabs, and native-verification flag. The adapter re-reads Chrome immediately before closure. Per-target results distinguish closed window, closed tabs, stale, skipped, and failed.

`restoreDesktop` includes attempt/operation IDs and ordered windows/tabs. For a cold launch, the app opens an exact operation-marker tab. The adapter may reuse only the window containing that marker, creates the saved tabs, then removes only the marker tab. Session-restored and otherwise uncertain windows are preserved. With Chrome already running, the adapter creates new restoration windows. It applies bounds and pinned/active state and journals each window before cleanup.

`cancelOperation` stops before the next window-level step. Already opened content remains and is reported.

## Retry, reconnection, and errors

A deliberate load creates new attempt and operation IDs. Retry reuses the prior operation ID. Completed operations return their stored result. A running operation verifies every journaled Chrome window, adopts it, and creates only missing groups. If prior content cannot be identified, it returns `indeterminate` and opens nothing further.

Waits are bounded. Disconnect, timeout, incompatible protocol, stale identity, cancellation, partial result, and indeterminate result are distinct. Another adapter can implement the same registration, inventory, close, restore, cancellation, and result lifecycle while owning its state schema and restoration logic.
