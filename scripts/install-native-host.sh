#!/bin/zsh
set -eu
if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 EXTENSION_ID"
  exit 64
fi
root=${0:A:h:h}
extension_id=$1
[[ $extension_id =~ '^[a-p]{32}$' ]] || { print -u2 "Invalid unpacked Chrome extension ID"; exit 64; }
cd "$root"
HOME="$root/.build/home" CLANG_MODULE_CACHE_PATH="$root/.build/cache" SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/cache" swift build --disable-sandbox --product deskriptions-bridge
host="$root/.build/debug/deskriptions-bridge"
manifest_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$manifest_dir"
manifest="$manifest_dir/com.deskriptions.bridge.json"
sed -e "s|__HOST_PATH__|$host|" -e "s|__EXTENSION_ID__|$extension_id|" "$root/native-host/manifest.template.json" > "$manifest"
print "Installed $manifest"

