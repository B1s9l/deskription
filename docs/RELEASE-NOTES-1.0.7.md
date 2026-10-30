# Deskriptions 1.0.7 development build

- Adds an application-independent exact-document record and shared explicit-application restoration path.
- Migrates Preview restoration onto the shared document infrastructure while continuing to decode existing Preview records.
- Adds Microsoft PowerPoint presentation discovery through public `AXDocument` identities with a bounded public Automation fallback for multiple presentations, explicit PowerPoint opening, and post-open verification.
- Retains application-only fallback for unsaved, inaccessible, unidentified, or permission-blocked presentations.

This development package is not a new public release and is not notarized by the ordinary build workflow.
