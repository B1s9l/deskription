#!/bin/zsh
set -eu

root=${0:A:h:h}
version=1.0.7
stage="$root/.build/release-artifacts/Deskriptions-$version"
app="$stage/Deskriptions.app"
cache="$root/.build/release-cache"
home="$root/.build/release-home"

rm -rf "$stage"
mkdir -p "$cache" "$home" "$app/Contents/MacOS" "$app/Contents/Resources" "$stage/Chrome Extension" "$stage/Documentation"
cd "$root"
HOME="$home" CLANG_MODULE_CACHE_PATH="$cache" SWIFTPM_MODULECACHE_OVERRIDE="$cache" \
  swift build -c release --disable-sandbox --product DeskriptionsLab
HOME="$home" CLANG_MODULE_CACHE_PATH="$cache" SWIFTPM_MODULECACHE_OVERRIDE="$cache" \
  swift build -c release --disable-sandbox --product deskriptions-bridge

cp "$root/.build/release/DeskriptionsLab" "$app/Contents/MacOS/DeskriptionsLab"
cp "$root/.build/release/deskriptions-bridge" "$app/Contents/Resources/deskriptions-bridge"
for browser in chrome brave edge; do cp "$root/.build/release/deskriptions-bridge" "$app/Contents/Resources/deskriptions-bridge-$browser"; done
cp "$root/app/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Deskriptions" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier org.deskriptions.app" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 44" "$app/Contents/Info.plist"
cp "$root/Assets/AppIcon.iconset/icon_512x512@2x.png" "$app/Contents/Resources/Deskriptions.png"
chmod 755 "$app/Contents/MacOS/DeskriptionsLab" "$app/Contents/Resources/deskriptions-bridge" "$app/Contents/Resources/deskriptions-bridge-chrome" "$app/Contents/Resources/deskriptions-bridge-brave" "$app/Contents/Resources/deskriptions-bridge-edge"
if [[ "${DESKRIPTIONS_ALLOW_ADHOC_RELEASE:-0}" == 1 ]]; then
  print -u2 "warning: producing an explicitly requested ad-hoc test package; capture authorization is not persistent across changed builds"
  "$root/scripts/sign-app.sh" "$app"
else
  DESKRIPTIONS_REQUIRE_STABLE_SIGNING=1 DESKRIPTIONS_SIGNING_MODE="${DESKRIPTIONS_SIGNING_MODE:-development}" "$root/scripts/sign-app.sh" "$app"
fi

cp "$root/extension/manifest.json" "$root/extension/service-worker.js" "$root/extension/startup.html" "$stage/Chrome Extension/"
cp "$root/scripts/install-release-bridge.sh" "$root/scripts/uninstall.sh" "$stage/"
cp "$root/native-host/manifest.template.json" "$stage/native-host-manifest.template.json"
cp "$root/README.md" "$root/docs/API.md" "$root/docs/DESKTOP-FORMAT.md" \
  "$root/docs/TESTER-GUIDE.md" "$root/docs/COMPATIBILITY.md" "$root/docs/KNOWN-ISSUES.md" \
  "$root/docs/RELEASE-NOTES-1.0.7.md" "$root/docs/PUBLICATION-CHECKLIST.md" "$stage/Documentation/"
cp "$root/THIRD-PARTY-NOTICES.md" "$stage/Documentation/"
cp "$root/LICENSE" "$stage/Documentation/"
chmod 755 "$stage/install-release-bridge.sh" "$stage/uninstall.sh"

cd "$root/.build/release-artifacts"
ditto -c -k --sequesterRsrc --keepParent "Deskriptions-$version/Deskriptions.app" "Deskriptions-$version-macOS.zip"
ditto -c -k --keepParent "Deskriptions-$version/Chrome Extension" "Deskriptions-$version-Chrome-extension.zip"
ditto -c -k --sequesterRsrc --keepParent "Deskriptions-$version" "Deskriptions-$version-beta-kit.zip"
shasum -a 256 "Deskriptions-$version-macOS.zip" "Deskriptions-$version-Chrome-extension.zip" "Deskriptions-$version-beta-kit.zip" > "SHA256SUMS-$version.txt"
print "$stage"
