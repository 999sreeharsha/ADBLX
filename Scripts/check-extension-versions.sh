#!/bin/sh
# Fails unless every extension embedded in a built .app has the app's CFBundleShortVersionString
# and CFBundleVersion. App Store Connect rejects an upload whose extensions differ, so a version
# bump that misses one shows up only at upload time. Run it on a Release build.
# usage: check-extension-versions.sh path/to/ADBLX.app
app="${1:?usage: $0 path/to/ADBLX.app}"
[ -d "$app" ] || { echo "error: $app is not a directory" >&2; exit 2; }
fail=0

value() { # plist key
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

short=$(value "$app/Info.plist" CFBundleShortVersionString)
build=$(value "$app/Info.plist" CFBundleVersion)
case "$short$build" in
    *'$('*) echo "error: app version is an unexpanded build setting ($short / $build)" >&2; exit 1 ;;
esac
if [ -z "$short" ] || [ -z "$build" ]; then
    echo "error: app Info.plist lacks CFBundleShortVersionString or CFBundleVersion" >&2; exit 1
fi

found=0
for appex in "$app"/PlugIns/*.appex; do
    [ -d "$appex" ] || continue
    found=1
    name=$(basename "$appex")
    ext_short=$(value "$appex/Info.plist" CFBundleShortVersionString)
    ext_build=$(value "$appex/Info.plist" CFBundleVersion)
    if [ "$ext_short" != "$short" ] || [ "$ext_build" != "$build" ]; then
        echo "error: $name is ${ext_short:-<none>} (${ext_build:-<none>}), app is $short ($build)" >&2; fail=1
    fi
done
[ "$found" = 1 ] || { echo "error: $app embeds no extensions" >&2; exit 1; }
[ "$fail" = 0 ] && echo "ok: every extension is version $short ($build) in $app"
exit "$fail"
