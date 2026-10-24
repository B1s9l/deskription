#!/bin/zsh
set -eu

root=${0:A:h:h}
identity=${DESKRIPTIONS_DEVELOPER_ID_SHA1:-1E985D10E686F82AF175C9BCF205D17EA0878240}

identity_line=$(security find-identity -v -p codesigning 2>/dev/null | grep -E "^[[:space:]]*[0-9]+\) $identity \"Developer ID Application:.*\(9ZGCDZ7YNN\)\"" || true)
[[ -n "$identity_line" ]] || {
  print -u2 "error: Developer ID Application identity $identity for team 9ZGCDZ7YNN is unavailable."
  exit 2
}

DESKRIPTIONS_SIGNING_MODE=distribution \
DESKRIPTIONS_SIGNING_IDENTITY="$identity" \
  "$root/scripts/build-release.sh"
