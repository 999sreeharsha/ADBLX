#!/bin/sh
# Checks check-manifest-trust.sh against each form the pinned-key list can take.
dir=$(dirname "$0")
trust=$(mktemp)
debug=$(mktemp)
manifest=$(mktemp)
trap 'rm -f "$trust" "$debug" "$manifest"' EXIT
failures=0
# 2026-11-07T00:00:00Z, so the bundled manifest's age doesn't depend on when this runs.
export MANIFEST_TRUST_NOW=1794009600
fresh='  "manifestVersion": "2026-11-06T09:30:00Z",'

k1='sN62bob0fFo4DrKj51F8Yo4ptABPsgpntoTlX58UwswxQFgcDSXSIUgtxy1H29p6+d59IcFSvV9eoYXEcgrwkw=='
k2='kObOHjBnyHpXUs2trrvc5TCRSsGYhCyixqpoRmbFW9nU88rGKINFLmnGD/cqVmE+mMtxHZIU9EoBRKjNotrt2Q=='
test_key='AAAAbob0fFo4DrKj51F8Yo4ptABPsgpntoTlX58UwswxQFgcDSXSIUgtxy1H29p6+d59IcFSvV9eoYXEcgrwkw=='

expect() { # expected-exit action key-lines debug-key description [manifest-version-line]
    printf '    static let productionPublicKeys: [String] = [\n%b    ]\n' "$3" > "$trust"
    printf '#if DEBUG\n    static let debugPublicKeys: [String] = ["%s"]\n#endif\n' "$4" > "$debug"
    printf '{\n%s\n  "entries": []\n}\n' "${6-$fresh}" > "$manifest"
    ACTION="$2" "$dir/check-manifest-trust.sh" "$trust" "$debug" "$manifest" 2>/dev/null
    actual=$?
    if [ "$actual" -ne "$1" ]; then
        echo "FAIL: $5 (ACTION=$2) exited $actual, expected $1"
        failures=$((failures + 1))
    fi
}

expect_age() { # expected-exit manifest-version-line description
    expect "$1" install "        \"$k1\", // K1\n        \"$k2\", // K2\n" "$test_key" "$3" "$2"
}

expect 0 install "        \"$k1\", // K1\n        \"$k2\", // K2\n" "$test_key" "two production keys"
expect 0 install "        \"$k1\", // K1\n        \"$k2\"\n" "" "no debug key, last entry without a comma"
expect 1 install "        \"$k1\", // K1\n" "$test_key" "one key"
expect 1 install "" "$test_key" "no keys"
expect 1 install "        // \"$k1\", // K1\n        // \"$k2\", // K2\n" "$test_key" "keys commented out"
expect 1 install "        \"$k1\", // K1\n        \"$k1\", // K2\n" "$test_key" "the same key twice"
expect 1 install "        \"$k1\", // K1\n        \"${k2%==}\", // K2\n" "$test_key" "a key that isn't 64 bytes"
expect 1 install "        \"$k1\", // K1\n        Secrets.k2, // K2\n" "$test_key" "a line that isn't a key"
expect 1 install "        \"$k1\", // K1\n        \"$test_key\", // K2\n" "$test_key" "the Debug test key in the production list"
expect 0 build "" "$test_key" "no keys in an everyday build"
expect 0 '' "" "$test_key" "no keys with no action"

expect_age 0 '  "manifestVersion": "2026-10-08T00:00:00Z",' "a bundled manifest 30 days old"
expect_age 0 '  "manifestVersion": "2026-11-05",' "a recent date-only bundled manifest"
expect_age 1 '  "manifestVersion": "2026-10-07T23:59:59Z",' "a bundled manifest over 30 days old"
expect_age 1 '  "manifestVersion": "2026-10-01",' "an old date-only bundled manifest"
expect_age 1 '  "manifestVersion": "soon",' "a bundled manifest version that isn't a date"
expect_age 1 '' "a bundled manifest with no version"
expect_age 0 "$fresh" "valid keys and a fresh manifest, before the missing-manifest case"
if ACTION=install "$dir/check-manifest-trust.sh" "$trust" "$debug" "$manifest.missing" 2>/dev/null; then
    echo "FAIL: no bundled manifest (ACTION=install) exited 0, expected 1"
    failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] && echo "manifest trust check: all cases passed"
exit "$failures"
