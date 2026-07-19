#!/usr/bin/env python3
"""PostToolUse guardrail: RuleCompiler/RulePartitioner/CompositionService
conformances must run off the main actor — this target defaults unannotated
declarations to @MainActor (SWIFT_DEFAULT_ACTOR_ISOLATION), so their protocol
methods require an explicit `nonisolated`. See docs/gotchas.md and the
Sprint 3A design/plan docs.

Heuristic, not a full parser: flags a `func compile(`, `func partition(`, or
`func compose(` line in an edited/created ADBLX/**/*.swift file that isn't
preceded by `nonisolated` on the same or immediately preceding line. False
positives are possible for unrelated same-named methods — read the flagged
line before assuming it's wrong.
"""
import json
import re
import sys

TARGET_METHODS = ("func compile(", "func partition(", "func compose(")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    file_path = payload.get("tool_input", {}).get("file_path", "")
    if not file_path.startswith("ADBLX/") and "/ADBLX/" not in file_path:
        return 0
    if not file_path.endswith(".swift") or file_path.endswith("Tests.swift"):
        return 0

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return 0

    flagged = []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if any(stripped.startswith(m) or f" {m}" in stripped for m in TARGET_METHODS):
            if "nonisolated" not in stripped:
                prev = lines[i - 1].strip() if i > 0 else ""
                if "nonisolated" not in prev:
                    flagged.append((i + 1, stripped))

    if flagged:
        details = "\n".join(f"  line {n}: {text}" for n, text in flagged)
        sys.stderr.write(
            f"guardrail: {file_path} has compile/partition/compose method(s) "
            f"without an explicit 'nonisolated':\n{details}\n"
            "RuleCompiler/RulePartitioner/CompositionService conformances must be "
            "nonisolated to run off @MainActor — see docs/gotchas.md.\n"
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
