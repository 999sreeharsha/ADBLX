# iOS manifest verification (SEC-09, app side)

Design: `docs/Security/ManifestTrust.md`. Branch: `feat/manifest-signing`. Publisher side is
done (P-256 with K1 in the Secure Enclave, hash-named signatures, 7-day pruning, timestamp
`manifestVersion`, ID pattern).

## What exists today

- `ManifestClient.fetch(previousETag:)` GETs `manifest.json` and decodes it. No signature, no
  rules beyond JSON decoding. An unknown `group` already fails decoding (`FilterGroup` is a
  closed enum), so that rule holds.
- `UpdateCoordinator.runTransaction` saves the manifest and ETag through `ManifestStore` after
  planning (or after install). A 304 returns early.
- Duplicate IDs trap in `Dictionary(uniqueKeysWithValues:)` in `UpdatePlan.swift` (SEC-09/SEC-05).
- The bundled lists' checksums match the committed `backend/public/manifest.json` exactly
  (checked 2026-11-06), so that manifest describes the bundled snapshot.

## Tasks

Each task ends green, with a test that fails without it.

### 1. `ManifestVerifier`: signature and rules, pure and synchronous

`ADBLX/Filtering/Updates/ManifestVerifier.swift`, `nonisolated struct`, no I/O. Input: the raw
manifest bytes, the signature file bytes, the manifest URL, the cached manifest (if any), the
built-in minimum version. Output: the decoded `FilterManifest` or a `ManifestRejection` with a
reason case (`signature`, `malformed`, `versionFormat`, `rollback`, `belowMinimum`, `id`,
`duplicate`, `sourceURL`).

Checks, in order: signature over the raw bytes against the pinned P-256 keys (64-byte raw
r ‖ s); decode; `manifestVersion` strict `YYYY-MM-DDTHH:MM:SSZ`; not below the built-in
minimum; not below the cached version, and equal only if the decoded manifest is equal; every
id matches `^[a-z0-9][a-z0-9-]{0,63}$`; no duplicate ids; every `sourceURL` is https and equals
`<manifest directory>/filters/<group>/<id>.txt`, under a pinned base.

Tests: one rejection per reason, each with an otherwise valid manifest; acceptance with K1 and
with K2 (recovery); a date-only cached version compares as midnight UTC; the Publisher's
signature format verifies (fixture signed by the Publisher, committed with its public key).

### 2. Pinned keys and bases

`ManifestTrust.swift`: `pinnedPublicKeys` (K1, K2, base64 raw P-256) and `allowedBases`
(`https://999sreeharsha.github.io/ADBLX`). Keys are empty until the owner generates them.

A test fails while fewer than two keys are pinned. It is `.disabled` with a pointer to the
release checklist until the keys arrive, so the gap is visible in every run rather than
silent. Nothing ships without it enabled (checklist item "signed manifest live, both keys
pinned").

### 3. Built-in minimum from the bundled manifest

Copy `backend/public/manifest.json` to `ADBLX/Resources/Filters/manifest.json`. The minimum is
its `manifestVersion`. Test: every bundled `.txt` matches that manifest's checksum, and every
premium/free bundled list is in it, so the minimum can't drift from what ships. Gotcha entry:
the bundled manifest is the fourth copy to keep equal (with the payload, the bundled list and
the backend manifest).

### 4. `ManifestClient` fetches and verifies

On 200: keep the raw bytes, fetch `signatures/<sha256 hex>.sig` beside the manifest (404 or
other error → `signature` rejection), run `ManifestVerifier`, return `.updated` only for an
accepted manifest. On 304: unchanged (the cached manifest was verified when saved).

Tests with `HTTPSession` stubs: the signature URL is derived from the downloaded bytes; a
mismatched (old) signature is rejected; a missing one is rejected; a 304 fetches no signature.

### 5. Soft failure in the coordinator and the sheet

A rejection throws `ManifestRejection` from `run()` before anything is written: no download,
no compile, no `ManifestStore.save`, so the ETag isn't saved and the next run refetches.
`UpdateThrottle` isn't advanced by a rejected run. `UpdateProgressModel` shows the neutral
network-failure text ("Couldn't check for filter updates right now. Your current filters are
still on."), never mentioning verification. Log `manifest rejected reason=<case>` only
(`Logging.md`). The DEBUG diagnostics screen shows the consecutive-rejection count.

Tests: a rejected manifest leaves installed rules, `installed_filters.json`, the cached
manifest and the ETag byte-identical, and the throttle unchanged; **a fresh install served an
old, validly signed manifest keeps its bundled rules** and reports a failed update; the sheet
text for a rejection equals the network-failure text.

### 6. Cross-host redirects refused for list downloads

`FilterDownloadClient` cancels a redirect to a different host
(`URLSessionTaskDelegate.willPerformHTTPRedirection`). Test with a stub session.

### 7. Docs

`Findings.md` SEC-09 status, `ManifestTrust.md` order of work, `TECHNICAL_OVERVIEW.md` update
flow, gotchas (bundled manifest copy; verification failure is silent by design).

## Not in this plan

- Download size caps and streaming to disk (next item; `ManifestTrust.md` Size).
- Deploying the first signed manifest (owner, after keys; release checklist).

## Open questions for review

1. Equal-version rule: compare the decoded manifests rather than raw bytes, since
   `ManifestStore` keeps the decoded form. Same protection (any content change with an equal
   version is rejected); storing raw bytes would add a second cache file. OK?
2. Before the keys exist, the production verifier has no keys and would reject every manifest.
   Proposal: wire verification in fully, and until keys are pinned keep production builds on
   the bundled lists (updates fail softly). DEBUG builds can point at a test key and a locally
   signed manifest for device testing. Acceptable, given nothing ships before the keys?
