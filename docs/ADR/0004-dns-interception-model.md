# 0004 — DNS interception model: scoped-routing hypothesis, conditionally accepted

**Date:** 2026-08-24
**Status:** Proposed / Conditional — pending Sprint 8B feasibility evidence.
Not Accepted until the feasibility gate (§3) passes on real devices.

## Context

ADR-0003 committed `ADBLXPacketTunnel` to being a genuine local VPN, but
explicitly deferred the concrete forwarding/interception mechanism. This
ADR proposes that mechanism as a testable hypothesis, not an assumed fact,
because whether iOS reliably routes only DNS traffic into a tunnel's
`packetFlow` without a broader route claim is empirical behavior that
varies across iOS versions, interface types, and transition states — it
cannot be certified from documentation review alone.

## Primary hypothesis: scoped DNS routing ("Model A")

`ADBLXPacketTunnel` configures itself so that only DNS traffic is routed
into the extension's `packetFlow`, while general application traffic is
handled by iOS outside the extension entirely:

- The tunnel is a genuine `NEPacketTunnelProvider`.
- The tunnel owns a routing scope sufficient to cause system DNS queries
  to be directed at a tunnel-owned resolver endpoint, and no broader scope
  than that. The exact property required: **a tunnel-owned resolver
  endpoint whose routing causes system DNS queries to enter the packet
  tunnel without placing unrelated traffic on the extension's hot path.**
- No general TCP/UDP relay exists in this architecture. The extension
  processes only DNS packets it legitimately receives through the tunnel's
  own routing configuration.
- The precise `NEPacketTunnelNetworkSettings`, IPv4/IPv6 route
  configuration, and `NEDNSSettings` values that satisfy this property are
  **not specified here** — they are a Sprint 8B implementation detail,
  determined and verified against real devices, not frozen as an
  architectural contract in this ADR. Any address, route, or settings
  example used during 8B design discussion is illustrative only.

### Target cost profile, if the hypothesis holds

| Area | Model A target |
|---|---|
| Main-thread cost | None — tunnel work off-main |
| Extension memory | Primarily DNS parser + lookup index (ADR-0008) |
| CPU | Proportional to DNS query rate, not total traffic |
| Disk I/O | Zero on the packet path |
| Network wakeups | None beyond genuine DNS forwarding |
| Battery risk | Low, relative to a full relay architecture |
| NFR-02 (<3% battery/day) | Plausible — must still be measured, not assumed |

## Feasibility gate (first Sprint 8B implementation task)

This matrix is the acceptance criteria for adopting Model A, executed on
real devices as the first task of Sprint 8B, before any further DNS
implementation work proceeds. The governing criterion across every row is
**no silent fallback around filtering** — a single successful DNS capture
is not sufficient evidence.

| Scenario | Required result |
|---|---|
| Wi-Fi | DNS queries reach the tunnel consistently |
| Cellular | DNS queries reach the tunnel consistently |
| Wi-Fi → Cellular | No silent fallback to system resolver |
| Cellular → Wi-Fi | No silent fallback to system resolver |
| Sleep / wake | Filtering recovers correctly |
| App relaunch | Tunnel configuration remains coherent |
| Tunnel restart | DNS capture resumes |
| Blocked domain | No upstream leak |
| Allowed domain | Resolves correctly |
| Normal HTTPS traffic | Works without entering the relay path |
| Real VPN already active | Conflict surfaced; SHIELD does not silently supersede it |

## Failure condition

If any required scenario shows Model A losing DNS capture, falling back to
the system resolver, leaking a blocked domain, breaking connectivity, or
behaving inconsistently across interface transitions, **Model A is
rejected for production** regardless of its battery profile. Sprint 8B's
DNS-implementation work pauses at that point, and this ADR is reopened.

## Explicit non-fallback clause

Failure of the scoped-routing model does not automatically authorize
implementation of a full userspace TCP/IP relay, or any other
broader-traffic-claim architecture. Such an architecture requires its own
separate, evidence-based ADR — with explicit scope, performance, battery,
memory, and App Store review analysis — arrived at only after Model A's
failure mode is precisely recorded and the *minimum* architecture change
needed to close that specific gap has been evaluated. A rejected Model A
does not default-promote a general relay; it reopens the design question.

## Consequences

- Sprint 8B's first commit is a feasibility spike, not a feature commit —
  its acceptance criteria are the matrix in §3, and its output is either
  "Model A accepted, this ADR moves to Accepted" or "Model A rejected,
  documented failure mode, ADR-0004 reopened."
- Until the gate passes, ADR-0005 (block response), ADR-0006 (upstream
  resolution), and ADR-0008 (lookup structure) can proceed in parallel as
  architecture — they concern what happens to a DNS packet once it's
  inside the tunnel, not whether it arrives there — but none of their
  decisions authorize Sprint 8B feature work ahead of this gate passing.
- ADR-0007 (encrypted DNS boundary) has a partial dependency: whether
  DoH/DoT traffic even reaches the tunnel under Model A's routing scope is
  itself part of what the feasibility gate must observe, not a separate
  assumption.
