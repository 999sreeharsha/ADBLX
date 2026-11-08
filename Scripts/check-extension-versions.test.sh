#!/bin/sh
# Checks check-extension-versions.sh against built apps whose extensions match the app's version,
# and against each way one can differ.
dir=$(dirname "$0")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# set-version plist short-version bundle-version (an empty value leaves the key out)
set_version() {
    [ -n "$2" ] && /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $2" "$1" >/dev/null
    [ -n "$3" ] && /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $3" "$1" >/dev/null
    return 0
}

# make-app name app-short app-build [extension-name ext-short ext-build]...
make_app() {
    app="$work/$1.app"
    mkdir -p "$app/PlugIns"
    set_version "$app/Info.plist" "$2" "$3"
    shift 3
    while [ $# -ge 3 ]; do
        mkdir -p "$app/PlugIns/$1.appex"
        set_version "$app/PlugIns/$1.appex/Info.plist" "$2" "$3"
        shift 3
    done
    echo "$app"
}

expect() { # expected-exit app
    "$dir/check-extension-versions.sh" "$2" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -ne "$1" ]; then
        echo "FAIL: $(basename "$2") exited $actual, expected $1"
        failures=$((failures + 1))
    fi
}

expect 0 "$(make_app matching 1.2 7 Ads 1.2 7 Privacy 1.2 7)"
expect 1 "$(make_app short-differs 1.2 7 Ads 1.2 7 Privacy 1.0 7)"
expect 1 "$(make_app build-differs 1.2 7 Ads 1.2 1 Privacy 1.2 7)"
expect 1 "$(make_app extension-lacks-version 1.2 7 Ads "" "")"
expect 1 "$(make_app app-lacks-version "" "" Ads 1.2 7)"
expect 1 "$(make_app unresolved-placeholder '$(MARKETING_VERSION)' 7 Ads '$(MARKETING_VERSION)' 7)"
expect 1 "$(make_app no-extensions 1.2 7)"
expect 2 "$work/missing.app"

[ "$failures" -eq 0 ] && echo "extension versions check: all cases passed"
exit "$failures"
