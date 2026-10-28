#!/bin/zsh
set -eu

root=${0:A:h:h}

DESKRIPTIONS_SIGNING_MODE=distribution \
DESKRIPTIONS_REQUIRE_STABLE_SIGNING=1 \
  "$root/scripts/build-release.sh"
