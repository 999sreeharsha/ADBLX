# 0001 — Publisher writes manifest.json with a manual writer, not JSONEncoder

**Date:** 2026-07-27
**Status:** Accepted

## Context

`backend/tools/Publisher`'s `publish` command must produce
`backend/public/manifest.json` with a fixed, spec-mandated key order per
entry (`id`, `name`, `group`, `sourceURL`, `version`, `checksumSHA256`,
`ruleCount`, `enabledByDefault`, `premium`) and at the top level
(`manifestVersion`, `entries`) — see `backend/docs/ManifestSpecification.md`.
The output must also be byte-identical across runs given identical inputs
(determinism is a hard requirement of the publish pipeline).

During Sprint 7 Task 10 (integration tests), encoding a `Manifest` value with
Foundation's `JSONEncoder` and `.prettyPrinted` was found to **not** reliably
preserve `Codable` struct declaration order on this project's Swift 6.3
toolchain (`swiftlang-6.3.3.1.3`, macOS 26, arm64): encoding the same value
via a standalone script five times in a row produced a different key order
in four of the five runs (`Dictionary`-backed, per-process hash-seed
ordering, not declaration order). `JSONEncoder.outputFormatting =
[.sortedKeys]` fixes the determinism problem but forces alphabetical key
order, which does not match the spec.

## Decision

`backend/tools/Publisher/Sources/Publisher/Manifest/ManifestJSONWriter.swift`
serializes `Manifest` to JSON via manual string construction — the same
pattern `MarkdownGenerator` (Task 8) already uses for
`backend/docs/FilterRegistry.md` — rather than `Codable`/`JSONEncoder`. It:

- Emits exactly the spec-mandated key order, both per-entry and top-level.
- Does not re-sort `entries` — `ManifestBuilder` owns sort order upstream;
  the writer serializes whatever order it's given.
- Leaves forward slashes unescaped (`JSONEncoder`'s default `\/` escaping
  does not match `ManifestSpecification.md`'s literal example).
- Is deterministic by construction: no hash-seeded collection drives output
  order anywhere in the writer.

`PublishCommand` calls `ManifestJSONWriter.write(manifest)` and passes the
result to `AtomicFileWriter`. No production code path in Publisher uses
`JSONEncoder` to produce `manifest.json`.

## Consequences

- Adding a field to `Manifest`/`ManifestEntry` requires a matching, manual
  edit to `ManifestJSONWriter` — the compiler will not catch a forgotten
  field the way `Codable`'s auto-synthesis would. `ManifestJSONWriterTests`
  is the safety net; keep it in sync with the model.
- Any future golden/snapshot test against Publisher's real JSON output must
  drive it through `ManifestJSONWriter`, not `JSONEncoder` — an earlier draft
  of Task 10's golden-manifest integration test used `JSONEncoder` with
  `.sortedKeys` as a stopgap (predating this writer's existence) and had to
  be corrected after the fact to call the real writer once it landed. See
  `docs/gotchas.md` for the general pitfall this created.
- If a future Swift/Foundation release fixes `JSONEncoder`'s key-order
  non-determinism, revisit this ADR — the manual writer would still work,
  but the tradeoff that motivated it (hand-maintained serialization code vs.
  encoder configuration) would need re-evaluating. A reversed decision gets
  a new ADR that supersedes this one, not an edit to this file.
