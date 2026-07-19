#!/usr/bin/env python3
"""PostToolUse guardrail: this project uses Swift Testing exclusively
(@Suite/@Test/#expect) in ADBLXTests/ — no XCTest. See docs/gotchas.md and
the Sprint 3A plan's Global Constraints.

Flags (does not silently fix) any edited/created file under ADBLXTests/
that contains an XCTest import or XCTAssert-family call.
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

    if re.search(r"\bimport\s+XCTest\b", content) or re.search(r"\bXCTAssert\w*\(", content):
        sys.stderr.write(
            f"guardrail: {file_path} uses XCTest (import XCTest / XCTAssert*). "
            "This project uses Swift Testing exclusively (@Suite, @Test, #expect) "
            "in ADBLXTests/ — see docs/gotchas.md. Rewrite using Swift Testing.\n"
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
