#!/usr/bin/env bash
set -euo pipefail

# With a UDID, checks it names an available simulator and prints it, so a session can test on
# the simulator it created (see "Each session tests on its own simulator" in docs/gotchas.md).
# Without one, prints the first available iPhone, as CI does.

xcrun simctl list devices available -j | python3 -c '
import json, sys

wanted = sys.argv[1] if len(sys.argv) > 1 else None
data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if (wanted and d["udid"] == wanted) or (not wanted and d["name"].startswith("iPhone")):
            print(d["udid"])
            sys.exit(0)

if wanted:
    print(f"no available iOS simulator has UDID {wanted}", file=sys.stderr)
sys.exit(1)
' "$@"
