#!/bin/zsh
set -eu
root=${0:A:h:h}
cd "$root"
mkdir -p .build/cache .build/home
HOME="$root/.build/home" CLANG_MODULE_CACHE_PATH="$root/.build/cache" SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/cache" swift build --disable-sandbox --product DeskriptionsLab
HOME="$root/.build/home" CLANG_MODULE_CACHE_PATH="$root/.build/cache" SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/cache" swift build --disable-sandbox --product deskriptions-bridge
bundle="$root/.build/Deskriptions-1.0.2-build39.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$root/.build/debug/DeskriptionsLab" "$bundle/Contents/MacOS/DeskriptionsLab"
cp "$root/.build/debug/deskriptions-bridge" "$bundle/Contents/Resources/deskriptions-bridge"
cp "$root/Assets/AppIcon.iconset/icon_512x512@2x.png" "$bundle/Contents/Resources/Deskriptions.png"
cp "$root/app/Info.plist" "$bundle/Contents/Info.plist"
DESKRIPTIONS_SIGNING_MODE=development DESKRIPTIONS_REQUIRE_STABLE_SIGNING=1 \
  "$root/scripts/sign-app.sh" "$bundle"
print "$bundle"
