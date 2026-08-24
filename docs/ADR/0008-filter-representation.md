# 0008 — Filter representation: main-app-built immutable artifact, benchmark-gated structure

**Date:** 2026-08-24
**Status:** Proposed / partially settled

## Context

`ADBLXPacketTunnel` must answer "is this domain blocked?" on every DNS
query reaching the filtering path (ADR-0004's outcome determines which
queries those are, but not how many domains are checked against). The
governing principle, consistent with the existing pipeline's
main-app-only compilation boundary (PRD §6.2, TargetTopology.md's
`Filtering/` module):

> The main app performs all expensive normalization, parsing,
> deduplication, and index construction. The packet-tunnel extension
> receives an already-prepared immutable lookup artifact and performs no
> filter compilation.

This mirrors the Content Blocker pipeline's existing division (compile in
`ADBLX`, consume in the extension) rather than inventing a new pattern.

### Correcting the memory-budget assumption

The extension's constraint is **not** the Content Blocker's ~6 MB figure
— that applies to `com.apple.Safari.content-blocker` extensions
specifically. `com.apple.networkextension.packet-tunnel` extensions have
their own, separately-set, historically higher limit; Apple engineering
support has confirmed current figures around 50 MiB on modern iOS, risen
from 15 MiB, risen from an original ~5–6 MiB — but has also stated plainly
that none of these numbers are officially documented, are not stable
across iOS versions or devices, and should not be hardcoded into product
logic. Sprint 8B must measure the actual ceiling on representative test
devices/iOS versions directly (Jetsam `per-process-limit` termination is
the empirical signal, not a published constant) rather than design against
any number written here, including the ones cited above.

## Two separable decisions

This ADR treats matching semantics and physical representation as
independent questions, resolved in that order — the representation choice
follows from the semantics choice, not the reverse.

### Decision 1 — Matching semantics: domain-plus-subdomains, pending confirmation

A hosts-format entry (`0.0.0.0 ads.example.com`) could mean exact-name-only
match, or match on `ads.example.com` and every subdomain beneath it
(`foo.ads.example.com`, etc.). This is a real behavioral fork, not a
representation detail:

- **Exact-match only**: simplest, cheapest, but under-blocks in practice —
  ad/tracking infrastructure commonly rotates through subdomains under a
  stable base domain specifically to evade static blocklists, and
  OISD/HaGeZi-class lists are maintained with the expectation that
  consuming blockers apply subdomain-inclusive matching (this is the
  behavior Pi-hole, AdGuard Home, and NextDNS all implement by default).
- **Domain-plus-subdomains**: matches the ecosystem convention these
  source lists are authored against, at the cost of a per-query
  label-walk instead of a single hash lookup.

**Recommendation, subject to confirmation against actual list-author
documentation for each source in Appendix A before freezing**:
domain-plus-subdomains as the default match behavior, since exact-match-only
would silently under-deliver against G1 (≥95% block rate) relative to what
these specific lists are designed to achieve. This is the one item in this
ADR I'd flag as needing a source-list-documentation check, not just an
architecture judgment call, before Sprint 8B locks it in.

### Decision 2 — Physical representation: benchmark-gated, not pre-selected

| Structure | Lookup | Memory | Build cost | Assessment |
|---|---|---|---|---|
| `Set<String>` (normalized, exact-match) | ~O(1) | High per-entry overhead (Swift string/hashing machinery) at OISD/HaGeZi scale | Low | Reasonable baseline for a quick spike, likely not the shipped structure at scale |
| Reversed-label trie | O(label count) | Node-overhead-dependent — naïve `class`-per-node Swift trie is unacceptable; only viable compacted (e.g. array-backed, indices not pointers) | Higher | Best semantic fit *if* Decision 1 lands on domain-plus-subdomains — natural prefix-walk from TLD inward |
| Sorted normalized array + binary search | O(log n) | Predictable, compact — a flat buffer of fixed/interned strings | Low/moderate | Strong baseline; simplest structure that could plausibly ship as-is if exact-match wins Decision 1 |
| Compact serialized index (custom binary format, built in main app) | O(log n) or better | Best control — main app owns exact layout, extension just maps/reads it | Highest | Likely production direction if either Set or sorted-array measurements exceed budget at real list scale |

No structure is selected here. This ADR commits to a **benchmark gate**,
executed in Sprint 8B before any structure is written into
`ADBLXPacketTunnel`, using the actual merged OISD + HaGeZi + Peter Lowe's +
regional list scale — which is a materially larger scale than the PRD's
Appendix C India list (2–5K rules) and needs its own explicit sizing check
against current upstream list sizes before the benchmark runs, not an
assumed round number.

## Acceptance envelope for the benchmark gate

- No raw OISD/HaGeZi text parsing inside `ADBLXPacketTunnel` — all
  parsing, normalization, deduplication, and structure-building happens in
  the main app, matching `CompositionService`'s existing role for Content
  Blocker rules.
- The extension receives one immutable, pre-built artifact via the App
  Group container and performs no compilation.
- Zero disk I/O on the per-query DNS lookup path — the artifact is loaded
  once (mapped or fully resident, per Decision 2's outcome) at tunnel
  start, not re-read per query.
- No main-thread work — irrelevant inside the extension process itself
  (no UI thread there), but the main app's artifact-build step must stay
  off its main actor, consistent with the existing Definition of Done.
- Extension lookup latency benchmarked independently of main-app compile
  time, using `os_signpost` around the lookup call specifically.
- Memory measured against the actual current packet-tunnel ceiling for
  the target device/iOS matrix (measured directly per the caution above,
  not the figures cited in this document's Context section), with
  explicit headroom reserved for packet parsing, DNS query/response
  construction, and Network Extension framework baseline overhead — none
  of which this lookup structure's budget should be assumed to include.
- Main-app artifact construction remains within NFR-01's existing
  <200 MB / <10s-per-100K-rules budget — this is an *additional* consumer
  of that same compilation pipeline, not a separate budget to invent.
- A defined regression threshold (specific percentage/absolute figures set
  during the Sprint 8B spike once real list-scale numbers are in hand) 
  gates acceptance of whichever structure is chosen — this ADR commits to
  the *existence* of a threshold, not a number invented without data.

## Consequences

- Decision 1 (matching semantics) has a real correctness deadline: it
  needs settling before Decision 2's benchmark can be meaningfully run,
  since trie-vs-array cost profiles diverge specifically based on whether
  subdomain matching is in scope.
- If the benchmark gate shows every candidate structure exceeding the
  measured tunnel ceiling at real list scale, that is not a signal to
  silently drop coverage (e.g., truncating the merged list) — it's a
  signal to reopen this ADR with the actual numbers, the same discipline
  ADR-0004 applies to its own feasibility gate.
- This ADR has no dependency on ADR-0004's outcome — the lookup structure
  is correct regardless of which routing/capture model the tunnel
  ultimately uses, since it only concerns "given a domain name to check,
  answer yes/no," not how that domain name arrived.
