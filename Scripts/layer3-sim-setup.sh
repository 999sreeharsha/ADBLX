#!/usr/bin/env bash
# Prepares an iOS simulator for manually testing Layer 3 (YouTube ad handling in Safari).
#
#   Scripts/layer3-sim-setup.sh [simulator-udid]
#
# Builds and installs ADBLX, waits for the app's launch bootstrap to publish the Web
# Extension files into the App Group, forces the entitlement to premiumActive (simulator
# only — equivalent to tapping "Start 15-Day Free Trial"), then opens a YouTube watch page.
#
# Steps that cannot be scripted (Apple requires them in the UI) are printed at the end.
set -euo pipefail

cd "$(dirname "$0")/.."
UDID="${1:-$(Scripts/find-simulator-udid.sh)}"
BUNDLE_ID="com.ADBLX.ADBLX"
DERIVED="${DERIVED_DATA:-${TMPDIR:-/tmp}/adblx-layer3-dd}"
VIDEO_URL="${VIDEO_URL:-https://m.youtube.com/watch?v=jNQXAC9IVRw}"

echo "==> Simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true

echo "==> Building"
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" build -quiet

echo "==> Installing and launching"
xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/ADBLX.app"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

GROUP=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" groups | awk '/group.com.ADBLX.shared/ {print $2}')
ENTITLEMENT="$GROUP/WebExtension/entitlement.json"

# The Web Extension files are written only after the content-blocker install and reloads
# finish, which can take minutes on a first launch.
echo "==> Waiting for the launch bootstrap to publish $ENTITLEMENT"
for _ in $(seq 1 120); do
    [[ -f "$ENTITLEMENT" ]] && break
    sleep 5
done
[[ -f "$ENTITLEMENT" ]] || { echo "Bootstrap never published entitlement.json" >&2; exit 1; }

printf '{"state":"premiumActive","updatedAt":%s}' "$(date +%s)" > "$ENTITLEMENT"
echo "==> Entitlement: $(cat "$ENTITLEMENT")"
echo "==> Rules pointer: $(cat "$GROUP/WebExtension/current.json")"

xcrun simctl openurl "$UDID" "$VIDEO_URL"

cat <<EOF

Manual steps:
  1. Simulator: Settings > Apps > Safari > Extensions > ADBLX: turn on, and set
     youtube.com (or All Websites) to Allow.
  2. Mac Safari: Develop > Simulator > the YouTube page > Console, filter "ADBLX-L3".
  3. Reload the YouTube tab and play a video until an ad appears.
EOF
