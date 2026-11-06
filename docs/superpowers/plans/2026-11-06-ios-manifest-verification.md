# iOS manifest verification (SEC-09, app side)

Design: `docs/Security/ManifestTrust.md`. Branch: `feat/manifest-signing`. Publisher side is
done (P-256 with K1 in the Secure Enclave, hash-named signatures, 7-day pruning, timestamp
`manifestVersion`, ID pattern). Reviewed 2026-11-07; the review's changes are folded in below.

## What exists today

- `ManifestClient.fetch(previousETag:)` GETs `manifest.json` and decodes it. No signature, no
  rules beyond JSON decoding. An unknown `group` already fails decoding (`FilterGroup` is a
  closed enum), so that rule holds.
- `UpdateCoordinator.runTransaction` saves the manifest and ETag through `ManifestStore` after
  planning (or after install). A 304 returns early through `upToDateResult()`, which retries
  `pending_reloads.json`.
- `ADBLXApp` checks `UpdateThrottle` at launch and records success only for `.upToDate` and
  `.updated`; a thrown error records nothing.
- Duplicate IDs trap in `Dictionary(uniqueKeysWithValues:)` in `UpdatePlan.swift` (SEC-09/SEC-05).
- The bundled lists' checksums match the committed `backend/public/manifest.json` exactly
  (checked 2026-11-06), so that manifest describes the bundled snapshot.
- `Scripts/check-report-recipient.sh` is the existing pre-archive check (a build phase that
  acts only when `ACTION=install`, with a shell test). The new archive checks follow it.

## Tasks

Each task ends green, with a test that fails without it.

### 1. `ManifestVerifier`: signature and rules, pure and synchronous

`ADBLX/Filtering/Updates/ManifestVerifier.swift`, `nonisolated struct`, no I/O. Input: the raw
manifest bytes, the signature file bytes, **the trusted keys**, the manifest URL, the allowed
bases, the cached manifest (if any) and the built-in minimum version. Production passes
`ManifestTrust.pinnedPublicKeys`; tests pass their own key, so no test key is ever pinned in
the app.

Output:
- `.accepted(FilterManifest)`;
- `.unchanged`: same version and decoded-equal to the cached manifest. Treated like a 304: no
  install, no failure reported. The new ETag is saved, so the next check is a 304;
- or a `ManifestRejection` with a reason case (`signature`, `malformed`, `versionFormat`,
  `rollback`, `belowMinimum`, `id`, `duplicate`, `sourceURL`).

Checks, in order:
1. The signature over the raw bytes, against the trusted keys (64-byte raw r ‖ s).
2. Decode.
3. `manifestVersion` **strict**: an incoming manifest must be a full `YYYY-MM-DDTHH:MM:SSZ`.
4. Not below the built-in minimum.
5. Not below the cached version. Equal is `.unchanged` if decoded-equal and `rollback` if not.
6. Every id matches `^[a-z0-9][a-z0-9-]{0,63}$`.
7. No duplicate ids.
8. Every `sourceURL` is https and equals `<manifest directory>/filters/<group>/<id>.txt`, under
   an allowed base.

