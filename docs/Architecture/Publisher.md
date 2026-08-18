# Publisher (backend registry → manifest tool)

**Status:** current as of Sprint 7. Living document — update in place as the
tool's modules, CLI surface, or file contracts change. For the "why" behind
the manual JSON writer, see `docs/ADR/0001-manifest-json-manual-writer.md`.

## What it is

`backend/tools/Publisher` is a standalone Swift Package executable
(`Publisher`) — not part of the iOS app's Xcode project or any app target.
It reads the backend's filter registry and per-filter data, validates them,
and produces the two artifacts the iOS app and any future backend consumer
read: `backend/public/manifest.json` and `backend/docs/FilterRegistry.md`.

Build/run from the repository root:

```bash
cd backend/tools/Publisher && swift build
cd /path/to/repo-root
swift run --package-path backend/tools/Publisher publisher <subcommand>
```

## Inputs and outputs

| Path | Role |
|---|---|
| `backend/registry/filters.json` | Canonical registry — the source of truth for which filters exist, their group, and their default/premium flags. |
| `backend/metadata/{id}.json` | One file per filter: `{"id": ..., "version": "YYYY-MM-DD"}`. |
| `backend/public/filters/{group}/{id}.txt` | The actual filter-list payload for each registered filter. |
| `backend/public/manifest.json` | **Generated.** Consumed by the iOS app's update pipeline. |
| `backend/docs/FilterRegistry.md` | **Generated.** Human-readable mirror of the registry, grouped Ads/Privacy/Annoyances/Regional. |
| `backend/docs/RegistryRoadmap.md` | Hand-authored, never generated — filters under consideration, not yet registered. |

None of the input/output paths are configurable in Sprint 7 — the tool
assumes it is invoked from the repository root.

## CLI surface

```
publisher validate                                    # validate only
publisher generate-docs                                # regenerate FilterRegistry.md
publisher publish --publish-base-url <url>              # validate, then write manifest.json
publisher generate --publish-base-url <url>              # validate → generate-docs → publish
```

Exit codes: `0` success, `1` validation failure, `2` fatal error (unreadable
or malformed JSON, unsupported `registryVersion`).

`--publish-base-url` is CLI-only — required, no environment variable, no
config file, no default. It becomes the prefix for every entry's
`sourceURL`.

## Module layout

One executable target with folder-based internal modularity, built
bottom-up (each module only depends on modules before it in this list):

- **Models** (`Registry`, `FilterMetadata`, `Manifest`/`ManifestEntry`) —
  plain `Codable`/`Equatable` structs, no behavior.
- **Registry** (`RegistryLoader`) — reads and decodes `filters.json`, checks
  `registryVersion` compatibility. Fatal errors only (unreadable/malformed
  file, unsupported version) — no semantic validation here.
- **Metadata** (`MetadataLoader`) — reads every `backend/metadata/*.json`
  file, returns `[(filename, FilterMetadata)]` pairs. Pure loading, no
  cross-referencing against the registry.
- **Payload** (`PayloadReader`) — reads a filter's `.txt` payload, computes
  its SHA-256 checksum (lowercase hex, no prefix — matches the iOS app's
  `Checksum.sha256Hex`) and rule count (non-empty, non-`!`-comment lines).
- **Validation** (`ValidationError`, `ValidationReport`, `Validator`) — the
  only module that cross-references registry, metadata, and payload.
  `Validator.validate(registry:metadataDirectory:payloadDirectory:)` is the
  single entry point every CLI command calls; it accumulates every error
  found (empty registry, invalid/duplicate registry id, missing/orphaned/
  duplicate metadata, metadata id/filename mismatch, missing payload) into
  one `ValidationReport`, sorted by category (Registry → Metadata →
  Payload) then by id. Nothing downstream ever sees a partial or
  first-error-only report.
- **Manifest** (`ManifestBuilder`, `ManifestJSONWriter`) — `ManifestBuilder`
  combines already-loaded `Registry`/`FilterMetadata`/`PayloadInfo` into a
  `Manifest` (field ownership: `id`/`name`/`group`/`enabledByDefault`/
  `premium` from the registry, `version` from metadata, `checksumSHA256`/
  `ruleCount` from the payload, `sourceURL` derived, `manifestVersion` =
  lexical max of all entry versions), sorted ascending by id. It is pure
  combination logic — no filesystem access. `ManifestJSONWriter` serializes
  the result to the spec-mandated JSON shape via manual string
  construction rather than `JSONEncoder` — see
  `docs/ADR/0001-manifest-json-manual-writer.md` for why.
