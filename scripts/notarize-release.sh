#!/bin/zsh
set -eu

root=${0:A:h:h}
version=1.0.1
profile=${1:-${DESKRIPTIONS_NOTARY_PROFILE:-Deskriptions-Notarization}}
artifacts="$root/.build/release-artifacts"
stage="$artifacts/Deskriptions-$version"
app="$stage/Deskriptions.app"
work="$root/.build/notarization"
submission_archive="$work/Deskriptions-$version-notarization.zip"
final_archive="$artifacts/Deskriptions-$version-notarized-macOS.zip"
extension_archive="$artifacts/Deskriptions-$version-Chrome-extension.zip"
kit_archive="$artifacts/Deskriptions-$version-beta-kit.zip"
log="$artifacts/NOTARIZATION-$version.json"

command -v xcrun >/dev/null || { print -u2 "error: Xcode command-line tools are unavailable."; exit 2; }
xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null 2>&1 || {
  print -u2 "error: notarytool Keychain profile '$profile' is missing or cannot authenticate."
  print -u2 "Create it with: xcrun notarytool store-credentials '$profile' --team-id 9ZGCDZ7YNN"
  exit 2
}

"$root/scripts/build-distribution.sh"
mkdir -p "$work"
rm -f "$submission_archive" "$final_archive" "$log"
ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_archive"

result=$(xcrun notarytool submit "$submission_archive" --keychain-profile "$profile" --wait --output-format json)
submission_id=$(print -r -- "$result" | plutil -extract id raw -o - - 2>/dev/null || true)
notary_status=$(print -r -- "$result" | plutil -extract status raw -o - - 2>/dev/null || true)
[[ -n "$submission_id" ]] || { print -u2 "error: notarytool did not return a submission identifier."; exit 3; }
xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$log"
[[ "$notary_status" == Accepted ]] || {
  print -u2 "error: notarization $submission_id finished with status '$notary_status'. See $log"
  exit 3
}

xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=4 "$app"

ditto -c -k --sequesterRsrc --keepParent "$app" "$final_archive"
rm -f "$kit_archive"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$kit_archive"
temporary=$(mktemp -d "$work/verify.XXXXXX")
ditto -x -k "$final_archive" "$temporary"
codesign --verify --strict --verbose=2 "$temporary/Deskriptions.app"
xcrun stapler validate "$temporary/Deskriptions.app"
spctl --assess --type execute --verbose=4 "$temporary/Deskriptions.app"
rm -rf "$temporary"

cd "$artifacts"
shasum -a 256 "${final_archive:t}" "${extension_archive:t}" "${kit_archive:t}" > "SHA256SUMS-$version-notarized.txt"
print "Accepted submission: $submission_id"
print "Final archive: $final_archive"
print "Notarization log: $log"
