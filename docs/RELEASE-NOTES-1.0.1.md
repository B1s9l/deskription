# Deskriptions 1.0.1

This patch release makes code signing deterministic for development and public distribution builds.

- Development builds automatically use an Apple Development certificate and verify the expected Apple team.
- Public builds automatically use a Developer ID Application certificate, Hardened Runtime, and a secure timestamp.
- Certificate renewal no longer requires updating a hard-coded fingerprint.
- Builds stop with a clear error instead of silently producing an ad-hoc-signed app.