The cached version and the built-in minimum are parsed **leniently**: a date-only value
(`YYYY-MM-DD`, the committed manifest's format today) counts as midnight UTC.

Tests:
- One rejection per reason, each with an otherwise valid manifest.
- Acceptance with K1 and with K2 (recovery).
- Equal version and decoded-equal → `.unchanged`.
- A date-only cached version, and a date-only built-in minimum, parse and compare as midnight
  UTC. A date-only incoming version is rejected (`versionFormat`).
- The Publisher's signature format verifies: a fixture signed by the Publisher, committed with
  its public key, which the test passes in.

### 2. Pinned keys and bases, with a hard archive gate

`ManifestTrust.swift`: `pinnedPublicKeys` (K1, K2, base64 raw P-256) and `allowedBases`
(`https://999sreeharsha.github.io/ADBLX`). Keys are empty until the owner generates them, so
production builds stay on the bundled lists and updates fail softly until then.

- A Debug test key, for device testing against a locally signed manifest, lives in a separate
  file under `#if DEBUG` and is added to the trusted keys only in Debug.
- `Scripts/check-manifest-trust.sh`, a pre-archive build phase like the recipient check. It
  fails a Release archive when:
  - fewer than two production keys are pinned;
  - any pinned key isn't 64 raw bytes of base64;
  - the production list contains the Debug test key;
  - the bundled manifest is older than 30 days (see Task 3).
- `Scripts/check-manifest-trust.test.sh` covers each case, like `check-report-recipient.test.sh`.
- Optionally, a `.disabled` Swift test as a visible reminder while fewer than two keys are
  pinned. The archive check is what stops the broken build.

### 3. Built-in minimum from the bundled manifest, refreshed every release

- Copy `backend/public/manifest.json` to `ADBLX/Resources/Filters/manifest.json`. The minimum
  is its `manifestVersion`, parsed leniently (it is date-only today).
- Test: every bundled `.txt` matches that manifest's checksum, and every bundled list is in it,
  so the minimum can't drift from what ships.
- `Scripts/refresh-bundled-manifest.sh`, run before archiving (by hand, not as a build phase,
  so builds don't touch the network):
  - downloads the live `manifest.json` and its `signatures/<sha256>.sig`;
  - verifies them with `publisher verify` against the pinned public keys;
  - downloads each bundled list and checks it against the manifest's checksum;
  - only then copies everything into `ADBLX/Resources/Filters/`.
- The archive check (Task 2) fails if the bundled manifest is older than 30 days, so the
  minimum keeps up with releases.
- Gotcha entry: the bundled manifest is the fourth copy to keep equal (with the payload, the
  bundled list and the backend manifest), and the refresh script is how it stays current.

### 4. `ManifestClient` fetches and verifies

- **Size:** refuse a manifest over 256 KB (`ManifestTrust.md` Size; today's is a few KB). Check
  `expectedContentLength` first when the server sends one, then the received byte count, before
  hashing. The signature file is capped at 1 KB.
- **On 200:**
  - keep the raw bytes;
  - fetch `signatures/<sha256 hex>.sig` beside the manifest. A 404 or any other error is a
    `signature` rejection;
  - run `ManifestVerifier`;
  - return `.updated` only for an accepted manifest, and `.unchanged(etag:)` for an unchanged one.
- **On 304:** unchanged.
- **Caches from before verification:** `CachedManifest` gains `signatureVerified` (decoded as
  `false` when missing). `ManifestStore.load()` drops the ETag of a cache without it, so the
  next fetch is unconditional, gets a 200 and goes through verification. Dev and TestFlight
  devices carry such caches.

Tests with `HTTPSession` stubs:
- the signature URL is derived from the downloaded bytes;
- a mismatched (old) signature is rejected, and so is a missing one;
- a 304 fetches no signature;
- an oversized manifest is refused from `expectedContentLength` without reading on, and from
  the byte count when no length is sent;
- an old-format cache leads to a request without `If-None-Match`.

### 5. Soft failure in the coordinator and the sheet

A rejection throws `ManifestRejection` from `run()` before anything is written: no download,
no compile, no `ManifestStore.save`. The ETag isn't saved, so the next allowed check downloads
the full manifest.

- **Pending reloads still run.** `runTransaction` catches the rejection, runs the
  `pending_reloads.json` retry (as `upToDateResult()` does on a 304), then rethrows.
- **The throttle advances.** `ADBLXApp` records the throttle for a `ManifestRejection`, as it
  does for success. A bad publish or a missing signature then costs one request per throttle
  window per phone, not one per launch. Other errors keep today's behaviour (retry next launch).
- `UpdateProgressModel` shows the neutral network-failure text ("Couldn't check for filter
  updates right now. Your current filters are still on."), never mentioning verification.
- Log `manifest rejected reason=<case>` only. `Logging.md`'s allowed list gains "fixed enum
  codes" (Task 7).
- The DEBUG diagnostics screen shows the consecutive-rejection count.

Tests:
- A rejected manifest leaves the installed rules, `installed_filters.json`, the cached manifest
  and the ETag byte-identical.
- A rejection, then a launch inside the throttle window, makes no request.
- **A fresh install served an old, validly signed manifest keeps its bundled rules** and
  reports a failed update.
- A pending reload is retried on a rejected run.
- The sheet text for a rejection equals the network-failure text.

### 6. List downloads: same host and HTTPS at every hop

`FilterDownloadClient` cancels a redirect to a different host, and a redirect that downgrades
to `http` (`URLSessionTaskDelegate.willPerformHTTPRedirection`). Tests with a stub session for
both.

### 7. Docs

- `Findings.md`: SEC-09 status.
- `ManifestTrust.md`:
  - the order of work;
  - equal version compares decoded manifests;
  - a rejection advances the throttle;
  - the refresh script and the 30-day check;
  - the brand domain goes into `allowedBases` in a release *before* the site moves.
- `Logging.md`: add "fixed enum codes (e.g. `reason=signature`)" to the allowed list.
- `TECHNICAL_OVERVIEW.md`: the update flow.
- Gotchas: the bundled manifest copy and its refresh; verification failure is silent by design.

## Not in this plan

- Download size caps and streaming to disk for the lists (next item; `ManifestTrust.md` Size).
  The manifest's own cap is in Task 4.
- Deploying the first signed manifest (owner, after keys; release checklist).

## Decided in review (2026-11-07)

1. Equal version: compare the decoded manifests. Decoded-equal with the same version is
   treated like a 304.
2. No keys yet: acceptable, gated by the pre-archive check in Task 2, which also keeps the
   Debug test key out of Release.
