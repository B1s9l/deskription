#!/bin/zsh
set -eu

for manifest in \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.deskriptions.bridge.json" \
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.deskriptions.bridge.json" \
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.deskriptions.bridge.json"; do
  if [[ -f "$manifest" ]]; then rm "$manifest"; print "Removed bridge registration: $manifest"; fi
done
print "Move Deskriptions.app to the Trash to remove the app."
print "Saved Desktops and settings were preserved under your user Library. See docs/TESTER-GUIDE.md for optional data removal."
