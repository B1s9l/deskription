# Deskriptions 1.0.9 development build

- Bounds PowerPoint Automation inside the Apple Event itself so timed-out workers terminate.
- Runs browser refresh and native adapter inventory concurrently.
- Reuses one Window Server snapshot for browser matching, visibility, and generic title correlation.
- Validates browser profiles and native integrations concurrently before saving.
- Verifies individual Preview and PowerPoint documents without repeatedly rebuilding complete inventories.
- Coalesces duplicate Settings refreshes and caches integration icons.
- Reduces the bounded Preview identity retry from eight seconds to two seconds.
- Uses PowerPoint's fast bulk `full name of every presentation` query instead of slow per-document property access.
- Populates browser, Finder, Notes, Preview, and PowerPoint inventory sections progressively while keeping Save disabled until collection is complete.
- Build 49 removes the floating ScreenCaptureKit preview feature, its shortcut, menu items, capture diagnostics, and Screen Recording usage description while preserving Preview.app document restoration.
- PowerPoint restoration now uses one bounded Automation confirmation after targeted Accessibility polling and distinguishes an accepted but unverifiable open command from a confirmed failure.
- Build 50 adds exact-document discovery and explicit restoration for Microsoft Word documents and Microsoft Excel workbooks, using Accessibility with bounded Automation fallback and the shared document-restoration infrastructure.

This is a development artifact. It has not been notarized or published.
