# 0006 — Upstream resolution: preserve network resolver, explicit loop avoidance

**Date:** 2026-08-24
**Status:** Proposed

## Context

For a query that legitimately reaches the filtering engine and is *not*
blocked (ADR-0005 covers the blocked path), SHIELD must forward it to some
upstream resolver and return the real answer. Two independent risks exist:
(a) silently changing the user's DNS provider, and (b) the forwarded query
looping back into the tunnel it originated from.

### Options considered

1. **Fixed public upstream resolver** (e.g. hardcoded `1.1.1.1`/`8.8.8.8`).
   Simple loop-avoidance story — the upstream is a known-external address,
   trivially outside the tunnel's own routes. But this silently relocates
   every allowed query's visibility to a third party the user never chose,
   which is a real, undisclosed shift in the product's privacy posture —
   not something G5 ("zero data collection") was written to authorize, and
   not something to introduce as an implementation-convenience default.
2. **Preserve the pre-tunnel/network-selected resolver.** Captures
   whatever DNS servers the network (DHCP, Wi-Fi config, or an MDM/DoH
   profile) already provided, before SHIELD's tunnel installs its own
   `NEDNSSettings`, and forwards to that. Best preserves existing user/
   network trust relationships and intent. Requires reliably capturing
   that state at the right moment — a real implementation question, not
   a given.
3. **Use the system resolver from inside the tunnel.** Attractive on
   paper (no separate capture step) but risks resolving through the
   tunnel's own configured DNS settings — i.e., through itself. **Treated
   as unsafe by default** unless Sprint 8B produces device evidence that
   a specific implementation path genuinely bypasses the tunnel's own
   routing for its own outbound queries.
4. **Local recursive resolver** (SHIELD performs iterative resolution
   from root/TLD down, no upstream forwarding at all). Rejected for v1:
   meaningfully higher CPU, memory, and battery cost than a forwarding
   design, plus its own cache/staleness management — no PRD requirement
   currently justifies this, and NFR-02's battery budget argues against
   it directly. Revisit only if a future requirement (e.g. resistance to
   upstream-resolver-level censorship/logging) explicitly demands it.

## Decision

**Preserve the network-selected upstream resolver as the primary
strategy.** SHIELD captures the device's pre-tunnel DNS configuration
before `ADBLXPacketTunnel` installs its own `NEDNSSettings`, and forwards
allowed queries to that captured resolver rather than to a SHIELD-chosen
default.

**Loop avoidance requirement:** the forwarding path for an allowed query
must not re-enter `ADBLXPacketTunnel`'s own routing scope. iOS's Network
Extension framework is understood to generally exclude a provider's own
self-originated connections from being routed back through its own
tunnel — this is the documented mechanism that lets any packet-tunnel VPN
reach its own remote endpoint at all — but this project should not treat
that as proven for our specific configuration until confirmed on-device
alongside ADR-0004's feasibility gate. If self-exclusion doesn't hold
reliably for the chosen Model A routing scope, the forwarding mechanism
must be redesigned before any DNS filtering ships, not shipped with an
assumed-safe loop path.

**Fallback policy is a separate, explicit decision — not a silent
default.** If capturing the pre-tunnel resolver proves unreliable across
the real-device matrix (interface transitions, VPN-already-active,
DoH/DoT-configured networks), SHIELD does **not** silently fall back to a
hardcoded public resolver. That fallback, if ever needed, requires its own
documented product/privacy decision — including what it discloses to
users, whether it's opt-in, and how it's described in the privacy-audit
materials PRD §10 anticipates — not an invisible default baked into this
ADR or into Sprint 8B code.

## Verification note

Capturing "the pre-tunnel resolver" reliably is itself the crux of this
ADR and needs its own confirmation pass in Sprint 8B: what mechanism
reads current DNS configuration from the main app or extension context
before `setTunnelNetworkSettings` takes effect, whether that mechanism
works identically for Wi-Fi/cellular/MDM-configured-DoH networks, and
whether it survives interface handoff without going stale. This folds
into the same device-verification effort as ADR-0004's gate and ADR-0005's
client-behavior check, rather than standing up a fourth separate pass.

## Consequences

- No third-party DNS provider is introduced into SHIELD's architecture by
  default — consistent with the "nothing about you ever leaves your
  phone [to somewhere we chose]" positioning, made explicit rather than
  incidental.
- If pre-tunnel resolver capture fails the feasibility check, Sprint 8B
  implementation pauses on the allowed-query path specifically (the
  blocked-query path from ADR-0005 is unaffected) until a fallback policy
  is deliberately decided and documented — this is a second, narrower gate
  alongside ADR-0004's, not a reason to reopen ADR-0004 itself.
- This decision has no bearing on Model A vs. any reopened alternative
  from ADR-0004 — upstream selection is orthogonal to how the query
  reached the filtering engine in the first place.
