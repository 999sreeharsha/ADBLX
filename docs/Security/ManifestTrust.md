# Manifest Trust

How the app decides that a `manifest.json` came from us and is safe to act on. This is the
design for SEC-09 (`docs/Security/Findings.md`). The Publisher side of signing is built; the
app side is not yet.

## Why

The manifest decides which rule lists every device downloads and installs. Today it is
trusted because it arrives over HTTPS from one GitHub Pages site, so anyone who can push to
that site, or to the account behind it, controls what every user blocks and allows. HTTPS
proves which host answered, not who wrote the file. A signature made with a key that never
touches GitHub removes that dependency.

## What is signed

- **Algorithm:** ECDSA P-256 with SHA-256 (CryptoKit `P256.Signing`, iOS 13+ and macOS
  10.15+). P-256, not Ed25519, because the Secure Enclave only holds P-256 keys, and K1 lives
  there (decided 2026-11-06).
- **Message:** the exact bytes of `manifest.json` as `ManifestJSONWriter` writes them. The app
  verifies those bytes before parsing, never a re-encoding of the parsed value.
- **File:** `signatures/<sha256>.sig` beside the manifest, where `<sha256>` is the lowercase hex
  SHA-256 of the manifest bytes. It holds the base64 of the 64-byte raw (r ‖ s) signature, not
  DER, and a newline. It
  has no key ID; the app tries each pinned key.
- **Not deterministic:** ECDSA signatures are randomized, so signing the same manifest
  twice gives different signature files. Both verify. The manifest itself stays byte-identical
  for the same inputs.

### Publisher commands

```bash
# Once, on the signing Mac. Each refuses a path inside the repository or an existing file.
# K1, inside this Mac's Secure Enclave: the file is only a handle this enclave can use.
swift run --package-path backend/tools/Publisher Publisher keygen --secure-enclave --output ~/Keys/adblx-manifest-k1.key
# K2, an ordinary key file: move it to offline storage at once (see Keys).
swift run --package-path backend/tools/Publisher Publisher keygen --output /Volumes/<offline drive>/adblx-manifest-k2.key

# Every publish, from the repository root.
swift run --package-path backend/tools/Publisher Publisher publish --publish-base-url <url> --manifest-version <UTC now, e.g. 2026-11-06T09:30:00Z>
swift run --package-path backend/tools/Publisher Publisher sign --signing-key-file ~/Keys/adblx-manifest-k1.key   # asks for Touch ID or the password
swift run --package-path backend/tools/Publisher Publisher verify --public-key <K1> --public-key <K2>

# Before every archive, once the signed manifest is deployed: copy it and the bundled lists
# into the app (verifies with Publisher verify --manifest <file> --signatures <dir>).
Scripts/refresh-bundled-manifest.sh
```

### Why the signature is named after the manifest

The manifest and its signature are fetched separately, and the CDN caches each file on its
own. With one fixed `manifest.json.sig`, a device right after a deploy can get the new
manifest with the old signature, or the old manifest with the new one, and both fail.

Naming the signature after the manifest's hash removes that race. The app hashes the bytes it
downloaded and fetches exactly that signature, so a cached copy can only ever be the right
one. The other fixes considered:

- **The manifest's ETag in the query string:** only gives a unique URL if the CDN keys on
  the query, and an edge still serving the old manifest would fetch the new signature from
  origin.
- **One envelope file holding both:** removes the race too, but the signed bytes would have to
  sit base64-encoded inside JSON, and the manifest format would change.

### Old signatures are pruned after 7 days

Every published signature keeps its manifest valid, and the rollback rule only protects a
device that already has a cached version. So `sign` deletes signatures written more than
7 days ago (`ManifestPublication.signatureRetention`). That is long enough for a device whose
CDN edge still serves the previous manifest, which takes minutes or hours. Each signature's date
is recorded in `signatures/index.json`, because a file's date in a fresh checkout is the checkout
time. Any signature not in the index is deleted. The deploy replaces the whole Pages root, so a
pruned signature is gone from the site too. Pruning narrows replay; the built-in minimum below
closes it for fresh installs.

