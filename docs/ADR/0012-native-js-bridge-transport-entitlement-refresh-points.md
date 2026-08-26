# 0012 — Native↔JS bridge: pull-only transport, entitlement propagation, refresh points

**Date:** 2026-08-25
**Status:** Proposed

## Context

ADR-0010 established that native code can never reliably notify a
suspended JS background context, and that a cached entitlement value must
never be treated as indefinitely authoritative. ADR-0011 established
where data lives (generations + independent `entitlement.json`) and that
request-driven native reads must be bounded, not incurred on every matched
page load. This ADR decides the actual protocol: message shapes, when JS
is required to ask again, and how a missing or stale generation is
handled without either silently serving corrupt state or crashing.

## Decision

### 1. Two message types, not one — separate "did anything change" from "give me the data"

```text
JS → Native: checkVersion
Native → JS: {
  generation: Int,
  generationStatus: "ok" | "unavailable",
  entitlementState: "free" | "premiumActive" | "unavailable",
  checkedAt: Timestamp  // diagnostic/logging only
}

JS → Native: fetchGeneration(generation: Int?)
Native → JS: { generation: Int, rules: <rules.json content>, checksum: String }
```

`checkVersion` reads only `current.json` and `entitlement.json` — both
tiny, fixed-size files — and is cheap enough to call on every refresh
point below without the disk-I/O cost ADR-0011's correction flagged.
`fetchGeneration` reads the (potentially large) `rules.json` and is only
called when `checkVersion`'s returned generation number doesn't match
what JS already has cached. This is the concrete mechanism that resolves
"request-driven, not reparsing on every matched page": every matched page
costs one cheap `checkVersion` call; the expensive read only happens on
an actual generation change.

### 2. Pull-only, per ADR-0010: JS always initiates

The native handler never attempts to notify JS of anything. Every
exchange is JS asking, native answering synchronously within the same
`beginRequest`/response cycle already used by `SafariWebExtensionHandler`.

### 3. Explicit, mandatory refresh points & freshness tracking

A cached value is authoritative only between these points, not
indefinitely:

- **Background activation from suspension.** The first message the
  background script sends after being woken (extension load, first event
  after being suspended) is always a `checkVersion` call — never trust
  whatever was last known before suspension without re-checking.
- **First content-script activation on a newly matched page/tab.** Before
  applying any Layer 3 behavior (YouTube handling, cosmetic filtering,
  anti-adblock intervention) on a page, the content script asks the
  background script for current state; the background script answers from
  its own in-memory cache if that cache is within the max-age ceiling
  below, or performs a fresh `checkVersion` first if not.
- **A hard max-age ceiling on the background's in-memory cache: 15
  minutes.** Even if the background context happens to stay alive across
  many page activations without being suspended (a real possibility for a
  long-lived event page), it must force a fresh `checkVersion` at least
  every 15 minutes. This bounds worst-case entitlement staleness
  independent of whatever suspension behavior Safari actually exhibits in
  practice.
- **Freshness computation:** The 15-minute cache-age calculation is tracked
  via local monotonic elapsed time on the JS side, not by comparing against
  the native `checkedAt` wall-clock value. `checkedAt` is retained in the
  response for diagnostics/logging only — never used to compute cache freshness,
  since wall-clock time is subject to manual changes, timezone shifts, and system
  corrections that have nothing to do with how long the cache has actually
  been held.

This means a JS-cached entitlement is authoritative for at most 15
minutes, or until the next suspension/wake cycle, whichever comes first —
directly satisfying ADR-0010's requirement that no refresh point be left
undefined.

### 4. `browser.storage.local` role: cross-suspension warm cache, never a substitute for `checkVersion`

`storage.local` holds the last-known `{generation, entitlementState,
fetchedAt}` and the last-fetched `rules.json` content, so a freshly-woken
background script has *something* to serve immediately rather than
blocking every content-script request on a round-trip. But per the
refresh-point rule above, a background activation from suspension always
still issues a `checkVersion` call — `storage.local` bridges the gap
between "background just woke up" and "checkVersion response arrived," it
never replaces the check itself. `storage.sync` remains prohibited per
ADR-0010.

### 5. Independent recovery & authority models

