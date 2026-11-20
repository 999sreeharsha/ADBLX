#!/bin/sh
# Runs the Release checks on the app being archived, so an archive fails without CI:
#   - no DNS Protection (check-release-no-dns.sh), and
#   - every extension at the app's version (check-extension-versions.sh).
# Runs as the app target's last build phase but acts only on archives (ACTION=install), like the
# recipient and key checks. It runs after the extensions are embedded and before Xcode signs the
# app, so the signature can't be read yet: the entitlements Xcode is about to sign with
# (CODE_SIGN_ENTITLEMENTS) are checked for the Network Extension entitlement instead.
# CI runs the same two scripts on its own Release build (.github/workflows/ci.yml).
[ "${ACTION:-}" = "install" ] || exit 0

dir=$(dirname "$0")
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
fail=0

"$dir/check-release-no-dns.sh" "$app" || fail=1
"$dir/check-extension-versions.sh" "$app" || fail=1

case "${CODE_SIGN_ENTITLEMENTS:-}" in
    "") entitlements="" ;;
    /*) entitlements="$CODE_SIGN_ENTITLEMENTS" ;;
    *) entitlements="${SRCROOT:?}/$CODE_SIGN_ENTITLEMENTS" ;;
esac
if [ -z "$entitlements" ] || [ ! -f "$entitlements" ]; then
    echo "error: can't read the entitlements this archive is signed with (CODE_SIGN_ENTITLEMENTS=${CODE_SIGN_ENTITLEMENTS:-unset})" >&2
    fail=1
elif grep -q "networkextension" "$entitlements"; then
    echo "error: this archive would be signed with the Network Extension entitlement ($entitlements)" >&2
    fail=1
fi

[ "$fail" = 0 ] && echo "ok: Release checks passed for $app"
exit "$fail"
