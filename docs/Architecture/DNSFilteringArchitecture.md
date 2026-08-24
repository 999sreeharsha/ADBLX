# DNS Filtering Architecture

**Path:** `docs/Architecture/DNSFilteringArchitecture.md`
**Status:** Living document — architecture decisions only, no implementation.

## 1. Purpose

Defines the architecture and decision boundaries for SHIELD's premium
on-device DNS filtering layer (FR-11) before implementation. Sprint 8.1
produces architecture decisions only. No packet-tunnel lifecycle, DNS
parser, hosts-list lookup, or Network Extension implementation is
introduced by this document or this sprint.

## 2. Architecture overview

```text
Main App
    │
    ├── Downloads / validates filter sources
    ├── Parses and normalizes hosts-format lists
    ├── Builds immutable lookup artifact
    └── Atomically publishes artifact through App Group
              │
              ▼
      ADBLXPacketTunnel
              │
              ├── Receives DNS queries per ADR-0004's routing model
              ├── Performs immutable domain lookup (ADR-0008)
              ├── Blocked → ADR-0005 (NXDOMAIN)
              └── Allowed → ADR-0006 (forward to preserved resolver)
```

## 3. Decision map

**ADR-0003 — Traffic scope — Accepted**
`ADBLXPacketTunnel` uses `NEPacketTunnelProvider` as a local VPN
configuration, not a DNS-only shim. Minimum routing scope is determined
by ADR-0004.

**ADR-0004 — DNS interception model — Proposed / Conditional**
Scoped DNS routing (Model A) is the primary hypothesis. Sprint 8B Gate A
must prove reliable DNS capture across the real-device matrix before this
ADR moves to Accepted. Failure does not auto-authorize a general relay
architecture — it reopens this ADR.

**ADR-0005 — Block response — Accepted**
Matched domains receive NXDOMAIN, using a bounded caching strategy whose
exact structure is a Sprint 8B implementation detail.

**ADR-0006 — Upstream resolution — Proposed**
Preserve the network-selected resolver where feasible; no silent fallback
to a SHIELD-selected public resolver. Not yet Accepted — reliability of
resolver capture and loop-avoidance both depend on the same device
evidence ADR-0004 requires (Gate A/B).

**ADR-0007 — Encrypted DNS boundary — Accepted**
Encrypted-DNS bypass is an explicit, bounded v1 coverage limitation, not
something SHIELD attempts to defeat via port-blocking or TLS interception.
NEURLFilter is tracked, not adopted (server dependency + unsettled
consumer-device availability).

**ADR-0008 — Lookup representation — Proposed / partially settled**
Accepted in substance: main app builds an immutable artifact; the
extension performs zero compilation and zero per-query disk I/O.
Benchmark-gated: matching semantics (exact vs. domain-plus-subdomains,
pending source-list verification) and physical representation (Set / trie
/ sorted array / compact index), decided by Gate C.

## 4. Sprint 8B evidence gates

**Gate A — DNS capture** (ADR-0004)
Wi-Fi · Cellular · interface transitions · sleep/wake · tunnel restart ·
blocked-domain leak prevention · allowed-domain resolution · normal
traffic continuity · VPN conflict. Failure reopens ADR-0004.

**Gate B — Upstream preservation** (ADR-0006)
Pre-tunnel resolver discovery · interface-transition behavior · loop
avoidance · stale-resolver handling. No silent public-resolver fallback.

**Gate C — Lookup benchmark** (ADR-0008)
Real source-list scale (sized before the benchmark, not assumed) ·
artifact build time · peak main-app memory · tunnel steady-state memory ·
lookup latency · packet-path CPU. Representation selected from measured
results, against the tunnel's *actual measured* memory ceiling — not a
hardcoded figure.

**Gate D — Battery and energy** (NFR-02)
Measured separately: tunnel idle · DNS forwarding only · active blocking ·
ad-heavy browsing. Target: <3% battery/day.

## 5. Explicit non-goals for Sprint 8.1

Not implemented this sprint: `NEPacketTunnelProvider` lifecycle · packet
parsing · TCP/IP relay · DNS parser · hosts parser inside the extension ·
encrypted-DNS interception · TLS interception · hardcoded third-party DNS
fallback · filter truncation to fit an assumed memory budget · general
traffic inspection · logging of DNS or browsing activity.

## 6. Transition to Sprint 8B

Sprint 8B begins with an evidence-producing gate (**8B-0**), not feature
implementation. Gates A–D run before any DNS-filtering code is considered
production-track. A gate failure reopens its source ADR; it does not
authorize scope expansion beyond what that ADR's non-fallback clause
permits.

> Sprint 8.0 → Sprint 8.1 (this document) → **Sprint 8B-0 (feasibility
> gates)** → Sprint 8B implementation (only for gates that pass)
