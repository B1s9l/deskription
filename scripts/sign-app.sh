#!/bin/zsh
set -eu

app=${1:?usage: sign-app.sh /path/to/Deskriptions.app}
root=${0:A:h:h}
identity=${DESKRIPTIONS_SIGNING_IDENTITY:-}
require_stable=${DESKRIPTIONS_REQUIRE_STABLE_SIGNING:-1}
signing_mode=${DESKRIPTIONS_SIGNING_MODE:-development}
team_id=${DESKRIPTIONS_DEVELOPMENT_TEAM:-9ZGCDZ7YNN}

case "$signing_mode" in
  development) certificate_kind="Apple Development" ;;
  distribution) certificate_kind="Developer ID Application" ;;
  *) print -u2 "error: unsupported signing mode '$signing_mode' (expected development or distribution)."; exit 2 ;;
esac
identity_store=${DESKRIPTIONS_SIGNING_IDENTITY_FILE:-"$HOME/Library/Application Support/Deskriptions/signing-identity-$signing_mode"}

if [[ "$signing_mode" == distribution ]]; then
  require_stable=1
fi

if [[ -z "$identity" ]]; then
  if [[ -s "$identity_store" ]]; then
    pinned=$(tr -d '[:space:]' < "$identity_store")
    if security find-identity -v -p codesigning 2>/dev/null | grep -Eq "^[[:space:]]*[0-9]+\) $pinned \"$certificate_kind:"; then
      identity=$pinned
    fi
  fi
  if [[ -z "$identity" ]]; then
    # Pin the certificate fingerprint, not its display name. Xcode commonly
    # creates multiple certificates with the same name, and asking codesign to
    # resolve that name can silently change the app's signing requirement.
    identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -nE "/\"$certificate_kind:/s/^[[:space:]]*[0-9]+\\) ([0-9A-F]{40}) .*/\\1/p" | head -n 1)
    if [[ -n "$identity" ]]; then
      mkdir -p "${identity_store:h}"
      temporary="$identity_store.tmp.$$"
      print -r -- "$identity" > "$temporary"
      chmod 600 "$temporary"
      mv -f "$temporary" "$identity_store"
    fi
  fi
fi

if [[ -n "$identity" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -Eq "^[[:space:]]*[0-9]+\) $identity \"$certificate_kind:"; then
  print -u2 "error: signing identity '$identity' is not a valid '$certificate_kind' certificate."
  exit 2
fi

if [[ -n "$identity" ]]; then
  timestamp_arguments=(--timestamp=none)
  [[ "$signing_mode" == distribution ]] && timestamp_arguments=(--timestamp)
  print "Signing in $signing_mode mode with identity: $identity"
  for executable in "$app/Contents/Resources/deskriptions-bridge" "$app/Contents/Resources/deskriptions-bridge-chrome" "$app/Contents/Resources/deskriptions-bridge-brave" "$app/Contents/Resources/deskriptions-bridge-edge"; do
    [[ -f "$executable" ]] && codesign --force --options runtime "${timestamp_arguments[@]}" --sign "$identity" "$executable"
  done
  codesign --force --options runtime "${timestamp_arguments[@]}" --entitlements "$root/app/Deskriptions.entitlements" --sign "$identity" --identifier org.deskriptions.app "$app"
else
  if [[ "$require_stable" == 1 ]]; then
    print -u2 "error: no valid '$certificate_kind' identity for Apple team $team_id was found in the keychain."
    print -u2 "Open Xcode > Settings > Accounts > Manage Certificates and create/download the required certificate."
    print -u2 "Alternatively set DESKRIPTIONS_SIGNING_IDENTITY to its SHA-1 fingerprint."
    exit 2
  fi
  print -u2 "warning: no code-signing identity found; using ad-hoc signing. macOS capture permission will need to be granted again after every rebuild."
  for executable in "$app/Contents/Resources/deskriptions-bridge" "$app/Contents/Resources/deskriptions-bridge-chrome" "$app/Contents/Resources/deskriptions-bridge-brave" "$app/Contents/Resources/deskriptions-bridge-edge"; do
    [[ -f "$executable" ]] && codesign --force --sign - "$executable"
  done
  codesign --force --entitlements "$root/app/Deskriptions.entitlements" --sign - --identifier org.deskriptions.app "$app"
fi

for executable in "$app/Contents/Resources/deskriptions-bridge" "$app/Contents/Resources/deskriptions-bridge-chrome" "$app/Contents/Resources/deskriptions-bridge-brave" "$app/Contents/Resources/deskriptions-bridge-edge"; do
  [[ -f "$executable" ]] && codesign --verify --strict --verbose=2 "$executable"
done
codesign --verify --strict --verbose=2 "$app"
if [[ -n "$identity" ]]; then
  team_identifier=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ "$team_identifier" == "$team_id" ]] || { print -u2 "error: signed app has team '$team_identifier', expected '$team_id'"; exit 2; }
  requirement=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')
  [[ "$requirement" == *"identifier \"org.deskriptions.app\""* ]] || { print -u2 "error: signed app has an unexpected designated requirement"; exit 2; }
  flags=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')
  [[ "$flags" == *runtime* ]] || { print -u2 "error: Hardened Runtime is not enabled"; exit 2; }
  if [[ "$signing_mode" == distribution ]]; then
    timestamp=$(codesign -dvvv "$app" 2>&1 | sed -n 's/^Timestamp=//p')
    [[ -n "$timestamp" ]] || { print -u2 "error: distribution signature has no secure timestamp"; exit 2; }
    print "Verified secure timestamp: $timestamp"
  fi
  print "Verified stable signing team: $team_identifier"
  print "Verified designated requirement: $requirement"
fi
