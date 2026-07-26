# ADBLX Manifest Specification (v1)

## Purpose

This document freezes the JSON contract of `backend/public/manifest.json` —
the one file every ADBLX client downloads first (Sprint 6 Commit 1). It is
consumed directly by the iOS app, so once published it is a versioned public
API, not an internal implementation detail.

This document **specifies the existing implementation**; it does not
introduce a new schema. The JSON shape below is already the decode target of
`FilterManifest` (`ADBLX/Filtering/Models/FilterManifest.swift`), already
diffed against installed state by `UpdatePlanner`
(`ADBLX/Filtering/Updates/UpdatePlan.swift`), and already fetched by
`ManifestClient` (`ADBLX/Filtering/Updates/ManifestClient.swift`). Any change
to the JSON shape described here requires a coordinated change to that Swift
model — this document and the code must never drift apart.

Commit 3 answers:

- JSON structure and field-by-field meaning.
- Versioning strategy (`manifestVersion`).
- Checksum format.
- URL convention.
- Compatibility rules.

Commit 3 deliberately does not answer:

- How the manifest file is generated (later commit / `backend/tools/`).
- GitHub Actions or publishing workflow.
- Download implementation for filter payloads (`FilterDownloadClient`
  already exists in the app, but its behavior is out of scope here).
- Client fetch scheduling (`UpdateCoordinator` / PRD §5.1 cadence).
- Filter compilation (`FilterPipeline`, `CompositionService`).

## Document structure

`manifest.json` is a single JSON object with two top-level fields:

```json
{
  "manifestVersion": "2026-08-01",
  "entries": [
    {
      "id": "easylist",
      "name": "EasyList",
      "group": "ads",
      "sourceURL": "https://example.invalid/backend/public/filters/ads/easylist.txt",
      "version": "2026-07-15",
      "checksumSHA256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85",
      "ruleCount": 62000,
      "enabledByDefault": true,
      "premium": false
    }
  ]
}
```

### Top-level fields

| Field | Type | Required | Meaning |
|---|---|:---:|---|
| `manifestVersion` | string | ✅ | Identifies the published manifest snapshot. Date-based (see Versioning below). Changes whenever the set of published entries or their metadata changes. It is not the application version and does not imply a change to this JSON schema. |
| `entries` | array of Entry | ✅ | Every filter currently published. Order is not meaningful (no compile-order semantics — see `docs/FilterRegistry.md`). |

### Entry fields

Field names are exact JSON keys — `JSONDecoder()` is used with no
`keyDecodingStrategy`, so camelCase keys must match verbatim.

| Field | Type | Required | Meaning |
|---|---|:---:|---|
| `id` | string | ✅ | Stable internal identifier. Matches `docs/FilterRegistry.md`'s Internal ID (e.g. `easylist`). Immutable once published — see the registry's ID contract. |
| `name` | string | ✅ | Display name (e.g. `"EasyList"`). |
| `group` | string | ✅ | One of `"ads"`, `"privacy"`, `"annoyances"`, `"regional"` — the raw value of the client's `FilterGroup` enum. Any other value fails to decode. |
| `sourceURL` | string (URL) | ✅ | Absolute HTTPS URL to the filter's payload file. Decoded as Swift `URL`. See URL convention below. |
| `version` | string | ✅ | Date-based version of this specific filter's content, e.g. `"2026-07-15"`. Independent of `manifestVersion` — a filter's own version only changes when its content changes. |
| `checksumSHA256` | string | ✅ | SHA-256 of the filter payload at `sourceURL`. See Checksum format below. |
| `ruleCount` | integer | ✅ | Number of rules represented by this filter entry, as published by the backend. |
| `enabledByDefault` | boolean | ✅ | Whether a fresh install enables this filter. Matches `docs/FilterRegistry.md`'s "Default enabled (fresh installation)" field. |
| `premium` | boolean | ✅ | Whether this filter requires a premium entitlement. Matches the registry's Premium field. Drives `UpdatePlanner`'s `.skipPremium` action for non-installed premium entries. |

## Versioning

### `manifestVersion`

Date-based string, formatted `YYYY-MM-DD` (matching each entry's `version`
format and PRD §6.2's "date-based" versioning). Example: `"2026-08-01"`.

`manifestVersion` identifies the published manifest snapshot. It changes
whenever the set of published entries or their metadata changes. It is not
the application version, is not coupled to the ADBLX repository's commit
history or tags (Sprint 6 Commit 1), and does not imply a change to this
JSON schema.

### No separate schema version in v1

This manifest has no `schemaVersion` field. `manifestVersion` (content) and
schema shape (structure) are different concerns, but v1 does not need to
distinguish them because there is only one schema. A `schemaVersion` field
is deferred until an actual second, incompatible schema needs to exist —
introducing it before then would freeze a field with no real use yet. See
Future evolution below.

## Checksum format

SHA-256 of the exact bytes served at `sourceURL`, formatted as:

- Lowercase hexadecimal.
- 64 characters.
- No `0x` or other prefix.

This matches the client's own computation
(`Checksum.sha256Hex(of:)` in `ADBLX/Filtering/Utilities/Checksum.swift`,
which formats each byte as `%02x`). The backend and client must produce
identical strings for identical bytes.

## URL convention

`sourceURL` is always an absolute HTTPS URL, not a path relative to
`manifest.json`. This keeps the client simple (no base-URL resolution) and
makes future hosting migrations (Sprint 6 Commit 1's GitHub Raw → Cloudflare
R2 / GitHub Pages possibility) transparent to already-cached manifests, since
each entry carries its own fully-qualified location.

## Compatibility rules

These follow directly from `FilterManifest`/`Entry` being plain `Codable`
structs with no custom `init(from:)` — they are the actual current decode
behavior, not a future promise:

- **Unknown top-level fields are ignored.** Adding a new top-level key in a
  future manifest does not break older clients.
- **Unknown per-entry fields are ignored.** Adding a new `Entry` key does not
  break older clients.
- **Missing required fields fail the decode.** If the backend omits any
  field listed as required above, `JSONDecoder` throws and the client's
  fetch fails for that manifest (surfaces as an update error, not a crash —
  the client keeps using its last successfully cached manifest via
  `ManifestStore`).
- **An unrecognized `group` value fails the decode** for that reason too,
  since `FilterGroup` is a closed `String` enum with exactly four cases.
  Adding a fifth group is a breaking change requiring a coordinated client
  release, not something this manifest can introduce unilaterally.

## Transport-level caching

`ManifestClient` fetches with a conditional `If-None-Match` request and
honors HTTP `304 Not Modified` / `ETag`, independent of `manifestVersion`.
This is existing behavior, documented here because it's part of how clients
actually observe "the manifest hasn't changed" — a backend that changes
manifest content must also change its ETag (ordinary HTTP semantics; no
manifest-specific action needed if the host computes ETags from content).

## Future evolution

If a breaking schema change is ever needed (a structural change no
`Codable`-default client could tolerate), introduce an explicit top-level
`schemaVersion` integer at that point, e.g.:

```json
{
  "schemaVersion": 2,
  "manifestVersion": "2028-03-15",
  "entries": [...]
}
```

Clients on the old schema would need an explicit rule for handling an
unrecognized `schemaVersion` (e.g. refuse the update, keep serving the last
good cached manifest) — that rule is deferred until this actually happens,
since v1 has no `schemaVersion` field for a client to check.

## Deliverables (this commit)

- `backend/docs/ManifestSpecification.md` (this file).
- Frozen JSON schema, documented field-by-field against the existing
  `FilterManifest`/`Entry` Swift types.
- No manifest generation, no automation, no code changes.
