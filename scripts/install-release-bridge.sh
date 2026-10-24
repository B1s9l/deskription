#!/bin/zsh
set -eu

extension_id="agimibdhlfgliioagkdaefkddfenhmfe"
app_path=${1:-/Applications/Deskriptions.app}
template="${0:A:h}/native-host-manifest.template.json"
if [[ ! -f "$template" ]]; then
  print -u2 "Installer support file is missing: $template"
  exit 66
fi
for spec in \
  "chrome|Library/Application Support/Google/Chrome/NativeMessagingHosts|Google Chrome" \
  "brave|Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts|Brave Browser" \
  "edge|Library/Application Support/Microsoft Edge/NativeMessagingHosts|Microsoft Edge"; do
  tag=${spec%%|*}; rest=${spec#*|}; relative=${rest%%|*}; name=${rest#*|}
  host="$app_path/Contents/Resources/deskriptions-bridge-$tag"
  [[ -x "$host" ]] || { print -u2 "Deskriptions $name bridge was not found at: $host"; exit 66; }
  manifest_dir="$HOME/$relative"; manifest="$manifest_dir/com.deskriptions.bridge.json"; temporary="$manifest.tmp.$$"
  mkdir -p "$manifest_dir"
  sed -e "s|__HOST_PATH__|$host|" -e "s|__EXTENSION_ID__|$extension_id|" "$template" > "$temporary"
  chmod 600 "$temporary"; mv -f "$temporary" "$manifest"
  print "Installed $name bridge registration: $manifest"
done
print "Reload the extension in each installed browser now."