- **Documentation** (`MarkdownGenerator`) — renders `Registry` into
  `FilterRegistry.md`'s Markdown, grouped in fixed order (Ads, Privacy,
  Annoyances, Regional — from the domain's `FilterGroup` model, not
  alphabetical), sorted ascending by id within each group. Pure
  string-building, no filesystem access.
- **Utilities** (`AtomicFileWriter`) — writes a file atomically: temp file
  in the same directory as the destination, `F_FULLFSYNC`, then
  `FileManager.replaceItemAt`. Mirrors `ADBLX/Filtering/Storage/
  AtomicRuleWriter.swift`'s pattern (a standalone reimplementation, since
  that file lives in the iOS app target and can't be imported here).
- **CLI** (`PublisherCommand`, `PublisherPipeline`, and one file per
  subcommand under `CLI/Commands/`) — argument parsing (swift-argument-
  parser) and command wiring only. `PublisherPipeline.loadAndValidate()` is
  the one shared load+validate sequence every subcommand that needs it
  calls, so the sequence itself is defined once.

## Determinism and safety invariants

- `publish` never writes any output if validation reports errors — the
  `guard report.isValid else { throw ... }` check in `PublishCommand.run()`
  runs before any manifest-building or file-writing code.
- Both generated files are written atomically (`AtomicFileWriter`) — a
  crash or interruption mid-write can never leave a corrupt or partial
  `manifest.json`/`FilterRegistry.md` on disk.
- Running the full pipeline twice on identical inputs must produce
  byte-identical output. This is why `ManifestJSONWriter` exists instead of
  `JSONEncoder` (see the linked ADR) and why `MarkdownGenerator` never
  iterates an unordered collection to build its output.

## Known gaps (tracked, not yet closed)

- No end-to-end test invokes the actual CLI binary — integration tests
  (`PublisherIntegrationTests.swift`) exercise the internal pipeline
  functions directly, not `PublishCommand`/`GenerateCommand` through
  `ArgumentParser`. `PublisherPaths` is a hardcoded enum of process-relative
  paths with no injection seam, which is what currently blocks a true
  CLI-level test.
- `generate` re-runs registry load+validate twice (once via its own
  `validate` step, once inside `publish`'s internal guard) — harmless at
  the registry's current size, but worth collapsing if load ever becomes
  expensive.

## Production hosting: GitHub Pages, `gh-pages` branch of this repo

The production manifest is served from a `gh-pages` branch of this same
ADBLX repository (not a separate repo) via GitHub Pages:

- Manifest: `https://harshaunofficial.github.io/ADBLX/manifest.json`
- Filters: `https://harshaunofficial.github.io/ADBLX/filters/<group>/<id>.txt`

This is a deployment decision, not an architectural one — the only place
this URL is expressed in application code is `AppManifestEndpointProvider`
(`ADBLX/AppCompositionRoot.swift`). If hosting later moves (custom domain,
CDN), only that one `let` changes.

## Deploying: `backend/tools/publish-pages.sh`

After running `Publisher publish` above, deploy the result:

```bash
./backend/tools/publish-pages.sh
```

The script is intentionally "dumb" — it copies whatever exists under
`backend/public/` to the `gh-pages` branch verbatim, with no knowledge of
filter groups, manifest structure, or versions. `Publisher` produces the
artifact; `publish-pages.sh` deploys it — keep that separation when editing
either.

It maintains a **persistent worktree at `.gh-pages-worktree/`**, checked out
to the `gh-pages` branch, so it never disturbs your active branch or working
tree. **This directory is intentional and persistent — do not delete it** as
part of routine cleanup; it is recreated automatically if removed, but doing
so forces a full re-fetch on the next publish.

The script is self-bootstrapping and idempotent:

- If `origin/gh-pages` doesn't exist yet, it creates it as an orphan branch
  (no shared history with `main`/`dev`) and pushes it, before creating the
  worktree.
- If run again with no content changes, it prints `No changes to publish.`
  and exits `0` without creating an empty commit.

## First-time production setup (operational, one-time)

These steps are performed by the repository owner, not automated by this
script:

1. Run `Publisher publish --publish-base-url https://harshaunofficial.github.io/ADBLX`.
2. Run `./backend/tools/publish-pages.sh` to push the first `gh-pages` commit.
3. In GitHub repo Settings → Pages, set the source to the `gh-pages` branch, root.
4. Verify `https://harshaunofficial.github.io/ADBLX/manifest.json` is reachable over HTTPS.
