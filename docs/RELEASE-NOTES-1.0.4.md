# Deskriptions 1.0.4 development build

- Separates Chromium adapter release versions from protocol/capability compatibility, so compatible 1.0.0 extensions remain connected to newer app releases.
- Adds an explicit Preview Accessibility Grant Access action, manual System Settings fallback, and status refresh on return.
- Adds a guarded Developer ID local-update workflow and documents why Apple Development builds do not preserve the public app's TCC code identity.
- Runs Desktop-name generation outside the modal Save Desktop UI actor and shows private, non-content-bearing progress or failure status.

This development package is not a new public release. Public notarization remains an explicit, separately authorized workflow.
