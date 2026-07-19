#!/usr/bin/env python3
"""PostToolUse guardrail: any test file that touches FilterStore shares the
same App Group container (group.com.ADBLX.shared) across parallel test runs
and must be a serialized suite. See docs/gotchas.md and the Sprint 3A plan's
Global Constraints.

Approximation: this codebase's convention is one @Suite per file, so this
checks file-wide presence of FilterStore(appGroupIdentifier: alongside
.serialized rather than parsing which @Suite a given reference falls under.
If a file ever holds multiple @Suite declarations with mixed FilterStore
usage, this hook's file-wide check is not precise enough — split the file
before splitting the check.
"""
import json
import re
import sys


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    file_path = payload.get("tool_input", {}).get("file_path", "")
    if "ADBLXTests/" not in file_path or not file_path.endswith(".swift"):
        return 0

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return 0

    touches_filter_store = "FilterStore(appGroupIdentifier:" in content
    has_suite = re.search(r"@Suite\(", content)
    if touches_filter_store and has_suite and ".serialized" not in content:
        sys.stderr.write(
            f"guardrail: {file_path} constructs FilterStore(appGroupIdentifier:) "
            "but its @Suite(...) doesn't include .serialized. Tests sharing the "
            "App Group container race when run in parallel — add .serialized to "
            "the @Suite attribute (see FilterPipelineTests.swift / "
            "UpdateCoordinatorTests.swift for the pattern). See docs/gotchas.md.\n"
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
