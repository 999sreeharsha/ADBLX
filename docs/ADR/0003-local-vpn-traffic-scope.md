# 0003 — Local-VPN traffic scope, not DNS-only interception

**Date:** 2026-08-24
**Status:** Accepted

## Context

FR-11 requires on-device DNS filtering via `ADBLXPacketTunnel`
(`NEPacketTunnelProvider`). The open question: should the tunnel intercept
only DNS traffic, or claim broader routing scope as a genuine local VPN?

### Apple-documented constraints

- `NEDNSProxyProvider` is documented as supported only on supervised
  (MDM-managed) iOS devices — not viable for a retail App Store app. This
  rules it out entirely, not as a licensing/tier question but a
  device-supervision requirement.
- `NEPacketTunnelProvider` operates at the IP layer only; Apple's WWDC25
  Network Extension session states it does not receive flow- or
  application-level metadata, and that the Content Filter API is the
  intended surface for pure content-filtering verdicts.
- TN3120 documents the packet tunnel's supported use case as implementing
  a real VPN client, precisely because Apple sees frequent attempts to use
  it as a narrow DNS/content-filter shim instead.

### Field-observed precedent

- Multiple Apple DTS engineers, across separate forum threads, state that
  a packet tunnel used as a content filter without properly functioning as
  a VPN is not something DTS supports, and describe developers hitting
  silently-ignored DNS settings or query timeouts when the tunnel isn't
  operating as the device's actual default-route VPN.
- Shipping consumer apps demonstrate that local VPN-based DNS protection is
  an established product pattern; their internal forwarding architectures
  are not treated as authoritative specifications for SHIELD.

## Decision

`ADBLXPacketTunnel` will operate as a genuine local `NEPacketTunnelProvider`
VPN rather than a narrow DNS-port interception mechanism.

The tunnel will claim the routing scope required by the selected
packet-tunnel architecture, including the default-route configuration if
confirmed by ADR-0004's implementation model.

ADBLX's filtering responsibility remains intentionally limited:

1. DNS queries are eligible for domain-based filtering according to
   ADR-0005 through ADR-0008.
2. Non-DNS traffic is not an ADBLX filtering surface. It must continue to
   function correctly and must not be inspected, persisted, or logged for
   ad-blocking purposes.
3. The concrete mechanism by which DNS traffic is intercepted and non-DNS
   traffic is forwarded is explicitly deferred to ADR-0004. This ADR does
   not prescribe a userspace TCP/UDP relay implementation.
4. The VPN remains entirely local from SHIELD's perspective: no user
   traffic is sent to SHIELD-operated infrastructure, and no browsing or
   DNS history is collected.

## Consequences

- The selected forwarding model may place some or all device traffic on
  the extension's hot path. ADR-0004 must therefore establish explicit
  CPU, memory, latency, and energy budgets before Sprint 8B implementation
  begins.
- One-active-VPN-at-a-time (PRD §10) is unchanged; VPN-conflict
  detection/UX (FR-11) is unaffected by this decision.
- App Store review risk is not increased by committing to a genuine VPN
  architecture — a tunnel that behaves like the documented use case is
  lower risk than one that doesn't, regardless of what ADR-0004 decides
  about the forwarding mechanism's scope.
