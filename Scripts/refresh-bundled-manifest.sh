#!/bin/sh
# Copies the live signed manifest and the bundled lists from the published site into
# ADBLX/Resources/Filters/, so the app's built-in minimum version keeps up with releases
# (docs/Security/ManifestTrust.md, Rollback). Run by hand before archiving; the archive
# fails if the bundled manifest is over 30 days old (Scripts/check-manifest-trust.sh).
#
# Nothing is copied unless the manifest's signature verifies against the keys pinned in
# ManifestTrust.swift and every list matches the manifest's checksum.
#
# Usage: Scripts/refresh-bundled-manifest.sh [base-url]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
base="${1:-https://999sreeharsha.github.io/ADBLX}"
trust="${MANIFEST_TRUST_FILE:-$root/ADBLX/Filtering/Updates/ManifestTrust.swift}"
filters="$root/ADBLX/Resources/Filters"
publisher="$root/backend/tools/Publisher"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
    echo "error: $1" >&2
    exit 1
}

fetch() { # url destination
    curl --fail --silent --show-error --proto '=https,file' --max-filesize 20000000 "$1" -o "$2" ||
        fail "Couldn't download $1."
}

keys=$(awk '/static let productionPublicKeys: \[String\] = \[/ { inside = 1; next }
            inside && /^[[:space:]]*\]/ { exit }
            inside' "$trust" | sed -nE 's#^[[:space:]]*"([A-Za-z0-9+/]{86}==)".*#\1#p')
[ -n "$keys" ] || fail "No production keys are pinned in $trust, so there's nothing to verify against."

fetch "$base/manifest.json" "$work/manifest.json"
digest=$(shasum -a 256 "$work/manifest.json" | cut -d ' ' -f 1)
mkdir "$work/signatures"
fetch "$base/signatures/$digest.sig" "$work/signatures/$digest.sig"

(cd "$publisher" && swift build --configuration release --quiet) || fail "Couldn't build the Publisher."
key_options=""
for key in $keys; do
    key_options="$key_options --public-key $key"
done
# shellcheck disable=SC2086 # one option and value per key
"$(cd "$publisher" && swift build --configuration release --show-bin-path)/Publisher" verify \
    --manifest "$work/manifest.json" --signatures "$work/signatures" $key_options ||
    fail "The live manifest's signature doesn't verify against the pinned keys."

count=$(plutil -extract entries raw -o - "$work/manifest.json")
found=""
i=0
while [ "$i" -lt "$count" ]; do
    id=$(plutil -extract "entries.$i.id" raw -o - "$work/manifest.json")
    group=$(plutil -extract "entries.$i.group" raw -o - "$work/manifest.json")
    checksum=$(plutil -extract "entries.$i.checksumSHA256" raw -o - "$work/manifest.json")
    i=$((i + 1))
    [ -f "$filters/$id.txt" ] || continue
    # The layout the app requires of every sourceURL (ManifestTrust.md, sourceURL).
    fetch "$base/filters/$group/$id.txt" "$work/$id.txt"
    [ "$(shasum -a 256 "$work/$id.txt" | cut -d ' ' -f 1)" = "$checksum" ] ||
        fail "$id.txt doesn't match the manifest's checksum."
    found="$found $id"
done

for list in "$filters"/*.txt; do
    id=$(basename "$list" .txt)
    case " $found " in
        *" $id "*) ;;
        *) fail "The bundled list $id isn't in the live manifest." ;;
    esac
done

cp "$work/manifest.json" "$filters/bundled-manifest.json"
for id in $found; do
    cp "$work/$id.txt" "$filters/$id.txt"
done
echo "✓ Bundled manifest $(plutil -extract manifestVersion raw -o - "$filters/bundled-manifest.json") and lists:$found"
