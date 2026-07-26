# Sprint 7 Implementation Blueprint — Registry → Manifest Publisher

## Purpose

Sprint 6 froze the backend's architecture across four documents (Repository
layout, `FilterRegistry.md`, `ManifestSpecification.md`,
`ManifestGeneration.md`) but implemented nothing — no downloader, no
generator, no automation. This document is Sprint 7's implementation
contract: it answers *how* the registry → manifest publisher is built, not
*what* it must do (already frozen) or *whether* the backend architecture is
correct (already frozen).

This is not another architecture sprint. Every decision below is scoped to
implementation: technology choice, module structure, the registry's
machine-readable format, CLI shape, validation behavior, testing policy, and
logging/configuration. Once this document is approved, Sprint 7 is
considered fully planned — implementation should be largely mechanical.

## Technology choice

The publisher is a standalone Swift Package executable, matching the rest of
ADBLX (iOS app, filtering pipeline, update system, and manifest models are
all already Swift). This avoids introducing a second language/ecosystem
purely for tooling, runs identically on a developer's Mac, in GitHub Actions
(official Swift/Xcode-equipped macOS runners), and — since modern Swift runs
on Linux — on a future Linux scheduled runner, with no rewrite.

The publisher does not parse Markdown. Documentation is for humans; the
publisher consumes structured data (`backend/registry/filters.json`, defined
below) and *produces* Markdown as a generated artifact, never the reverse.

## Project and target structure

One Swift Package executable target — not a library + thin executable. There
is exactly one consumer today (the CLI itself); introducing a `PublisherKit`
library now would be speculative, contradicting the project's established
"don't introduce an abstraction until you have at least two consumers or a
demonstrated need" principle. The internal code is still organized like a
library, via folders and types, so extracting a library target later (if a
second consumer ever appears — e.g. a future macOS tool) is a mechanical
file-move, not a redesign. `main.swift` stays a thin entry point: parse
arguments, construct `Publisher`, run, exit.

```
backend/
└── tools/
    └── Publisher/
        ├── Package.swift
        ├── Sources/
        │   └── Publisher/
        │       ├── main.swift
        │       ├── CLI/
        │       ├── Registry/
        │       ├── Metadata/
        │       ├── Payload/
        │       ├── Manifest/
        │       ├── Documentation/
        │       ├── Validation/
        │       ├── Utilities/
        │       └── Models/
        └── Tests/
            └── PublisherTests/
```

