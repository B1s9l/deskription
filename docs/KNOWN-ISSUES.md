# Known issues

- Screen Recording permission is tied to the app's signing identity. Release and local build scripts now use a stable Apple Development identity when one is available. The ad-hoc fallback changes identity after each rebuild and therefore requires permission to be granted again; the build prints a warning when this fallback is used.

- Loading targets the current macOS desktop. Deskriptions never creates, switches, or removes macOS Spaces. Public APIs do not provide a stable Space identifier for independent placement verification.
- Public macOS APIs do not expose a stable Space identifier. Off-Space or ambiguous windows require explicit selection; ambiguous native/browser associations cannot authorize whole-window closure.
- Live previews require Screen & System Audio Recording permission. Deskriptions reconnects interrupted streams and reacquires an unambiguous recreated fullscreen window, but minimized, suspended, protected, or DRM content may still freeze, be blank, or become unavailable. ScreenCaptureKit cannot force a source application to render new pixels while that application throttles or suspends its own background surfaces.
- Preview exact-document support requires Accessibility and appears only for windows that expose an exact file URL. Apple Notes support saves only the currently selected note identity and uses Notes' supported scripting `show` command; it never reads note bodies. Notes windows are not selectively closed.
- The Chrome profile must be associated using the complete Profile Path from `chrome://version`. An extension identity or profile display name is not a launch locator.
- Cold launch reuses only a startup window carrying the exact operation marker. Session-restored or otherwise uncertain windows are preserved.
- The local file-spool bridge is user-private and exact-origin authorized, but API v1 remains provisional. A signed XPC/app-group transport is recommended before a broadly distributed release.
- Release packaging requires a stable Apple Development or Developer ID Application identity. Apple Development signing is suitable for local verification but not public distribution; a public download still requires Developer ID signing and notarization.
- Chrome before-unload prompts, VoiceOver navigation, larger accessibility text, and repeated fullscreen/Space preview cycles require human verification.
