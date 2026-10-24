#!/bin/zsh
set -eu

app=${1:?usage: sign-app.sh /path/to/Deskriptions.app}
root=${0:A:h:h}
identity=${DESKRIPTIONS_SIGNING_IDENTITY:-}
require_stable=${DESKRIPTIONS_REQUIRE_STABLE_SIGNING:-0}
identity_store=${DESKRIPTIONS_SIGNING_IDENTITY_FILE:-"$HOME/Library/Application Support/Deskriptions/signing-identity"}

if [[ -z "$identity" ]]; then
  if [[ -s "$identity_store" ]]; then
    pinned=$(tr -d '[:space:]' < "$identity_store")
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "^[[:space:]]*[0-9]*) $pinned \""; then
      identity=$pinned
    fi
  fi
  if [[ -z "$identity" ]]; then
    # Pin the certificate fingerprint, not its display name. Xcode commonly
    # creates multiple certificates with the same name, and asking codesign to
    # resolve that name can silently change the app's signing requirement.
    identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -nE '/"(Developer ID Application|Apple Development):/s/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}) .*/\1/p' | head -n 1)
    if [[ -n "$identity" ]]; then
      mkdir -p "${identity_store:h}"
      temporary="$identity_store.tmp.$$"
      print -r -- "$identity" > "$temporary"
      chmod 600 "$temporary"
      mv -f "$temporary" "$identity_store"
    fi
  fi
fi

if [[ -n "$identity" ]]; then
  print "Signing with stable identity: $identity"
  for executable in "$app/Contents/Resources/deskriptions-bridge" "$app/Contents/Resources/deskriptions-bridge-chrome" "$app/Contents/Resources/deskriptions-bridge-brave" "$app/Contents/Resources/deskriptions-bridge-edge"; do
    [[ -f "$executable" ]] && codesign --force --options runtime --timestamp=none --sign "$identity" "$executable"
  done
  codesign --force --options runtime --timestamp=none --entitlements "$root/app/Deskriptions.entitlements" --sign "$identity" --identifier org.deskriptions.app "$app"
else
  if [[ "$require_stable" == 1 ]]; then
    print -u2 "error: release packaging requires a stable Apple Development or Developer ID Application identity."
    print -u2 "Create/import the certificate, or set DESKRIPTIONS_SIGNING_IDENTITY to its SHA-1 fingerprint."
    exit 2
  fi
  print -u2 "warning: no code-signing identity found; using ad-hoc signing. macOS capture permission will need to be granted again after every rebuild."
  for executable in "$app/Contents/Resources/deskriptions-bridge" "$app/Contents/Resources/deskriptions-bridge-chrome" "$app/Contents/Resources/deskriptions-bridge-brave" "$app/Contents/Resources/deskriptions-bridge-edge"; do
    [[ -f "$executable" ]] && codesign --force --sign - "$executable"
  done
  codesign --force --entitlements "$root/app/Deskriptions.entitlements" --sign - --identifier org.deskriptions.app "$app"
fi

codesign --verify --deep --strict "$app"
if [[ -n "$identity" ]]; then
  team_identifier=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ -n "$team_identifier" && "$team_identifier" != "not set" ]] || { print -u2 "error: signed release has no TeamIdentifier"; exit 2; }
  requirement=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')
  [[ "$requirement" == *"identifier \"org.deskriptions.app\""* ]] || { print -u2 "error: signed app has an unexpected designated requirement"; exit 2; }
  print "Verified stable signing team: $team_identifier"
  print "Verified designated requirement: $requirement"
fi
