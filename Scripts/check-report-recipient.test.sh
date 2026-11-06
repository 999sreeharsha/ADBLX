#!/bin/sh
# Checks check-report-recipient.sh against each form the recipient line can take.
dir=$(dirname "$0")
source=$(mktemp)
trap 'rm -f "$source"' EXIT
failures=0

expect() { # expected-exit action line
    printf '%s\n' "$3" > "$source"
    ACTION="$2" "$dir/check-report-recipient.sh" "$source" 2>/dev/null
    actual=$?
    if [ "$actual" -ne "$1" ]; then
        echo "FAIL: ACTION=$2 '$3' exited $actual, expected $1"
        failures=$((failures + 1))
    fi
}

expect 0 install '    static let recipient: String? = "reports@brand.app"'
expect 1 install '    static let recipient: String? = nil'
expect 1 install '    static let recipient: String? = ""'
expect 1 install '    static let recipient: String? = "not-an-address"'
expect 1 install '    static let recipient: String? = "reports@<brand-domain>"'
expect 1 install '    static let recipient: String? = "reports@example.org"'
expect 1 install '    static let recipient: String? = "someone+reports@gmail.com"'
expect 1 install '    static let recipient = Secrets.reportsAddress'
expect 1 install ''
expect 0 build '    static let recipient: String? = nil'
expect 0 '' '    static let recipient: String? = nil'

[ "$failures" -eq 0 ] && echo "report recipient check: all cases passed"
exit "$failures"
