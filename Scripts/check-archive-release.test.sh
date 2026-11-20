#!/bin/sh
# Checks check-archive-release.sh: it does nothing outside an archive, and in an archive it fails
# when the built app carries DNS Protection, when an extension's version differs from the app's,
# or when the entitlements Xcode is about to sign with include the Network Extension one.
dir=$(dirname "$0")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

clean_entitlements="$work/clean.entitlements"
cat > "$clean_entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>group.com.ADBLX.shared</string></array></dict></plist>
EOF
tunnel_entitlements="$work/tunnel.entitlements"
cat > "$tunnel_entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.developer.networking.networkextension</key><array><string>packet-tunnel-provider</string></array></dict></plist>
EOF

version() { # plist short build
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $2" -c "Add :CFBundleVersion string $3" "$1" >/dev/null
}

# make-app name [extension-name ext-short]...   (the app is 1.2 / 7, every extension build 7)
make_app() {
    app="$work/$1/ADBLX.app"
    mkdir -p "$app/PlugIns"
    printf 'plain app binary\n' > "$app/ADBLX"
    version "$app/Info.plist" 1.2 7
    shift
    while [ $# -ge 2 ]; do
        mkdir -p "$app/PlugIns/$1.appex"
        version "$app/PlugIns/$1.appex/Info.plist" "$2" 7
        shift 2
    done
    echo "$work/$(basename "$(dirname "$app")")"
}

expect() { # expected-exit action build-dir entitlements
    ACTION="$2" TARGET_BUILD_DIR="$3" WRAPPER_NAME=ADBLX.app SRCROOT=/ CODE_SIGN_ENTITLEMENTS="$4" \
        "$dir/check-archive-release.sh" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -ne "$1" ]; then
        echo "FAIL: $(basename "$3") (ACTION=$2) exited $actual, expected $1"
        failures=$((failures + 1))
    fi
}

good=$(make_app good ADBLXAdsBlocker 1.2 ADBLXSafariWebExtension 1.2)
tunnel=$(make_app tunnel ADBLXAdsBlocker 1.2 ADBLXPacketTunnel 1.2)
mismatch=$(make_app mismatch ADBLXAdsBlocker 1.2 ADBLXPrivacyBlocker 1.0)

expect 0 build "$tunnel" "$tunnel_entitlements"
expect 0 install "$good" "$clean_entitlements"
expect 1 install "$tunnel" "$clean_entitlements"
expect 1 install "$mismatch" "$clean_entitlements"
expect 1 install "$good" "$tunnel_entitlements"
expect 1 install "$good" "$work/missing.entitlements"
expect 1 install "$work/no-such-build-dir" "$clean_entitlements"

[ "$failures" -eq 0 ] && echo "archive release checks: all cases passed"
exit "$failures"
