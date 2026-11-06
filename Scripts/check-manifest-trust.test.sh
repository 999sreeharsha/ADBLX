#!/bin/sh
# Checks check-manifest-trust.sh against each form the pinned-key list can take.
dir=$(dirname "$0")
trust=$(mktemp)
debug=$(mktemp)
trap 'rm -f "$trust" "$debug"' EXIT
failures=0

k1='sN62bob0fFo4DrKj51F8Yo4ptABPsgpntoTlX58UwswxQFgcDSXSIUgtxy1H29p6+d59IcFSvV9eoYXEcgrwkw=='
k2='kObOHjBnyHpXUs2trrvc5TCRSsGYhCyixqpoRmbFW9nU88rGKINFLmnGD/cqVmE+mMtxHZIU9EoBRKjNotrt2Q=='
test_key='AAAAbob0fFo4DrKj51F8Yo4ptABPsgpntoTlX58UwswxQFgcDSXSIUgtxy1H29p6+d59IcFSvV9eoYXEcgrwkw=='

expect() { # expected-exit action key-lines debug-key description
    printf '    static let productionPublicKeys: [String] = [\n%b    ]\n' "$3" > "$trust"
    printf '#if DEBUG\n    static let debugPublicKeys: [String] = ["%s"]\n#endif\n' "$4" > "$debug"
    ACTION="$2" "$dir/check-manifest-trust.sh" "$trust" "$debug" 2>/dev/null
    actual=$?
    if [ "$actual" -ne "$1" ]; then
        echo "FAIL: $5 (ACTION=$2) exited $actual, expected $1"
        failures=$((failures + 1))
    fi
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

[ "$failures" -eq 0 ] && echo "manifest trust check: all cases passed"
exit "$failures"