`sign` also reads the key from `ADBLX_MANIFEST_SIGNING_KEY` (base64), and refuses when both are
given. No command prints the private key, and no error contains it. Commit the signature with
the manifest: it is public, and the deploy copies `backend/public/` verbatim.

## Keys

### Generation and storage

**Manual signing (decided 2026-11-06, Option B).** Each publish is a manual step on the owner's
Mac (`publisher generate`, then `publisher sign --signing-key-file <K1>`, review, deploy), so
lists update only when the owner publishes. No key is ever in the repository, CI, a cloud
session or any folder an AI session can read. Any future automation must follow
[`PublishingAutomation.md`](PublishingAutomation.md); its first rule is that no AI agent ever
has access to a signing key.

- Generate each key with `publisher keygen` on the signing Mac, not in CI.
- **K1, the signing key, is made inside that Mac's Secure Enclave** (`keygen --secure-enclave`).
  The private key never leaves the enclave and can't be copied by anyone, including the owner.
  The file `keygen` writes holds only a handle (the key's `dataRepresentation`) that this one
  enclave can use, so it is useless anywhere else; keep it out of the repository anyway.
  - Every signature asks for **user presence**: Touch ID, or the login password on a Mac
    without Touch ID. Checked on 2026-11-06 on the signing Mac, a Mac mini with no
    fingerprints enrolled: an ad-hoc-signed command-line build can make, reload and sign with
    an enclave key, with no entitlements. A key that requires biometrics can't even be made
    there.
  - Not biometrics-only on any Mac: such a key becomes unusable for good when the enrolled
    fingerprints change, which would lose K1.
  - When automation is built, it uses this same K1, so no new key needs pinning.
- **K2, the recovery key:** an ordinary P-256 key file, generated now, with K1, not at the first
  rotation. Rotation only works if K2's public key is already pinned in every installed app,
  so it must ship in the first build. Write it straight to offline storage (an encrypted drive
  kept apart from the Mac), never to the signing Mac's own disk. It never signs anything until
  K1 is retired, lost or leaks.
- Both public keys are pinned before the first TestFlight build.
- **Test recovery before the first TestFlight build:** sign a manifest with K2 and confirm the
  app accepts it. It is the one path normal use never exercises. The Publisher side is covered
  by `test_aManifestSignedWithTheRecoveryKeyFileVerifiesAgainstBothPinnedKeys`; the app needs
  the same test with its real pinned keys, plus a manual run against a K2-signed deploy.
- The public keys are not secret. Both ship in the app.
- `.gitignore` ignores `*.key` as a backstop, and `keygen` refuses repository paths, but the
  key file should never be inside a checkout in the first place.

### Two pinned keys and rotation

The app pins **K1 and K2** and accepts a manifest signed by either. Old app versions can't
learn new keys, so rotation always moves to a key every installed version already trusts.

- **The signing Mac is lost, replaced or its enclave reset.** K1 is tied to that one Mac and
  is gone with it; `sign` then reports that the key file isn't a key this Mac can use.
  1. Sign with K2, from its offline copy, on whichever Mac publishes now. Every installed app
     accepts it. Put K2 back offline after each publish.
  2. On the new signing Mac, run `keygen --secure-enclave` to make a new enclave key, K3.
  3. Ship an app update pinning K3 and K2.
  4. Once that update is out, sign with K3 again. K2 goes back to recovery only. Versions that
     still pin K1 also pin K2, so they keep updating with K2 until they update.
  Nothing has to be rushed: K2 signs for as long as the update takes.
- **Planned rotation:**
  1. Start signing with K2. Every installed app accepts it.
  2. Generate K3 and store it offline as the new standby.
  3. Ship an app update pinning K2 and K3.
  4. Stop accepting K1 in that update. Versions that still pin K1 also pin K2, so they keep
     updating.
- **K1 compromised:** the same steps, done at once. Until users update, an attacker holding K1
  can still sign manifests that older versions accept. The rollback rule below limits what
  they can replay, and the rules below limit what a signed manifest can make the app do.
- **Both keys lost:** devices keep their installed rules but can't update until they install
  an app version pinning a new key. That is why K2 is stored separately from K1.

## What the app checks, in order

On a `200` response:

1. **Fetch `signatures/<sha256 of the downloaded bytes>.sig`** from the same base URL, with its
   own size cap. A missing or unreadable signature is a verification failure. On a `304` the
   cached manifest was verified when it was stored, so no signature is fetched. A cache
   written before verification existed has no `signatureVerified` mark; its ETag is dropped,
   so the next request is unconditional and the manifest is verified.
2. **Verify** the downloaded bytes against the pinned keys, before parsing.
3. **Parse,** then apply every rule below to the whole manifest. Any failure rejects the whole
   manifest. Nothing is kept from it.
4. **Commit:** only now save the manifest and its ETag. Saving the ETag earlier would turn the
   next request into a `304` for a manifest that was never verified.

### Rollback

A valid signature still allows replaying an old signed manifest, for example one that lists a
list we since removed or that has an older checksum.

- **Reject** a `manifestVersion` lower than the cached one.
- **Reject** a `manifestVersion` lower than the app's built-in minimum, the version of the
  manifest its bundled snapshot came from. A fresh install has no cached version, so without
  this an old manifest that is still validly signed would install older rules on it. The
  bundle doesn't record that version today: ship the snapshot's `manifest.json` in
  `ADBLX/Resources/Filters/`, with a test that the bundled lists match its checksums, so the
  minimum can't drift from what actually ships. A manifest rejected this way is a failed
  update like any other, and the bundled rules stay installed.
- **The minimum is refreshed every release.** Before archiving,
  `Scripts/refresh-bundled-manifest.sh` copies the live signed manifest and its lists into the
  bundle, after verifying the signature and checksums. The pre-archive check fails if the
  bundled manifest is more than 30 days old, so fresh-install protection doesn't weaken as
  releases go by.
- **Equal version:** if the decoded manifest equals the cached one, nothing changed: it is
  treated like a `304` (no install, no failure). Equal version with different content is
  rejected. Decoded rather than raw bytes, because `ManifestStore` keeps the decoded form.
- **The version changes on every publish that changes the manifest** (built 2026-11-06,
  `ManifestVersion.resolve`):
  - `manifestVersion` is a UTC timestamp, `YYYY-MM-DDTHH:MM:SSZ`. It is fixed width, so
    string order is time order. A cached date-only value (`2026-11-05`, the format before this
    change) compares as that day at `00:00:00Z`.
  - It is an input to `publish` (`--manifest-version`), not the clock, so the output stays
    deterministic. `publish` refuses a value not later than the committed manifest's when the
    entries differ, and keeps the committed value when they don't. A committed date-only
    version is never kept: the next publish needs a timestamp.
  - The first signed manifest must use this format, since the app's rollback check compares it.
- The app parses an incoming manifest's version strictly and rejects anything that doesn't
  match the format. The cached version and the built-in minimum are parsed leniently (a
  date-only value counts as midnight UTC), since the committed manifest is still date-only.

### Filter IDs

An `id` becomes a file name (`Filters/<id>.json`) and part of a URL.

- Must match `^[a-z0-9][a-z0-9-]{0,63}$`. Anything else rejects the manifest.
- The Publisher's `Validator` enforces the same pattern (`Validator.idPattern`), so a bad ID
  never gets published.

### Duplicates

- Two entries with the same `id` reject the whole manifest. Keeping the first would make
  behaviour depend on entry order and hide a publishing bug. It also removes the
  `Dictionary(uniqueKeysWithValues:)` traps in `UpdatePlan.swift` and
  `UpdateCoordinator.swift`.
- The Publisher already rejects duplicate registry IDs.

### Groups

`group` must be one of `ads`, `privacy`, `annoyances` or `regional`. Unknown values reject
the manifest instead of being skipped.

### `sourceURL`

- Must be `https`, and must equal `<base>/filters/<group>/<id>.txt`, where `<base>` is the
  directory the manifest was fetched from. This is the layout decided on 2026-11-06
  (`docs/gotchas.md`). Any other host, path or scheme rejects the manifest.
- The app pins the allowed bases: today `https://999sreeharsha.github.io/ADBLX`, later the
  brand domain. Moving hosts means adding the brand domain to `allowedBases` in a release
  *before* the site moves, and moving only once that release is what users run.
- Downloads refuse redirects to a different host (a `URLSessionTaskDelegate` that cancels a
  cross-host redirect). `URLSession` follows redirects by default.
- The payload checksum is checked as today. With a signed manifest, that checksum is now
  trustworthy too.

### Size

The manifest, its signature and every list download are capped and streamed to disk, as in
SEC-09's size-cap item. Planned caps: 256 KB for the manifest, 1 KB for the signature, and a
per-list cap set from the largest real list with headroom.

## When verification fails

Treat it as temporary. The likeliest cause is a deploy still reaching the CDN (the signature
not there yet), not an attack, and the safe response to both is the same.

- Keep every installed rule and the cached manifest and ETag exactly as they are. Nothing is
  downloaded or compiled. Not saving the ETag means the next allowed check fetches the whole
  manifest again. Pending Safari reloads (`pending_reloads.json`) are still retried, as on a
  `304`.
- Don't show it as an error. An automatic update says nothing and retries on the next run. A
  manual update shows the neutral "Couldn't check for filter updates right now. Your current
  filters are still on.", the same as a network failure. It does not mention verification.
- Retry at the next allowed check, not in a loop. A rejection **advances** the update
  throttle, like a success: otherwise a bad publish or a missing signature would make every
  launch on every phone refetch the manifest for as long as the problem lasts.
- Log the reason as a case name and a count only (`docs/Architecture/Logging.md`): for example
  `manifest rejected reason=signature`, never a URL or ID. The DEBUG diagnostics screen shows
  consecutive failures, so one that lasts past a deploy can be seen during testing.
- Never fall back to the unsigned path.

The rule checks below (rollback, IDs, duplicates, groups, `sourceURL`) fail the same way. A
manifest that breaks them is a publishing bug or an attack, and it stays rejected until a new
manifest replaces it.

## Order of work

1. Publisher: `keygen`, `sign` (to `signatures/<sha256>.sig`, keeping earlier ones) and
   `verify`. **Done.**
2. Publisher: signature pruning (7 days, `signatures/index.json`) and the `manifestVersion`
   timestamp, and the ID-pattern check in `Validator`. **Done.**
3. Generate K1 (`keygen --secure-enclave`) and K2 (a key file, written to offline storage)
   together, and record both public keys in the app. The algorithm is settled: P-256.
4. App: download cap and streaming (SEC-09 size cap), then signature fetch and verification,
   then the rollback rule (cached version and built-in minimum), ID, duplicate, group and
   `sourceURL` rules, each with a test that the whole manifest is rejected and the installed
   rules are unchanged. That includes a fresh install served an old, validly signed manifest:
   it keeps its bundled rules and reports a failed update.
5. Sign and deploy the first signed manifest **before** the first TestFlight upload. Nothing has
   shipped, so there is no unsigned transition: every build requires a signature from the
   first release on. An app that requires a signature, reading a site that has none, can never
   update, so "signed manifest live on the site" is on the release checklist
   (`docs/AppStoreSetup.md`).
