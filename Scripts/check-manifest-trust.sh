#!/bin/sh
# Stops an archive shipping an app that can't verify filter manifests: it needs both pinned
# production keys (K1 and K2, docs/Security/ManifestTrust.md), and never the Debug test key.
# Runs as a build phase but acts only on archives (ACTION=install), so everyday builds and
# tests don't need the keys yet. Any line in the list that isn't a key or a comment fails, so
# reformatting the list can't quietly switch the check off.
[ "${ACTION:-}" = "install" ] || exit 0

trust="${1:-$SRCROOT/ADBLX/Filtering/Updates/ManifestTrust.swift}"
debug="${2:-$SRCROOT/ADBLX/Filtering/Updates/ManifestTrust+Debug.swift}"
manifest="${3:-$SRCROOT/ADBLX/Resources/Filters/bundled-manifest.json}"

fail() {
    echo "error: $1 See docs/Security/ManifestTrust.md (Keys)." >&2
    exit 1
}

# A raw P-256 public key is 64 bytes: 86 base64 characters and "==".
key='"[A-Za-z0-9+/]{86}=="'

block=$(awk '/static let productionPublicKeys: \[String\] = \[/ { inside = 1; next }
             inside && /^[[:space:]]*\]/ { exit }
             inside' "$trust")
entries=$(printf '%s\n' "$block" | grep -Ev '^[[:space:]]*(//.*)?$')

if printf '%s\n' "$entries" | grep -Ev "^[[:space:]]*$key[[:space:]]*,?[[:space:]]*(//.*)?\$" | grep -q .; then
    fail "ManifestTrust.productionPublicKeys has a line that isn't a quoted base64 P-256 public key."
fi

keys=$(printf '%s\n' "$entries" | sed -nE 's/^[[:space:]]*"([^"]+)".*/\1/p')
count=$(printf '%s\n' "$keys" | grep -c .)
distinct=$(printf '%s\n' "$keys" | sort -u | grep -c .)
if [ "$distinct" -lt 2 ] || [ "$count" -ne "$distinct" ]; then
    fail "Pin both production public keys, K1 and K2, in ManifestTrust.productionPublicKeys before archiving."
fi

# Test keys that must never be pinned: the Debug list's, and the one committed with
# ManifestVerifierTests' PublisherFixture (its private half was deleted, but it is the key
# most likely to be pasted here by mistake).
fixture_key='sN62bob0fFo4DrKj51F8Yo4ptABPsgpntoTlX58UwswxQFgcDSXSIUgtxy1H29p6+d59IcFSvV9eoYXEcgrwkw=='
for test_key in $(grep -oE "$key" "$debug" 2>/dev/null | tr -d '"') "$fixture_key"; do
    if printf '%s\n' "$keys" | grep -qxF "$test_key"; then
        fail "A test key is in ManifestTrust.productionPublicKeys."
    fi
done

# The bundled manifest's version is the oldest manifest the app accepts, so a stale one
# weakens fresh installs' protection against rollback with every release.
version=$(sed -nE 's/^[[:space:]]*"manifestVersion":[[:space:]]*"([^"]*)".*/\1/p' "$manifest" 2>/dev/null)
case "$version" in
    ????-??-??) version="${version}T00:00:00Z" ;;
esac
published=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$version" +%s 2>/dev/null) ||
    fail "Can't read the bundled manifest's version. Run Scripts/refresh-bundled-manifest.sh."
now="${MANIFEST_TRUST_NOW:-$(date -u +%s)}"
if [ $((now - published)) -gt $((30 * 86400)) ]; then
    fail "The bundled manifest is over 30 days old. Run Scripts/refresh-bundled-manifest.sh before archiving."
fi
exit 0
