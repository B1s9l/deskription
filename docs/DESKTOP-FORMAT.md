# Saved Desktop format v1

Each Desktop is one UTF-8 JSON file named by UUID in `~/Library/Application Support/Deskriptions/Desktops/`. Writes use a temporary file and same-directory move. Existing identifiers are not overwritten implicitly. Corrupt and future-version files are skipped and surfaced without modification.

Top-level fields are `formatVersion` (currently 1), `id`, `name`, `createdAt`, `modifiedAt`, `profiles`, `finderFolders`, `previewDocuments`, `notes`, `applications`, and user-visible `limitations`. A profile stores verified browser application bundle ID, browser-scoped extension installation identity, adapter state version, optional confirmed user-data directory and profile directory, and ordered windows. New records set `browserIdentityVerified`; older records decode as unverified and require guided reassociation before restoration. A window stores its UUID, source session identifiers for revalidation, bounds/state, and ordered tabs.

Each Finder folder record stores its own UUID, `com.apple.finder` application identity, the source Finder window ID used for save-time revalidation, the exact POSIX folder path reported by Finder, and its bounds. Older format-v1 records without `finderFolders`, and early Finder records without `applicationBundleID`, decode to an empty list and `com.apple.finder` respectively.

Each application-only record stores a stable bundle identifier, display name, and last-known bundle path. Loading resolves the bundle identifier first and uses the saved path only as a local fallback. These records promise application launch or activation only, never restoration of previous window contents. Older format-v1 records without `applications` decode to an empty list.

Generic document records store an exact standardized file path, display name, original application bundle identifier and optional verified application bundle path, plus non-sensitive discovery metadata. Preview and PowerPoint prefer the public Accessibility `AXDocument` attribute; PowerPoint can additionally enumerate multiple saved presentations through its public Automation `full name`/`path` properties. Restoration always targets the recorded application rather than the file type's default handler. Existing `previewDocuments` records remain supported and are converted to the shared in-memory representation when loaded. Notes records store only the selected note's stable scripting identifier and display name; note bodies are never saved. Older format-v1 records without `documents`, `previewDocuments`, or `notes` decode those lists as empty.

Repeated windows and tabs remain distinct array records; identical URLs/titles are never coalesced. Runtime IDs are not durable identities. URLs remain local in the saved file and native-message spool; normal logs omit them.

Load attempts live separately under `Operations/` and store `attemptID`, `desktopID`, `operationID`, status, restored window IDs, and diagnostics. This separates retrying an interrupted operation from deliberately loading another copy.

