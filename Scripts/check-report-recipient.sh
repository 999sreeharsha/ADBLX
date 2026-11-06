#!/bin/sh
# Stops an archive shipping without somewhere for broken site reports to go. Runs as a build
# phase but acts only on archives (ACTION=install), so everyday builds and tests don't need the
# address yet. A unit test can't do this: tests run in Debug. Anything this can't parse as a real
# address fails, so reformatting the line can't quietly switch the check off.
[ "${ACTION:-}" = "install" ] || exit 0

file="${1:-$SRCROOT/ADBLX/Features/BrokenSite/BrokenSiteModels.swift}"
address=$(sed -nE 's/^[[:space:]]*static let recipient: String\? = "([^"@ ]+@[^"@ ]+\.[^"@ ]+)"[[:space:]]*$/\1/p' "$file")

case "$address" in
    "" | *"<"* | *@example.* | *@gmail.com | *@googlemail.com)
        echo "error: Set BrokenSiteReport.recipient to a reports alias on the product's domain before archiving." >&2
        exit 1
        ;;
esac
