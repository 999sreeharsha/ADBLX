# 0007 — Encrypted DNS boundary: system DNS is in scope; application-managed encrypted DNS is not guaranteed in v1

**Date:** 2026-08-24
**Status:** Accepted

## Context

SHIELD's DNS filtering architecture operates only on DNS queries that
legitimately reach `ADBLXPacketTunnel`.

ADR-0004 defines the unresolved question of how system DNS is captured.
ADR-0005 defines the response for a matched query. ADR-0006 defines how
an allowed query is forwarded.

Those decisions do not imply that every application on the device uses
the system DNS path.

Applications may implement their own encrypted name resolution, including
DNS-over-HTTPS (DoH) or DNS-over-TLS (DoT), or otherwise establish
connections using independently resolved addresses. If that resolution
does not traverse the DNS capture path selected under ADR-0004, SHIELD
cannot perform domain-level filtering on that query.

This is therefore a coverage-boundary decision, not a parser limitation.

## Decision

**SHIELD v1 guarantees filtering only for DNS resolution that reaches the
ADBLX DNS filtering path. Application-managed encrypted DNS that bypasses
that path is an explicit v1 coverage limitation.**

SHIELD v1 will not:

1. inspect encrypted DoH payloads;
2. terminate or decrypt TLS for DNS filtering;
3. maintain a broad denylist of public DoH endpoint IP addresses;
4. block TCP port 853 as a general mechanism for forcing applications back
   to plaintext or system DNS;
5. claim that DNS protection covers every domain resolution performed by
   every application.

Blocking known DoH/DoT transports to force fallback is rejected for v1.
It would create a brittle, continuously-maintained network-control surface,
can break applications that intentionally require encrypted DNS, and would
move SHIELD toward general traffic interference rather than its defined
domain-filtering responsibility.

## Firefox and resolver-upgrade behavior

Browser-specific resolver-upgrade mechanisms, including canary-domain
behavior such as `use-application-dns.net`, are treated as external
ecosystem behavior rather than an architectural dependency.

Sprint 8B must observe whether major supported browsers continue using
the system DNS path while SHIELD is active. A browser remaining on the
system resolver is useful compatibility behavior; it is not a guarantee
on which SHIELD's architecture depends.

Any browser that uses an independent encrypted resolver and bypasses
SHIELD's DNS capture path is recorded as a coverage limitation rather
than handled through traffic blocking or TLS interception.

## Interaction with ADR-0004

The first Sprint 8B feasibility spike must explicitly observe encrypted
DNS behavior.

The question is not whether SHIELD can decrypt encrypted DNS. It cannot
and will not in v1.

The question is:

    Which DNS-resolution paths actually reach the selected tunnel
    routing scope?

The feasibility evidence must separately classify:

- system DNS on Wi-Fi;
- system DNS on cellular;
- DNS after interface transitions;
- DNS behavior with an active encrypted-DNS system configuration, where
  supported by the test environment;
- browser/application-managed encrypted DNS, where reproducible.

Results must be recorded as one of:

- captured and filterable;
- bypasses SHIELD;
- connectivity failure;
- indeterminate / requires further investigation.

A bypass is not automatically an ADR-0004 failure if ordinary system DNS
continues to meet ADR-0004's acceptance criteria. It is instead evidence
for this ADR's documented coverage boundary.

## Privacy and App Store consequences

SHIELD does not decrypt, inspect, MITM, persist, or export encrypted DNS
traffic.

This preserves the product's local-processing and zero-collection
architecture.

It also avoids introducing certificate installation, TLS interception,
or traffic-decryption behavior that would materially increase privacy,
security, battery, and App Store review risk.

## Performance and battery consequences

The chosen boundary has negligible incremental cost beyond the normal
tunnel configuration:

- Main-thread impact: none.
- Extension CPU: no TLS decryption or encrypted-payload inspection.
- Extension memory: no certificate store, TLS state, or DoH endpoint
  database.
- Disk I/O: none on the encrypted-DNS decision path.
- Network wakeups: no additional wakeups caused by encrypted-DNS probing
  or endpoint blocking.
- Expected energy impact: negligible relative to the baseline DNS
  filtering path.

This is preferable to maintaining an active DoH/DoT endpoint-blocking
system, which would add update churn and create avoidable connectivity
failures.

## Future architecture watch

iOS 26 introduces Network Extension URL filtering, which can make
system-level filtering decisions using URL data while preserving privacy.
However, Apple's current architecture includes an off-device PIR database
and associated infrastructure.

That conflicts with SHIELD's current local-only / no-server architecture.

Therefore:

**NEURLFilter is tracked as a future architectural option, not adopted
for SHIELD v1.**

Any future adoption requires a separate ADR covering:

- server and PIR infrastructure;
- consistency with SHIELD's privacy promises;
- operational cost;
- battery and latency characteristics;
- entitlement/capability requirements;
- App Store distribution requirements.

## Future architecture watch (addendum)

Beyond the off-device PIR server requirement, NEURLFilter's availability to unsupervised consumer devices is itself unsettled in Apple's own documentation as of this writing — WWDC25 material suggests general availability, while Apple's Platform Deployment guide lists it as supervision-required, and Apple DTS's public response to this exact discrepancy did not resolve it either way. This is a second, independent reason NEURLFilter is tracked rather than adopted: even if SHIELD later accepted running PIR infrastructure, device-coverage eligibility for a retail App Store install isn't yet a settled fact. Any future ADR revisiting this must re-verify current documentation and device-coverage status, not rely on this note.

## Consequences

- Marketing and in-app copy must not describe SHIELD v1 DNS protection as
  universally blocking every tracker or advertisement across every app.
- A documented coverage matrix becomes part of Sprint 8B verification.
- Encrypted-DNS bypass behavior is a known limitation, not silently
  treated as a product defect unless the affected traffic was expected to
  traverse SHIELD's selected DNS path.
- No implementation work in Sprint 8B may add TLS interception or
  endpoint-blocking as an undocumented workaround.
