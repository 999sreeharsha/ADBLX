# ADBLX Manifest Generation (v1)

## Purpose

This document freezes how `backend/public/manifest.json` (specified field-
by-field in `docs/ManifestSpecification.md`) is produced from
`backend/registry/filters.json` and the published filter payloads. It is a design
document — it defines the pipeline's inputs, outputs, ownership, and failure
rules. It does not implement the generator.

Guiding principle: **the generator is a pure function.** Given identical
inputs (registry, metadata files, published payloads, and one deployment
`publishBaseURL`), it must always produce byte-identical output. No wall-
clock time, filesystem timestamps, or manually-typed per-run values ever
enter the manifest.

Commit 4 answers:

- What are the generator's inputs, and what owns each manifest field.
- The `backend/metadata/{id}.json` sidecar shape that supplies each filter's
  `version`.
- How `sourceURL` and `manifestVersion` are derived rather than configured.
- Deterministic generation rules (ordering, formatting).
- Failure conditions.

Commit 4 deliberately does not answer:

- The generator's implementation language/tooling (`backend/tools/`,
  later commit).
- How upstream filter lists are fetched or how `backend/metadata/{id}.json`
  gets its `version` value written in the first place (later upstream-sync
  work — this document assumes that file already exists and is correct by
  the time generation runs).
- GitHub Actions / CI wiring.
- Filter compilation or download-client behavior (already specified
  elsewhere: `FilterPipeline`, `FilterDownloadClient`).

## Inputs

1. `backend/registry/filters.json` — which filters are registered, their `id`,
   `name`, `group`, `enabledByDefault`, `premium` (canonical registry input;
   `docs/FilterRegistry.md` is a generated output, not an input).
2. `backend/metadata/{id}.json` — one file per registered filter, supplying
   that filter's `version` (defined below).
3. `backend/public/filters/{group}/{id}.txt` — the published payload used to
   compute `checksumSHA256` and `ruleCount`.
4. `publishBaseURL` — a single deployment-level configuration value (e.g.
   `https://cdn.adblx.com`), not part of the repository's committed data.
   The only input that legitimately varies by deployment.

## Output

`backend/public/manifest.json`, matching `docs/ManifestSpecification.md`
exactly. It is not signed yet.

`publisher sign` then writes `backend/public/signatures/<sha256>.sig`, an
Ed25519 signature over the manifest's exact bytes, named after their SHA-256,
with a key kept outside the repository. Earlier signatures stay, for devices
whose CDN edge still serves an older manifest. Signatures are randomized, so
the `.sig` file differs between runs even though the manifest doesn't. See `docs/Security/ManifestTrust.md` for the
commands, keys and what the app checks.

## `backend/metadata/{id}.json` — per-filter metadata sidecar

One JSON file per registered filter:

```text
backend/metadata/easylist.json
backend/metadata/easyprivacy.json
backend/metadata/fanboy-annoyances.json
```

Minimal v1 shape:

```json
{
  "id": "easylist",
  "version": "2026-07-15"
}
```

- `id` — must exactly match both the filename (`{id}.json`) and the
  registry's Internal ID. Redundant with the filename by design: it gives
  the file an internal identity so a misnamed or copy-pasted file is
  detectable rather than silently mismatched.
- `version` — date-based (`YYYY-MM-DD`), matching `ManifestSpecification.md`'s
  `Entry.version` format. This is the authoritative source of that field —
  the generator copies it verbatim into the manifest entry. Where this value
  comes from (manual edit today, upstream-sync tooling later) is out of
  scope for this document; generation only requires that the file already
  exists and is correct.

This shape is intentionally minimal but extensible. Later commits may add
fields (e.g. `upstreamRevision`, `downloadedAt`, `sourceChecksum`,
`statistics`) without changing the overall structure or breaking the
generator's contract, since the generator only reads `id` and `version` in
v1.

## Field ownership

| Manifest field | Source |
|---|---|
| `id` | Registry |
| `name` | Registry |
| `group` | Registry |
| `enabledByDefault` | Registry |
| `premium` | Registry |
| `version` | `backend/metadata/{id}.json` |
| `checksumSHA256` | Generated exactly as specified in `ManifestSpecification.md` — SHA-256 of `backend/public/filters/{group}/{id}.txt` |
| `ruleCount` | Generated — number of rules represented by the published payload at `backend/public/filters/{group}/{id}.txt`, using the same counting methodology as the eventual publisher implementation |
| `sourceURL` | Derived — see below |
| `manifestVersion` | Derived — see below |

No field is manually typed per publish run. The only human-supplied value in
the entire pipeline is `publishBaseURL`, and it is supplied once per
deployment, not once per filter or per publish.

### `sourceURL` derivation

```text
sourceURL = publishBaseURL
          + "/filters/"
          + <group>
          + "/"
          + <id>
          + ".txt"
```