Naming avoids "Service" (reserved in this codebase for long-lived runtime
components, e.g. the iOS app's services) and avoids "PublisherEngine" or
similar — the publisher is a batch process that runs and exits, so the type
is simply named `Publisher`, matching the executable name.

## Canonical registry: `backend/registry/filters.json`

### Architectural evolution, not a reversal

Sprint 6 correctly froze `docs/FilterRegistry.md` as the authoritative
registry, because no machine-readable representation existed and no
publisher consumed it yet. Sprint 7 introduces tooling, and tooling changes
the requirements: production code should not depend on Markdown table
formatting staying stable (a header rename like "Display name" → "Name"
would silently break a Markdown-parsing publisher, with nothing in Git or
Swift explaining why).

Sprint 7 therefore promotes `backend/registry/filters.json` to canonical
status. `FilterRegistry.md` becomes generated documentation derived from it.
This is documented explicitly as a two-phase evolution:

- **Phase 1 (Sprint 6, completed):** `FilterRegistry.md` was the
  human-authored, human-reviewed architecture contract — correct for a
  project with no publisher yet.
- **Phase 2 (Sprint 7):** `backend/registry/filters.json` becomes the
  canonical source; `FilterRegistry.md` becomes generated output.

There is only one hand-edited source going forward. Dual editing (hand-sync
JSON and Markdown independently) is explicitly rejected.

### Schema

```json
{
  "registryVersion": 1,
  "filters": [
    {
      "id": "easylist",
      "name": "EasyList",
      "upstreamProject": "EasyList",
      "upstreamDownloadURL": "https://easylist.to/easylist/easylist.txt",
      "license": "CC BY-SA 3.0 / GPLv3",
      "group": "ads",
      "enabledByDefault": true,
      "premium": false,
      "notes": null
    }
  ]
}
```

**Required per-entry fields:** `id`, `name`, `upstreamProject`,
`upstreamDownloadURL`, `license`, `group`, `enabledByDefault`, `premium`.
**Optional:** `notes`.

The registry is the **complete canonical record** of every registered
filter — not just the publisher's inputs. Even though the publisher today
only consumes `id`, `name`, `group`, `enabledByDefault`, `premium` (per
`ManifestGeneration.md`'s field-ownership table), provenance fields
(`upstreamProject`, `upstreamDownloadURL`, `license`) and `notes` are
first-class registry data, not documentation-only prose. This avoids
splitting the registry into a machine-readable subset plus a
human-only-maintained remainder, which would recreate the dual-source
problem this migration exists to eliminate. Future tooling (license
attribution generation, OSS compliance reports, About-screen content) can
consume these fields without a schema change.

Excluded from the registry, per the ownership model already frozen in
Sprint 6: `version` (owned by `backend/metadata/{id}.json`), `sourceURL`,
`checksumSHA256`, `ruleCount` (all derived/computed by the publisher, never
registry data).

### `registryVersion` semantics

`registryVersion` is a **schema compatibility guard** for the publisher, not
content metadata — it answers "can this publisher understand this file?",
not "what data snapshot is this?" (that question belongs to `manifestVersion`
in the manifest, whose meaning is deliberately different). If the value
doesn't match what the publisher supports, the command reports a clear
"unsupported registryVersion" error and terminates with exit code 2 — no
partial-compatibility migration logic.

**`registryVersion` changes only when the JSON schema itself changes in a
backward-incompatible way.** It does **not** change when filters are added,
removed, renamed, or when `notes`/`license`/any other field's content is
edited. Adding, removing, or editing filter entries is ordinary registry
content churn and never bumps this field.

### Future candidates live outside the registry

`filters.json` models the **current registry** — filters that are actually
registered — not roadmap or planning material. Today's "Future candidates"
table in `FilterRegistry.md` (AdGuard Base, SHIELD proprietary, Peter Lowe's,
`shield-india`, EasyList regional variants) does not belong in `filters.json`
in any form (no `candidates` array): candidates have no `id`, no
`enabledByDefault`/`premium` decisions, and sometimes no confirmed group —
forcing a second, looser schema into the registry file would blur "what
exists" with "what might exist later."

Instead, this content moves to a new, permanently hand-authored document,
`backend/docs/RegistryRoadmap.md`, containing future candidates, deferral
rationale, design discussion, and open questions. This keeps
`FilterRegistry.md` fully generatable with no "don't edit above this line"
wrinkle, and gives planning material its own home with its own audience.

## Generated vs. hand-authored file ownership

| Artifact | Ownership | Notes |
|---|---|---|
| `backend/registry/filters.json` | Hand-edited | The only editable registry source |
| `backend/metadata/{id}.json` | Hand-edited (for now) | Per-filter `version` sidecar; upstream-sync tooling may write this later (out of scope) |
| `backend/docs/RegistryRoadmap.md` | Hand-edited | Future candidates, rationale, planning notes |
| `backend/docs/FilterRegistry.md` | **Generated** | Never hand-edited once Sprint 7 lands |
| `backend/public/manifest.json` | **Generated** | Never hand-edited |

Generated artifacts must never be edited by hand. A future contributor
editing `FilterRegistry.md` directly is editing something that will be
silently overwritten on the next `generate-docs` run.

### Generated Markdown scope

`FilterRegistry.md`, once generated, contains:
- Title and a short static overview paragraph (fixed template, not
  per-run content).
- The registered-filters table (one row per `filters.json` entry, grouped
  by `group`).

It deliberately does **not** contain a generation timestamp — this project's
"pure function" determinism rule (below) means the file's content must
depend only on `filters.json`, not on wall-clock time.

`RegistryRoadmap.md` is the only hand-authored registry-adjacent document.

## Publisher pipeline

### `generate-docs`

```
generate-docs
│
├── Load registry (filters.json)
├── Validate registry schema (registryVersion, required fields, structural)
├── Generate FilterRegistry.md content
└── Write FilterRegistry.md
```

Reads only `filters.json`. No metadata, no payloads, no `--publish-base-url`.
Fast — usable immediately after editing the registry, before payloads or
metadata exist.

### `publish`

```
publish --publish-base-url <url>
│
├── Load registry (filters.json)
├── Validate registry schema
├── Load metadata (backend/metadata/{id}.json, one per registered filter)
├── Load payloads (backend/public/filters/{group}/{id}.txt)
├── Run semantic validation (registry ↔ metadata ↔ payload consistency)
├── Generate manifest (compute checksums, rule counts, derive sourceURL/manifestVersion)
└── Write manifest.json
```

Does not touch `FilterRegistry.md`. The manifest publisher never
unexpectedly rewrites documentation.

### `validate`

Runs the schema + semantic validation steps of `publish` (registry,
metadata, payload consistency) but writes nothing. Used before committing or
in CI as an isolated, fast-failing step.

### `generate`

Convenience command: `validate` → `generate-docs` → `publish`, in that
order. The typical day-to-day developer/CI invocation.

| Command | Purpose |
|---|---|
| `validate` | Verify registry, metadata, and payload consistency. Writes nothing. |
| `generate-docs` | Regenerate `FilterRegistry.md` from `filters.json`. |
| `publish --publish-base-url <url>` | Produce `manifest.json`. |
| `generate --publish-base-url <url>` | `validate` → `generate-docs` → `publish`. |

## Validation model

Two tiers, distinguished by whether the publisher can even understand its
inputs:

**Fatal errors** — stop immediately, no accumulation possible:
- `filters.json` cannot be opened or is malformed JSON.
- `registryVersion` is unsupported by this publisher build.

**Validation errors** — accumulated into a `ValidationReport`, every
independent check runs regardless of earlier failures, matching every
condition already frozen in `ManifestGeneration.md`:
- Registered filter has no corresponding `backend/metadata/{id}.json`.
- A metadata file's `id` doesn't match its filename.
- A metadata file's `id` doesn't correspond to any registered filter
  (orphaned).
- Duplicate metadata files for the same `id`.
- Derived payload path does not exist for a registered filter.
- Registry is empty (zero registered filters).
- A registry entry's `group` is not one of the four frozen values.
- Duplicate registry `id` values.

`validate` prints every discovered error in one run (compiler-style: "N
errors found", not one-at-a-time). `publish` always validates first and
writes nothing — no partial `manifest.json`, no partial `FilterRegistry.md`
— if the report contains any errors. This mirrors the transactional,
no-partial-success model `ManifestGeneration.md` already froze.

### Deterministic validation ordering

Validation errors are sorted by category, then alphabetically by filter
`id`, so every run over identical (broken) inputs produces byte-identical
error output:

```
Registry errors
↓
Metadata errors
↓
Payload errors
```

### Error output format

Human-readable, grouped by category, no stack traces, no Swift type names:

```
Validation failed (3 errors)

[Metadata]
- Missing backend/metadata/easyprivacy.json

[Registry]
- Invalid group "advertisements" for filter "easylist" (expected: ads|privacy|annoyances|regional)

[Payload]
- Missing backend/public/filters/privacy/easyprivacy.txt
```

## Determinism rules

Restated and frozen explicitly as an implementation requirement (already
established as a principle in `ManifestGeneration.md`, now made concrete
across every generated artifact):

- **Registry entries** are processed in ascending `id` order (ordinal string
  comparison) — never registry-document order or filesystem enumeration
  order.
- **Manifest entries** are sorted by `id`, ascending (already frozen in
  `ManifestGeneration.md`).
- **Generated Markdown table rows** follow the same ascending-`id` ordering,
  grouped by `group` in the fixed group order (Ads, Privacy, Annoyances,
  Regional) — this order is defined by the client's `FilterGroup` domain
  model, not by `filters.json`'s array order or alphabetical order, and must
  not be "simplified" to either of those later.
- The publisher reads `filters.json` as authored (entries may appear in any
  order in the file — contributors are not required to hand-sort it),
  validates it, then sorts internally before any processing or output. Sort
  order is the publisher's responsibility, never a constraint on how the
  registry is authored.
- **Validation output** is sorted by category then `id`, as above.
- Given identical inputs (`filters.json`, metadata files, payloads,
  `publishBaseURL`), every generated artifact (`manifest.json`,
  `FilterRegistry.md`) must be byte-identical across runs, regardless of
  machine or time — no wall-clock timestamps, no filesystem iteration order,
  no non-deterministic formatting enter any output.
- **Output locations are fixed:** generated artifacts are always written to
  `backend/public/manifest.json` and `backend/docs/FilterRegistry.md`. No
  CLI flag or configuration value overrides these paths in Sprint 7.
- **Writes are atomic:** each generated file is written to a temporary file
  and renamed into place, never written in place incrementally. This
  guarantees no partially-written artifact is ever observable at the output
  path, even if generation is interrupted mid-write — the same philosophy
  already used by the iOS app's own atomic-write pattern
  (`installed_filters.json`/`filter_preferences.json`/`allowlist.json`).

## Configuration

`publishBaseURL` is supplied **only** via the required CLI argument
`--publish-base-url`. No environment variable fallback, no config file, no
default value. Omitting it is a fatal CLI argument error. This is the single
deployment-varying input in the entire pipeline (per `ManifestGeneration.md`)
and doesn't carry secrets, so there's no security rationale for an env var —
one input, one supported mechanism, keeping CI workflows self-documenting
(the URL is visible directly in the workflow file, not hidden in a variable
lookup).

## Logging and exit codes

**Normal output** — human-readable progress:

```
Loading registry...
✓ Loaded 3 filters

Validating...
✓ Validation passed

Generating documentation...
✓ Wrote FilterRegistry.md

Generating manifest...
✓ Wrote manifest.json

Done.
```

**Error output** — structured, grouped by category (see Validation model
above). No verbose mode in Sprint 7 — deferred until a concrete need
justifies it.

| Exit code | Meaning |
|---|---|
| 0 | Success |
| 1 | Validation failure (semantic errors) |
| 2 | Fatal error (invalid CLI arguments, unsupported `registryVersion`, unreadable/malformed input) |

## Testing strategy

A pyramid weighted toward unit tests, with integration tests proving
composition rather than re-deriving logic:

```
                    Integration
                 (Publisher workflow)
                        ▲
              Cross-module golden tests
                        ▲
                 Module unit tests
```

### Module unit tests

One test suite per module: `RegistryTests`, `ValidationTests`,
`MetadataTests`, `ManifestTests`, `DocumentationTests`, `PublisherTests`
(workflow orchestration). `ManifestTests` and `DocumentationTests` are pure
transformations — no filesystem, no CLI — given a registry/metadata/payload
fixture in memory, assert the resulting manifest fields or Markdown content
directly.

**Every validation rule documented in `ManifestGeneration.md` gets its own
explicitly named test** in `ValidationTests` (e.g.
`testMissingMetadataFile()`, `testOrphanedMetadata()`,
`testDuplicateMetadata()`, `testMissingPayload()`, `testEmptyRegistry()`,
`testInvalidGroup()`, `testDuplicateRegistryID()`). This gives a direct,
grep-able mapping from documented rule to test — if a future edit adds a
failure condition to `ManifestGeneration.md`, a missing corresponding test
is an obvious gap in review.

### Golden-file integration tests

`PublisherIntegrationTests` builds a fixture `backend/`-like tree (fake
registry, metadata, payloads) and asserts generated output is **byte-
identical** to a committed golden file — not "contains EasyList" or "three
entries exist," but literal equality. This directly guards against the
transposition class of bug documented in `docs/gotchas.md` (set-equality
assertions can't catch a swapped key↔value pairing), since byte-identical
comparison against a golden file forces correct pairwise field mapping, not
just "all values appeared somewhere."

Both generated artifacts get golden-file coverage:
- `manifest.json` vs. a committed golden manifest.
- `FilterRegistry.md` vs. a committed golden Markdown file.

Golden fixtures live under `Tests/Fixtures/`:
```
Tests/Fixtures/golden-manifest.json
Tests/Fixtures/golden-filter-registry.md
```

### Batch-failure integration tests

Per `docs/gotchas.md`'s batch/transactional coverage lesson (a test that
only fails a batch's sole item doesn't exercise the case a rollback/no-
partial-output guarantee actually exists for), fixtures use 3+ registered
filters and test failure at each position:

- First filter fails (missing metadata) — filters 2 and 3 are otherwise
  valid.
- **Middle** filter fails — the position most likely to reveal accidental
  partial writes, since filters before it may have already been processed.
- Last filter fails.

Each asserts: validation reports the applicable error(s), `publish` exits
non-zero, and **no output files are written** — not `manifest.json`, not
`FilterRegistry.md`.

### Determinism tests

Run the publisher twice over identical fixture inputs; assert both
`manifest.json` and `FilterRegistry.md` outputs are byte-identical across
the two runs. Guards against filesystem iteration order, dictionary
ordering, or accidental timestamp leakage.

### Explicitly out of scope for Sprint 7

No property-based/fuzz testing — the registry schema and input sizes are
small, rules are structural rather than mathematical, and this would add
complexity without proportional confidence at this scale. Revisit only if
the publisher later manages a much larger, more complex registry.

## Explicitly not the publisher's responsibility

Restated from `ManifestGeneration.md`, unchanged by this blueprint:
downloading upstream filter lists, compiling filter payloads into Safari
Content Blocker JSON, publishing to GitHub/CDN or cache invalidation,
scheduling when generation runs, and writing/updating
`backend/metadata/{id}.json` (the publisher only reads it).

## Deliverables (Sprint 7 planning)

- This design document, committed to
  `docs/superpowers/specs/2026-07-26-sprint7-publisher-implementation-blueprint-design.md`.
- No implementation code yet — this is the contract; implementation follows
  via a separate written plan (`writing-plans` skill).
