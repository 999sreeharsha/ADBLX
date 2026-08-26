# 0010 — Safari Web Extension execution and update model

**Date:** 2026-08-25
**Status:** Proposed

## Context

`ADBLXSafariWebExtension` (Layer 3) exists in the topology as an empty
shell: Manifest V2, no permissions, no content scripts, a three-line echo
handler, no App Group usage despite entitlement access already being
configured. Sprint 9 establishes what runs where, what's fixed at app
release versus updatable via the existing filter pipeline, and what
Apple's platform actually permits — before any Layer 3 behavior (YouTube
handling, cosmetic filtering, anti-adblock) is designed on top of it.

This ADR does not decide the data-publication mechanism (ADR-0011), the
native↔JS protocol (ADR-0012), or Layer 3's functional scope (ADR-0013).
It decides the execution model those three build on.

## Decision

1. **Manifest V3.** Sprint 9 targets `manifest_version: 3`, not the
   scaffold's current V2. This is the forward-looking, App-Store-aligned
   format; Chrome has already fully deprecated V2, and building new Sprint
   9 work against V2 would create migration debt with no offsetting
   benefit.

2. **Background model: `background.scripts`, not `background.service_worker`.**
   Even under `manifest_version: 3`, the extension's background context
   uses the `scripts` array (event-page form), not the `service_worker`
   field. This is a Safari-specific choice, not a stylistic one: Safari's
   `service_worker`-form background scripts have a currently open,
   Apple-acknowledged bug preventing any Develop-menu debugging access,
   with no fix timeline. `scripts`-form remains fully debuggable and is
   Apple's own documented workaround. Revisit only if Apple's own guidance
   changes — do not rediscover this by hitting the bug during
   implementation.

3. **Executable-code boundary.** All JavaScript and native Swift logic —
   DOM traversal, mutation-observer behavior, YouTube detection/
   intervention algorithms, the native↔JS message protocol itself, and any
   heuristic defining what constitutes an advertisement — is fixed at app
   binary release and changes only via an App Store submission. Nothing
   about *how* a rule is interpreted is remotely updatable.

4. **No remote executable code.** The extension never fetches, evaluates,
   or dynamically loads JavaScript, WASM, or any other behavior-changing
   payload at runtime, from any source — not the filter CDN, not a
   redirect, not a bundled-but-conditionally-loaded alternate script. Only
   inert data (domains, CSS selectors, feature flags, numeric thresholds,
   generation/version metadata, entitlement state) is updatable, via the
   same App Group publication mechanism ADR-0011 defines. This is an App
   Store Review Guideline 2.5.2 compliance boundary, not a preference —
   violating it risks rejection or removal regardless of intent.

5. **Scope: iOS/iPadOS Safari only.** Sprint 9's design and verification
   target iOS and iPadOS Safari exclusively. macOS and visionOS Safari
   Web Extension behavior is explicitly out of scope for this sprint and
   is not addressed, tested, or assumed — this does not resolve
   TargetTopology.md's deferred Platform Strategy ADR, and should not be
   read as narrowing that ADR's eventual scope. It simply means Sprint 9
   doesn't depend on an answer to a question that hasn't been asked yet.

6. **Activation must be event- or match-driven.** Content scripts run only
   on pages matching declared `content_scripts.matches` patterns (or an
   equivalent narrow, declarative trigger) and background-script logic
   runs only in response to genuine browser/extension events (installed,
   message received, tab matched). No global always-on DOM observation, no
   polling timer to check for updates, no work performed on pages outside
   the extension's actual scope (YouTube domains, and whatever narrow set
   ADR-0013 defines for cosmetic/anti-adblock intervention).

## Caching-authority consequence (stated here, refined in ADR-0012)

Because decisions 3 and 4 mean the native side can never proactively push
a change to JS (per the pull-only messaging model this ADR's execution
boundary implies — see ADR-0012 for the mechanism), a cached value on the
JS side — most importantly entitlement state — must never be treated as
indefinitely valid just because it was successfully retrieved once. A
premium lapse that isn't re-checked at a defined activation point is
functionally indistinguishable from a permanent entitlement, which
violates the same "protection must not silently persist past
subscription lapse" principle already flagged as an open item for the DNS
tunnel. ADR-0012 must define the specific points at which JS is required
to re-fetch entitlement state — this ADR establishes that an *undefined*
refresh point is not an acceptable answer, not what those points are.

## Consequences

- Sprint 9 implementation replaces the scaffold's Manifest V2 files
  (`manifest.json`, `background.js`, `SafariWebExtensionHandler.swift`)
  rather than incrementally extending them — there's no runtime behavior
  in the current stub worth preserving (confirmed by the Sprint 9 repo
  audit), so this is a clean rewrite, not a migration.
- `SafariWebExtensionHandler.swift`'s current echo behavior
  (`["echo": message]`) is discarded entirely in favor of the structured
  request/response protocol ADR-0012 defines.
- If Apple's YouTube-detection-relevant DOM structure changes in a way
  that requires new *logic* rather than new *selectors/data*, SHIELD
  cannot respond without an App Store release. This is a deliberate,
  disclosed limitation of decisions 3–4, not an implementation gap — it
  should be stated plainly in the Sprint 9 closure documentation the same
  way ADR-0007 stated the encrypted-DNS limitation, not discovered later
  as a surprise when YouTube changes something.
- No performance/battery cost analysis is owed by this ADR specifically —
  it constrains *where* code runs and *what* can change without a release,
  not the runtime cost of any specific Layer 3 feature. Decision 6 sets
  the ceiling (event-driven only) that ADR-0013's admission criteria for
  individual features will be measured against.