`backend/public/` is the deployed tree: `publish-pages.sh` copies its contents
verbatim to the root of the gh-pages site, so a payload at
`backend/public/filters/ads/easylist.txt` is served at
`<publishBaseURL>/filters/ads/easylist.txt`. The repo path
(`backend/public`) therefore never appears in a `sourceURL`. This is pinned by
`ManifestTests` (the builder) and `CommittedManifestTests` (the committed
`manifest.json`).

`group` and `id` come from the registry; the path structure is fixed by
Commit 1's frozen directory layout; `.txt` is a fixed convention for v1 (all
registered v1 filters — EasyList, EasyPrivacy, Fanboy Annoyances — are
plain-text lists). If the derived path does not exist under
`backend/public/filters/`, generation fails (see Failure conditions).

### `manifestVersion` derivation

```text
manifestVersion = max(entry.version for entry in entries)
```

Lexical comparison, valid because `version` is fixed-format `YYYY-MM-DD`.
`manifestVersion` therefore only advances when at least one entry's own
version advances — publishing with unchanged inputs produces an unchanged
`manifestVersion`, and by extension a byte-identical `manifest.json`.

**To change before the app verifies signatures:** removing a list or changing a
name or premium flag keeps the same `manifestVersion`, so the app's rollback
rule can't tell the new manifest from a replayed old one. The planned format is
a UTC timestamp supplied to `publish`; see `docs/Security/ManifestTrust.md`
(Rollback).

## Determinism rule

> Given identical registry content, identical `backend/metadata/{id}.json`
> files, identical published payloads, and the same `publishBaseURL`,
> generation MUST produce byte-identical `manifest.json` output, regardless
> of when or on what machine it runs.

This is what makes generation safe to run in CI, safe to diff in review, and
safe to use as a reproducibility/regression check (re-running generation
against an unchanged `backend/` tree should produce a no-op diff).

## Deterministic generation rules

- **Entry ordering:** entries sorted by `id`, ascending, ordinal string
  comparison. Not filesystem enumeration order, not registry document order.
- **JSON formatting:** pretty-printed, UTF-8, LF line endings, stable key
  order (the order fields are listed in `ManifestSpecification.md`'s Entry
  table). Two generation runs over identical inputs must be byte-identical,
  not merely semantically equal.
- **Write:** single atomic write of `manifest.json`. No partial or
  intermediate manifest is ever visible at the output path.

## Validation and failure conditions

The generator validates a one-to-one correspondence between the registry,
metadata, and published payload before producing any output. Generation
fails (produces no output, leaves any existing `manifest.json` untouched)
if any of the following are true:

- A registered filter (per `backend/registry/filters.json`) has no
  corresponding `backend/metadata/{id}.json` file.
- A `backend/metadata/{id}.json` file exists whose `id` field does not match
  its filename.
- A `backend/metadata/{id}.json` file exists whose `id` does not correspond
  to any registered filter in `backend/registry/filters.json`.
- Duplicate metadata files for the same `id` (e.g. case-variant filenames on
  a case-insensitive filesystem).
- The derived payload path `backend/public/filters/{group}/{id}.txt` does
  not exist for a registered filter.
- The registry is empty (zero registered filters) — an empty manifest is
  never a valid publish output.
- A registry entry's `group` is not one of the four values frozen by
  `docs/FilterRegistry.md` / the client's `FilterGroup` enum.

There is no partial-success mode: any single failure aborts the entire
generation run. This mirrors the "batch/transactional" caution already
documented in `docs/gotchas.md` — a manifest is either fully valid or not
published at all, never a partially-populated document.

## Explicitly not the generator's responsibility

- Downloading upstream filter lists.
- Compiling filter payloads into Safari Content Blocker JSON.
- Publishing to GitHub / CDN, or invalidating any cache.
- Scheduling when generation runs.
- Writing or updating `backend/metadata/{id}.json` — generation only reads
  it.

## Performance considerations (for the eventual implementation)

- **Main thread:** N/A — backend tooling, not iOS runtime code.
- **Memory:** stream/hash payload files rather than loading unnecessarily
  large files wholesale where practical; v1 payload sizes (tens of thousands
  of rules of plain text) are small enough that this is not yet a hard
  constraint.
- **Disk I/O:** sequential reads of metadata and payload files per
  registered filter, followed by one atomic write of `manifest.json`.
- **Network:** none — generation operates entirely on local repository
  files plus the single configured `publishBaseURL` string.
- **Concurrency:** per-filter metadata/payload validation is independent
  across filters, so parallelizing generation across filters is safe if
  ever needed — not required at v1's scale (3 registered filters).

## Deliverables (this commit)

- `backend/docs/ManifestGeneration.md` (this file).
- `backend/metadata/{id}.json` sidecar shape frozen.
- Every manifest field mapped to its authoritative source.
- Deterministic generation and failure rules documented.
- No implementation code, no automation.
