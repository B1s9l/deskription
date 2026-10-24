# Deskriptions 0.11.1 release candidate

Deskriptions is a native macOS menu-bar app for pinning live window previews and saving or restoring Desktops. This candidate supports content-aware restoration for Chromium browser windows and tabs, Finder folders, exact Preview documents where Accessibility exposes their file URLs, and selected Apple Notes identities. Other foreground apps use application-only launch or activation.

This maintenance release adds bounded live-preview recovery, verifies recreated source windows conservatively, keeps the Settings window reusable across repeated close/open cycles, improves saved-Desktop retention controls, and expands regression coverage for persistence, deletion, retry, browser identity, native integrations, and the persistent naming counter.

The app and Chromium adapter are version 0.11.1 (build 36). Saved Desktop format v1 and adapter protocol v1 are unchanged. Existing saved Desktops remain compatible.

Live preview quality still depends on the source application continuing to render in the background. Deskriptions cannot force updates from minimized, suspended, protected, or DRM-backed content. macOS Space placement is not managed. See `KNOWN-ISSUES.md` and `TESTER-GUIDE.md` before testing.
