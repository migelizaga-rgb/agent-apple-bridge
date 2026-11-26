#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="dist/AgentAppleBridge.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/AgentAppleBridge" "$app/Contents/MacOS/AgentAppleBridge"
sed 's/__EXECUTABLE__/AgentAppleBridge/g' Resources/Info.plist.in > "$app/Contents/Info.plist"
# The namespace contains an XML character reference, decoded by the plist reader.
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
if [ -n "${AGENT_BRIDGE_SIGNING_IDENTITY:-}" ]; then
  if [ -n "${AGENT_BRIDGE_PINNED_LEAF:-}" ]; then
    case "$AGENT_BRIDGE_PINNED_LEAF" in *[!a-fA-F0-9]*) echo 'Invalid leaf certificate hash' >&2; exit 1;; esac
    [ "${#AGENT_BRIDGE_PINNED_LEAF}" -eq 40 ] || { echo 'Expected 40 hex characters' >&2; exit 1; }
    codesign --force --options runtime --entitlements Resources/AgentAppleBridge.entitlements \
      --sign "$AGENT_BRIDGE_SIGNING_IDENTITY" \
      --requirements "=identifier \"$bundle_id\" and certificate leaf = H\"$AGENT_BRIDGE_PINNED_LEAF\"" "$app"
  else
    codesign --force --options runtime --entitlements Resources/AgentAppleBridge.entitlements \
      --sign "$AGENT_BRIDGE_SIGNING_IDENTITY" "$app"
  fi
  codesign --verify --strict "$app"
fi
printf '%s\n' "$app"
