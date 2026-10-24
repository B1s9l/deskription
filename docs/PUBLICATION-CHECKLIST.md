# Publication checklist

- [x] Owner selected GPL-3.0-only; `LICENSE`, README, Credits, and SPDX notices identify it.
- [ ] Owner confirms authorship or distribution rights for the application icon and repository artwork before publication.
- [ ] Replace ad-hoc signing with a Developer ID Application signature and notarize/staple the macOS archive.
- [ ] Verify signing with `codesign --verify --deep --strict` and Gatekeeper with `spctl --assess` on a clean Mac.
- [ ] Complete cold-launch, two-disposable-profile, VoiceOver, large-text, fullscreen/Space, and interruption tests.
- [ ] Test install, update, and uninstall from a non-development directory and a clean account/Mac.
- [ ] Review the artifact inventory and diagnostic sample for personal data, credentials, private URLs, and absolute development paths.
- [ ] Confirm release checksums and version consistency.
- [ ] Create the public repository only after explicit authorization; enable CI and branch protections.
- [ ] Upload artifacts and publish release notes only after explicit authorization.
- [ ] Submit a Chrome Web Store listing only after explicit authorization and store-policy/privacy review.

No repository, release asset, store listing, tester message, or external publication is created by the local release build.
