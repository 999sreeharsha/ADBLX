#!/bin/sh
# Checks a built .app's background modes and task identifiers against BACKGROUND_UPDATES_ENABLED
# (ADR-0014), and that it carries none of the DEBUG-only timing spike. The keys come from a merged
# plist, so check the built product, not project.yml. Run it on a Release build; unit tests cover
# Debug.
#   - Flag YES (set in Debug.xcconfig): UIBackgroundModes has fetch and processing, and
#     BGTaskSchedulerPermittedIdentifiers has both filter-update identifiers.
#   - Flag unset or anything else (Release today): none of them. Declaring a background mode the
#     app doesn't use risks App Review rejection (Guideline 2.5.4), and nothing registers the
#     tasks until background updates ship.
# The archive phase gets the flag from the build settings; CI passes it in the environment.
# usage: [BACKGROUND_UPDATES_ENABLED=YES] check-background-modes.sh path/to/ADBLX.app
app="${1:?usage: $0 path/to/ADBLX.app}"
[ -d "$app" ] || { echo "error: $app is not a directory" >&2; exit 2; }
plist="$app/Info.plist"
fail=0

contains() { # key value
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null | sed 's/^ *//' | grep -qx "$2"
}

if [ "${BACKGROUND_UPDATES_ENABLED:-}" = "YES" ]; then
    for mode in fetch processing; do
        contains UIBackgroundModes "$mode" || { echo "error: UIBackgroundModes lacks $mode" >&2; fail=1; }
    done
    for id in com.ADBLX.ADBLX.filter-refresh com.ADBLX.ADBLX.filter-install; do
        contains BGTaskSchedulerPermittedIdentifiers "$id" || { echo "error: BGTaskSchedulerPermittedIdentifiers lacks $id" >&2; fail=1; }
    done
    expectation="background modes and task identifiers present"
else
    for mode in fetch processing; do
        contains UIBackgroundModes "$mode" && { echo "error: UIBackgroundModes has $mode while BACKGROUND_UPDATES_ENABLED is off" >&2; fail=1; }
    done
    for id in com.ADBLX.ADBLX.filter-refresh com.ADBLX.ADBLX.filter-install; do
        contains BGTaskSchedulerPermittedIdentifiers "$id" && { echo "error: BGTaskSchedulerPermittedIdentifiers has $id while BACKGROUND_UPDATES_ENABLED is off" >&2; fail=1; }
    done
    expectation="no background modes or task identifiers (BACKGROUND_UPDATES_ENABLED off)"
fi
if strings -a "$app/ADBLX" 2>/dev/null | grep -q -e BackgroundTimingSpike -e DownloadTimer -e CompileTimer; then
    echo "error: app binary contains the DEBUG timing spike" >&2; fail=1
fi
[ "$fail" = 0 ] && echo "ok: $expectation in $app"
exit "$fail"
