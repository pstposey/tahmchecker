#!/bin/bash
# CI: selects the newest installed Xcode with the given major version
# (e.g. 27) for the rest of the job via DEVELOPER_DIR. Writes found=true or
# found=false to $GITHUB_OUTPUT; a missing version is a warning, not a
# failure, because runner images change what they ship.
set -euo pipefail
major="$1"
echo "Installed Xcodes:"
ls -d /Applications/Xcode*.app 2>/dev/null || true
best=""
best_version=""
for app in /Applications/Xcode*.app; do
  [ -d "$app/Contents/Developer" ] || continue
  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || true)
  [ "${version%%.*}" = "$major" ] || continue
  if [ -z "$best_version" ] || [ "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -1)" = "$version" ]; then
    best="$app"; best_version="$version"
  fi
done
if [ -z "$best" ]; then
  echo "::warning::No Xcode $major is installed on this runner image; the Xcode $major build and smoke test were skipped."
  echo "found=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "DEVELOPER_DIR=$best/Contents/Developer" >> "$GITHUB_ENV"
echo "found=true" >> "$GITHUB_OUTPUT"
DEVELOPER_DIR="$best/Contents/Developer" xcodebuild -version
DEVELOPER_DIR="$best/Contents/Developer" swift --version
