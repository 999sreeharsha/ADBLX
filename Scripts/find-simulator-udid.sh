#!/usr/bin/env bash
set -euo pipefail

xcrun simctl list devices available -j | python3 -c '
import json, sys

data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d["name"].startswith("iPhone"):
            print(d["udid"])
            sys.exit(0)

sys.exit(1)
'
