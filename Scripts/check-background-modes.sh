#!/bin/sh
# Fails unless a built .app declares the background modes and task identifiers that background
# filter updates register (ADR-0014), and carries none of the DEBUG-only timing spike. The keys
# come from a merged plist, so check the built product, not project.yml. Run it on a Release
# build; unit tests cover Debug.
# usage: check-background-modes.sh path/to/ADBLX.app
app="${1:?usage: $0 path/to/ADBLX.app}"
[ -d "$app" ] || { echo "error: $app is not a directory" >&2; exit 2; }
plist="$app/Info.plist"
fail=0

contains() { # key value
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null | sed 's/^ *//' | grep -qx "$2"
}

for mode in fetch processing; do
    contains UIBackgroundModes "$mode" || { echo "error: UIBackgroundModes lacks $mode" >&2; fail=1; }
done
for id in com.ADBLX.ADBLX.filter-refresh com.ADBLX.ADBLX.filter-install; do
    contains BGTaskSchedulerPermittedIdentifiers "$id" || { echo "error: BGTaskSchedulerPermittedIdentifiers lacks $id" >&2; fail=1; }
done
if strings -a "$app/ADBLX" 2>/dev/null | grep -q -e BackgroundTimingSpike -e DownloadTimer -e CompileTimer; then
    echo "error: app binary contains the DEBUG timing spike" >&2; fail=1
fi
[ "$fail" = 0 ] && echo "ok: background modes and task identifiers in $app"
exit "$fail"
