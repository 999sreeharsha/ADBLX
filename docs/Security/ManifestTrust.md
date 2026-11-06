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

- **Algorithm:** Ed25519 (CryptoKit `Curve25519.Signing`, iOS 13+ and macOS 10.15+).
- **Message:** the exact bytes of `manifest.json` as `ManifestJSONWriter` writes them. The app
  verifies those bytes before parsing, never a re-encoding of the parsed value.
- **File:** `manifest.json.sig` beside the manifest: the base64 of the 64-byte signature and a
  newline. It has no key ID; the app tries each pinned key.
- **Not deterministic:** CryptoKit randomizes Ed25519 signatures, so signing the same manifest
  twice gives different signature files. Both verify. The manifest itself stays byte-identical
  for the same inputs.

### Publisher commands

```bash
# Once, on the maintainer's machine. Refuses a path inside the repository or an existing file.
swift run --package-path backend/tools/Publisher Publisher keygen --output ~/Keys/adblx-manifest-1.key

# Every publish, from the repository root.
swift run --package-path backend/tools/Publisher Publisher publish --publish-base-url <url>   # removes a stale .sig
swift run --package-path backend/tools/Publisher Publisher sign --signing-key-file ~/Keys/adblx-manifest-1.key
swift run --package-path backend/tools/Publisher Publisher verify --public-key <K1> --public-key <K2>
```

`sign` also reads the key from `ADBLX_MANIFEST_SIGNING_KEY` (base64), and refuses when both are
given. No command prints the private key, and no error contains it. Commit `manifest.json.sig`
with the manifest: it is public, and the deploy copies `backend/public/` verbatim.

## Keys

### Generation and storage

- Generate each key with `publisher keygen` on the maintainer's own Mac, not in CI.
- **K1, the signing key:** an encrypted copy in the maintainer's password manager, which is
  where `sign` reads it from at publish time. Publishing is a local step
  (`backend/tools/publish-pages.sh`), so CI never needs the private key. If signing ever moves
  to CI, the key goes in the CI secret store as `ADBLX_MANIFEST_SIGNING_KEY` and nowhere else.
- **K2, the standby key:** generated at the same time, and kept offline only, in two places
  (for example, an encrypted USB drive and a printed copy in a safe). It is never used until a
  rotation.
- The public keys are not secret. Both ship in the app.
- `.gitignore` ignores `*.key` as a backstop, and `keygen` refuses repository paths, but the
  key file should never be inside a checkout in the first place.

### Two pinned keys and rotation

The app pins **K1 and K2** and accepts a manifest signed by either. Old app versions can't
learn new keys, so rotation always moves to a key every installed version already trusts.

- **Planned rotation (or K1 lost):**
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

1. **Fetch `manifest.json.sig`** from the same base URL, with the same size cap as the
   manifest. A missing or unreadable signature is a verification failure. On a `304` the
   cached manifest was verified when it was stored, so no signature is fetched.
2. **Verify** the downloaded bytes against the pinned keys, before parsing.
3. **Parse,** then apply every rule below to the whole manifest. Any failure rejects the whole
   manifest. Nothing is kept from it.
4. **Commit:** only now save the manifest and its ETag. Saving the ETag earlier would turn the
   next request into a `304` for a manifest that was never verified.

### Rollback

A valid signature still allows replaying an old signed manifest, for example one that lists a
list we since removed or that has an older checksum.

- **Reject** a `manifestVersion` lower than the cached one.
- **Equal version:** accept only if the bytes are identical to the cached manifest (nothing
  changed). Equal version with different bytes is rejected.
- **The version must therefore change on every publish that changes the manifest.** Today it
  doesn't: `ManifestBuilder` sets it to the newest entry's `version`, so removing a list or
  changing a name or premium flag keeps the same version, and two publishes on one day can't be
  ordered. Change it before shipping verification:
  - `manifestVersion` becomes a UTC timestamp, `YYYY-MM-DDTHH:MM:SSZ`. It is fixed width, so
    string order is time order. A cached date-only value (`2026-11-05`) compares as that day
    at `00:00:00Z`.
  - It is an input to `publish` (`--manifest-version`), not the clock, so the output stays
    deterministic. `publish` refuses a value not greater than the committed manifest's when
    the entries differ, and keeps the committed value when they don't.
  - Update `backend/docs/ManifestSpecification.md` with the new format.
- The app parses the version strictly and rejects anything that doesn't match the format.

### Filter IDs

An `id` becomes a file name (`Filters/<id>.json`) and part of a URL.

- Must match `^[a-z0-9][a-z0-9-]{0,63}$`. Anything else rejects the manifest.
- The Publisher's `Validator` enforces the same pattern, so a bad ID never gets published.

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
  brand domain. Moving hosts means shipping both in one app version first.
- Downloads refuse redirects to a different host (a `URLSessionTaskDelegate` that cancels a
  cross-host redirect). `URLSession` follows redirects by default.
- The payload checksum is checked as today. With a signed manifest, that checksum is now
  trustworthy too.

### Size

The manifest, its signature and every list download are capped and streamed to disk, as in
SEC-09's size-cap item. Planned caps: 256 KB for the manifest, 1 KB for the signature, and a
per-list cap set from the largest real list with headroom.

## When verification fails

- Keep every installed rule and the cached manifest and ETag exactly as they are. Nothing is
  downloaded or compiled.
- Report a failed update: the update sheet shows "Couldn't verify the filter update. Your
  current filters are still on." An automatic update logs it and retries on the next run, like
  any failed update.
- Log the reason as a case name and a count only (`docs/Architecture/Logging.md`): for example
  `manifest rejected reason=signature`, never a URL or ID.
- Don't fall back to the unsigned path, and don't retry immediately: a manifest that fails now
  fails the same way until it changes.

## Order of work

1. Publisher: `keygen`, `sign`, `verify`, and removing a stale signature on `publish`. **Done.**
2. Publisher: the `manifestVersion` change and the ID-pattern check in `Validator`.
3. Generate K1 and K2, store them as above, and record both public keys in the app.
4. App: download cap and streaming (SEC-09 size cap), then signature fetch and verification,
   then the rollback, ID, duplicate, group and `sourceURL` rules, each with a test that the
   whole manifest is rejected and the installed rules are unchanged.
5. Sign and deploy the first signed manifest **before** shipping an app that requires one. An
   app that requires a signature, reading a site that has none, can never update.
