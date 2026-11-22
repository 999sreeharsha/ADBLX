#!/bin/sh
# Checks check-archive-release.sh: it does nothing outside an archive, and in an archive it fails
# when the built app carries DNS Protection, when an extension's version differs from the app's,
# when its background modes and task identifiers don't match BACKGROUND_UPDATES_ENABLED (all
# present when on, none when off) or it carries the DEBUG timing spike (ADR-0014),
# or when the entitlements Xcode is about to sign with include the Network Extension one or iCloud
# key-value storage (iCloud sync is off in Release).
dir=$(dirname "$0")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

clean_entitlements="$work/clean.entitlements"
cat > "$clean_entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>group.com.ADBLX.shared</string></array></dict></plist>
EOF
icloud_entitlements="$work/icloud.entitlements"
cat > "$icloud_entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.developer.ubiquity-kvstore-identifier</key><string>T.com.ADBLX.ADBLX</string></dict></plist>
EOF
tunnel_entitlements="$work/tunnel.entitlements"
cat > "$tunnel_entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.developer.networking.networkextension</key><array><string>packet-tunnel-provider</string></array></dict></plist>
EOF

version() { # plist short build
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $2" -c "Add :CFBundleVersion string $3" "$1" >/dev/null
}

# background plist modes   (with any mode, the identifiers background filter updates register are added too)
background() {
    [ -n "$2" ] || return 0
    /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" -c "Add :BGTaskSchedulerPermittedIdentifiers array" "$1" >/dev/null
    for mode in $2; do /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes: string $mode" "$1"; done
    for id in com.ADBLX.ADBLX.filter-refresh com.ADBLX.ADBLX.filter-install; do
        /usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers: string $id" "$1"
    done
}

# make-app name modes binary-text [extension-name ext-short]...
#   (the app is 1.2 / 7, every extension build 7)
make_app() {
    app="$work/$1/ADBLX.app"
    mkdir -p "$app/PlugIns"
    printf '%s\n' "$3" > "$app/ADBLX"
    version "$app/Info.plist" 1.2 7
    background "$app/Info.plist" "$2"
    shift 3
    while [ $# -ge 2 ]; do
        mkdir -p "$app/PlugIns/$1.appex"
        version "$app/PlugIns/$1.appex/Info.plist" "$2" 7
        shift 2
    done
    echo "$work/$(basename "$(dirname "$app")")"
}

expect() { # expected-exit action build-dir entitlements [background-updates-flag]
    ACTION="$2" TARGET_BUILD_DIR="$3" WRAPPER_NAME=ADBLX.app SRCROOT=/ CODE_SIGN_ENTITLEMENTS="$4" \
        BACKGROUND_UPDATES_ENABLED="${5:-}" "$dir/check-archive-release.sh" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -ne "$1" ]; then
        echo "FAIL: $(basename "$3") (ACTION=$2, BACKGROUND_UPDATES_ENABLED=${5:-unset}) exited $actual, expected $1"
        failures=$((failures + 1))
    fi
}

modes="fetch processing"
# Release today: the background-updates flag is off, so no background modes.
good=$(make_app good "" "plain app binary" ADBLXAdsBlocker 1.2 ADBLXSafariWebExtension 1.2)
tunnel=$(make_app tunnel "" "plain app binary" ADBLXAdsBlocker 1.2 ADBLXPacketTunnel 1.2)
mismatch=$(make_app mismatch "" "plain app binary" ADBLXAdsBlocker 1.2 ADBLXPrivacyBlocker 1.0)
spike=$(make_app timing-spike "" "BackgroundTimingSpike" ADBLXAdsBlocker 1.2)
with_modes=$(make_app with-modes "$modes" "plain app binary" ADBLXAdsBlocker 1.2)
no_fetch=$(make_app no-fetch "processing" "plain app binary" ADBLXAdsBlocker 1.2)

expect 0 build "$tunnel" "$tunnel_entitlements"
expect 0 install "$good" "$clean_entitlements"
expect 1 install "$tunnel" "$clean_entitlements"
expect 1 install "$mismatch" "$clean_entitlements"
expect 1 install "$spike" "$clean_entitlements"
expect 1 install "$good" "$tunnel_entitlements"
expect 1 install "$good" "$icloud_entitlements"
expect 1 install "$good" "$work/missing.entitlements"
expect 1 install "$work/no-such-build-dir" "$clean_entitlements"
# Background modes follow the flag: absent while it is off, all present once it is on.
expect 1 install "$with_modes" "$clean_entitlements"
expect 0 install "$with_modes" "$clean_entitlements" YES
expect 1 install "$good" "$clean_entitlements" YES
expect 1 install "$no_fetch" "$clean_entitlements" YES

[ "$failures" -eq 0 ] && echo "archive release checks: all cases passed"
exit "$failures"
