#!/bin/zsh
set -eu

candidate=${1:?usage: install-trusted-update.sh /path/to/Deskriptions.app}
target=/Applications/Deskriptions.app
expected_bundle=org.deskriptions.app
expected_team=9ZGCDZ7YNN

[[ -d "$candidate" ]] || { print -u2 "error: candidate app does not exist: $candidate"; exit 2; }
codesign --verify --strict --deep --verbose=2 "$candidate"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")
[[ "$bundle" == "$expected_bundle" ]] || { print -u2 "error: candidate bundle identifier is '$bundle'."; exit 2; }
team=$(codesign -dv --verbose=4 "$candidate" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$team" == "$expected_team" ]] || { print -u2 "error: candidate team is '$team', expected '$expected_team'."; exit 2; }
requirement=$(codesign -d -r- "$candidate" 2>&1 | sed -n 's/^designated => //p')
[[ "$requirement" == *'certificate leaf[field.1.2.840.113635.100.6.1.13]'* ]] || {
  print -u2 "error: candidate is not Developer ID Application-signed. Refusing to replace the trusted installed app with a development or ad-hoc build."
  exit 2
}
flags=$(codesign -dv --verbose=4 "$candidate" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')
[[ "$flags" == *runtime* ]] || { print -u2 "error: candidate does not use Hardened Runtime."; exit 2; }

if [[ -d "$target" ]]; then
  existing_requirement=$(codesign -d -r- "$target" 2>&1 | sed -n 's/^designated => //p')
  [[ "$existing_requirement" == "$requirement" ]] || {
    print -u2 "error: installed and candidate designated requirements differ. Refusing an update that could invalidate privacy grants."
    exit 2
  }
  old_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
  old_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")
  backup="/Applications/Deskriptions-previous-$old_version-build$old_build.app"
  [[ ! -e "$backup" ]] || backup="/Applications/Deskriptions-previous-$old_version-build$old_build-$(date +%Y%m%d-%H%M%S).app"
else
  backup=""
fi

temporary="/Applications/.Deskriptions-update-$$.app"
trap '[[ -e "$temporary" ]] && rm -rf "$temporary"' EXIT
ditto "$candidate" "$temporary"
codesign --verify --strict --deep --verbose=2 "$temporary"
if [[ -n "$backup" ]]; then mv "$target" "$backup"; fi
mv "$temporary" "$target"
codesign --verify --strict --deep --verbose=2 "$target"
print "Installed: $target"
[[ -n "$backup" ]] && print "Previous app preserved at: $backup"
