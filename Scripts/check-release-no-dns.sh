#!/bin/sh
# Fails if a built .app carries DNS Protection: the packet tunnel extension, its Network
# Extension entitlement. The DNS screens stay compiled in but unreachable (BuildFeatures), so
# their symbols are not checked. Run it on a Release build (docs/gotchas.md,
# SEC-04). Unit tests run in Debug, so they can't see what a Release binary contains.
# usage: check-release-no-dns.sh path/to/ADBLX.app
app="${1:?usage: $0 path/to/ADBLX.app}"
[ -d "$app" ] || { echo "error: $app is not a directory" >&2; exit 2; }
fail=0

if [ -e "$app/PlugIns/ADBLXPacketTunnel.appex" ]; then
    echo "error: Release build embeds ADBLXPacketTunnel.appex" >&2; fail=1
fi
if strings -a "$app/ADBLX" | grep -q "packet-tunnel-provider"; then
    echo "error: Release app binary mentions packet-tunnel-provider" >&2; fail=1
fi
if codesign -d --entitlements - "$app" 2>/dev/null | grep -q "networkextension"; then
    echo "error: Release app is signed with the Network Extension entitlement" >&2; fail=1
fi
[ "$fail" = 0 ] && echo "ok: no DNS Protection in $app"
exit "$fail"
