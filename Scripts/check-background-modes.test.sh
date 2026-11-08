#!/bin/sh
# Checks check-background-modes.sh against built apps with and without each entry (ADR-0014).
dir=$(dirname "$0")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# make-app name modes identifiers [binary-text]
make_app() {
    app="$work/$1.app"
    mkdir -p "$app"
    plist="$app/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$plist" >/dev/null
    for mode in $2; do /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes: string $mode" "$plist"; done
    /usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers array" "$plist"
    for id in $3; do /usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers: string $id" "$plist"; done
    printf '%s' "${4:-}" > "$app/ADBLX"
    echo "$app"
}

expect() { # expected-exit app
    "$dir/check-background-modes.sh" "$2" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -ne "$1" ]; then
        echo "FAIL: $(basename "$2") exited $actual, expected $1"
        failures=$((failures + 1))
    fi
}

ids="com.ADBLX.ADBLX.filter-refresh com.ADBLX.ADBLX.filter-install"
expect 0 "$(make_app complete "fetch processing" "$ids")"
expect 1 "$(make_app no-fetch "processing" "$ids")"
expect 1 "$(make_app no-processing "fetch" "$ids")"
expect 1 "$(make_app no-refresh-id "fetch processing" "com.ADBLX.ADBLX.filter-install")"
expect 1 "$(make_app no-install-id "fetch processing" "com.ADBLX.ADBLX.filter-refresh")"
expect 1 "$(make_app nothing "" "")"
expect 1 "$(make_app timing-spike "fetch processing" "$ids" "BackgroundTimingSpike")"
expect 2 "$work/missing.app"

[ "$failures" -eq 0 ] && echo "background modes check: all cases passed"
exit "$failures"
