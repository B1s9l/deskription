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

This is a development artifact. It has not been notarized or published.
