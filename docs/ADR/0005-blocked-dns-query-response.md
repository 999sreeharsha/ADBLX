# 0005 — Blocked DNS query response: NXDOMAIN, not sinkhole

**Date:** 2026-08-24
**Status:** Accepted

## Context

Once a DNS query legitimately reaches the filtering engine (a question
answered independently of ADR-0004's capture-mechanism outcome — this ADR
concerns behavior *after* a query arrives, whatever route got it there),
SHIELD must synthesize some response for a matched/blocked domain.

Neither `adblock-prd-v1.1.md` nor `TargetTopology.md` specifies a response
format — this ADR has no existing SSOT constraint to reconcile against.
It does have one source-data tension to resolve explicitly: OISD and
HaGeZi (PRD Appendix A) ship in hosts-file format, mapping blocked domains
to a sinkhole address (conventionally `0.0.0.0`). Adopting NXDOMAIN means
SHIELD's parser extracts only the domain from each entry and discards the
mapped address — a deliberate reinterpretation of the source format, not
an accident of parsing.

### Options considered

| Strategy | Behavior | Assessment |
|---|---|---|
| NXDOMAIN | Name does not exist | Clean semantic failure; client fails fast, no connection attempt |
| NODATA/NOERROR | Name exists, no record of requested type | Ambiguous for blocking; some clients retry other record types before giving up |
| Sinkhole IPv4/IPv6 (`0.0.0.0`, loopback) | Resolves to an address that won't serve the content | Client still attempts a connection; `0.0.0.0` as a destination has undefined/hang-prone behavior on some stacks, loopback risks ECONNREFUSED noise or, if something happens to listen locally, unintended behavior |
| Synthetic local answer | Controlled answer, custom TTL/flags | Most flexible, but SHIELD now owns full DNS-correctness surface (flag bits, EDNS, record-type coverage) for every blocked reply |

## Decision (revised)

**NXDOMAIN is the primary blocked-domain response strategy**, applied to
the matched qname regardless of query type. Rationale:

1. **Performance/battery**: NXDOMAIN prevents SHIELD from returning a
   routable address for the blocked qname through the filtering resolver,
   normally avoiding a subsequent connection attempt based on that
   resolution — client retry/racing behavior is resolver-implementation-
   dependent and not guaranteed, but this is the best available signal at
   the DNS layer, and strictly better than a sinkhole address a client
   will attempt to connect to regardless.
2. **Bounded caching**: blocked responses must use a bounded caching
   strategy so that filter updates and explicit unblocking do not leave
   domains unavailable for an excessive period. The exact DNS response
   structure and cache-control behavior (including whether/how an SOA is
   synthesized) are implementation details for Sprint 8B and must be
   validated for standards compliance, not assumed here.
3. **Ecosystem note (external, not core justification)**: some browsers'
   DoH-upgrade decisions key off a canary domain's resolution outcome —
   Firefox's `use-application-dns.net` check is one documented example.
   Whether NXDOMAIN on that domain still keeps a given browser on the
   system resolver is browser-version-dependent field behavior, to be
   re-verified as part of ADR-0007, not relied on as justification here.

## Verification note (lightweight, distinct from ADR-0004's gate)

Whether iOS's stub resolver and third-party apps uniformly treat a
tunnel-synthesized NXDOMAIN the same as an authoritative one — no
retry-storms, no silent fallback to a secondary/system resolver — is a
real-device fact, not something to assume from RFC text alone. This
should be folded into Sprint 8B's device verification pass as a companion
check alongside ADR-0004's feasibility matrix, not stood up as a second
full gate: confirm blocked-domain behavior is a clean, single failure with
no client-side retry loop, across at least Safari and one third-party app
that does its own connection racing (e.g. an app implementing Happy
Eyeballs–style parallel connection attempts).

## Consequences

- Filter parsing (backend `Publisher` tool and/or client-side hosts-list
  ingestion) discards the sinkhole IP column from OISD/HaGeZi source data
  entirely — domain match is the only signal carried forward. Worth a
  one-line note in whichever component does that parsing, so a future
  maintainer doesn't "fix" what looks like a dropped field.
- SHIELD does not need to run or maintain any listening service at a
  sinkhole address — no additional attack surface, no additional process.
- If Sprint 8B's verification surfaces a client that mishandles synthesized
  NXDOMAIN (rare, but not zero-probability on iOS's networking stack),
  this ADR is the one that gets reopened — not ADR-0004, since capture and
  response-semantics are independent failure modes.