Replace single-field responses with two independently-tracked axes:

```text
                         AUTHORITATIVE
Main app entitlement ───────────────┐
                                    ▼
                             entitlement.json
                                    │
                                    ▼
                          entitlementState
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
             "premiumActive"              "free" OR "unavailable"
                    │                               │
                    ▼                               ▼
       Layer 3 premium may execute        Layer 3 premium STOPS
                                          immediately — no grace window,
                                          no fallback to a prior cached
                                          "premiumActive" value under
                                          any circumstance.

Rule generation follows an entirely separate fallback path:

          generationStatus: "unavailable"
                    │
                    ├── storage.local copy within 4-hour bound → use it
                    └── beyond 4 hours → disable affected Layer 3 behavior
```

**Filtering data may be eventually consistent. Authorization may not:**
`entitlementState` is re-derived fresh at every mandatory refresh point
(background wake, 15-minute cache expiry) with no bounded-staleness
fallback of its own. A native-read failure on the entitlement check
produces `"unavailable"`, which JS treats identically to `"free"` for
feature-gating purposes: Layer 3 premium behavior does not run.

This is distinct from `generationStatus: "unavailable"`, which does get the
4-hour last-known-good grace window, since stale filtering data is a
quality degradation while stale-and-unrefreshed entitlement is a business-
logic correctness failure.

If `fetchGeneration` is called for a generation number that no longer
exists on disk (the ADR-0011 retention race), the native handler:
1. Re-reads `current.json` once.
2. Retries resolution against whatever generation that pointer now names.
3. If that also fails (validation failure, still missing, corrupt), the
   native handler returns `{ generationStatus: "unavailable" }` — never a
   partial or best-guess payload.

On receiving `unavailable`, JS retains its last-good `storage.local` copy
if one exists (graceful degradation) bounded to **4 hours**. Beyond 4 hours,
JS disables Layer 3 filtering behavior entirely. Layer 1/2 are unaffected —
this is a Layer 3-only fail-safe.

### 6. Entitlement is never independently re-derived by JS

JS never checks StoreKit, never infers premium status from any other
signal. `entitlementState` in the `checkVersion` response is the sole
source of truth for whether Layer 3 premium behaviors run at all — this
keeps StoreKit logic entirely in the main app, consistent with ADR-0011's
decision to decouple entitlement from the generation lifecycle.

## Performance and battery

- **Main thread:** none — all native reads happen on the extension's
  request-handling queue, not the JS main thread; content-script requests
  to background are async message passing.
- **Memory:** background's in-memory cache is one generation's decoded
  rules plus a small entitlement record — bounded by ADR-0011's
  (still-to-be-set) size budget.
- **Disk I/O:** one cheap `checkVersion` read per refresh point (page
  activation subject to the 15-minute ceiling, or background wake); the
  expensive `fetchGeneration` read only on an actual version change — this
  is the bound ADR-0011's correction required.
- **Network/radio:** zero — this entire protocol is local IPC between the
  app's own processes, no network calls of any kind.
- **Battery:** negligible; cost is proportional to matched-page activation
  frequency (bounded by ADR-0010's match-driven ceiling) and the 15-minute
  cache ceiling, not to any polling loop.

## Consequences

- Real background-context lifetime (how often Safari actually suspends
  a non-persistent event page in practice) should be measured during
  Sprint 9 implementation and may justify tuning the 15-minute figure —
  this ADR fixes the *existence* of a ceiling and a reasonable starting
  value, not a number that can never change.
- The 4-hour Layer 3 fail-safe means a sustained native-read failure
  degrades gracefully and visibly (features quietly stop working) rather
  than either crashing or running forever on stale entitlement.
- `"unavailable"` and `"free"` behave identically for feature-gating
  (no premium Layer 3 behavior either way), but should be surfaced
  distinctly in main app UI diagnostics to avoid confusing paying users.
- `ADBLXSafariWebExtension.entitlements`' existing App Group access is
  now actually exercised by this design — the native handler reads
  `current.json`, the active generation's `rules.json`, and
  `entitlement.json`, all read-only from the extension side (writes
  remain main-app-only, consistent with every other extension's role in
  this project).
