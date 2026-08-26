# 0006 — Upstream DNS Resolution Architecture & Privacy Disclosure Contract

**Date:** 2026-08-25  
**Status:** Resolved & Adopted  
**Deciders:** ADBLX Architecture Team  
**Supersedes:** Proposed pre-tunnel discovery design (Sprint 8B-0)

---

## 1. Context & The Blocker

During Sprint 8B-0 (Gate B), empirical testing established that iOS provides **no supported public API** (in either the `NEPacketTunnelProvider` extension or the main application) to discover dynamically assigned local DNS resolver IP addresses (such as DHCP-assigned LAN routers or cellular carrier DNS).

Attempts to access system resolver state via `/etc/resolv.conf`, `res_state`, or private `libresolv` symbols are strictly blocked by the iOS sandbox (`deny(1) file-read-data`) and violate App Store Review Guideline 2.5.1 (Private APIs).

Furthermore, routing DNS queries through proprietary intermediary cloud proxies or silently falling back to undisclosed third-party IPs without user knowledge violates ADBLX's zero-telemetry privacy mandate.

---

## 2. Decision & Production Architecture

### 2.1 Upstream Resolver Selection
1. **Default Shipped Resolver:** **Quad9** (`9.9.9.9:53` IPv4 and `2620:fe::fe:53` IPv6).
   - **Entity & Jurisdiction:** Non-profit Foundation headquartered in Zürich, Switzerland, subject to the Swiss Federal Data Protection Act (FADP) and GDPR.
   - **Privacy Policy:** Strict zero-logging of end-user IP addresses; no monetization or resale of query telemetry ([quad9.net/privacy](https://www.quad9.net/privacy)).
   - **Security Filter:** Built-in threat intelligence blocking malicious/phishing domains at the upstream layer.
2. **Custom Resolver Option (Production Feature):**
   - Users may configure any custom IPv4 or IPv6 resolver address (e.g. local Pi-hole, router gateway `192.168.1.1`, or corporate DNS) with live format validation.
3. **UI Placement & Disclosure:**
   - Resolver configuration is surfaced in **DNS Protection Settings** (`DNSProtectionView`).
   - Quad9 is pre-selected as the default with a `"RECOMMENDED"` badge.
   - **Activation Confirmation:** A one-time activation confirmation is presented when the user first enables DNS Protection, explicitly disclosing that non-blocked queries are resolved via Quad9 and that custom resolvers can be configured at any time.

### 2.2 Privacy & Data Flow Contract
- **Traffic Path:** Allowed (non-blocked) DNS queries exit the device directly from the `ADBLXPacketTunnel` BSD UDP socket to Quad9 (or the user-configured custom IP) over standard UDP Port 53 via `NEPacketTunnelNetworkSettings.ipv4Settings.excludedRoutes`.
- **Zero Intermediary:** ADBLX operates no cloud servers, proxies, or relays. ADBLX never collects, receives, inspects, or stores user DNS queries or browsing history.

---

## 3. User-Facing Disclosure Language

```text
Quad9 (Default) — Recommended
9.9.9.9 & 2620:fe::fe — Encrypted upstream with threat blocking and zero IP logging.
Allowed DNS queries are sent directly to Quad9, a Swiss non-profit foundation.
ADBLX does not collect, receive, or store your browsing or DNS data.
```

---

## 4. Regulatory & Apple Privacy Compliance Audit

### 4.1 Apple Privacy Manifest (`PrivacyInfo.xcprivacy`)
Under Apple's privacy manifest framework:
- **`NSPrivacyTracking`:** Set to `false`. ADBLX does not track users across third-party apps or websites.
- **`NSPrivacyCollectedDataTypes`:** Set to empty array `[]`. ADBLX collects **0 data types**.
- **`NSPrivacyAccessedAPITypes`:** Only standard `NSPrivacyAccessedAPICategoryUserDefaults` (for local user settings storage) declared with legitimate reason `CA92.1` (App functionality).

### 4.2 App Store "App Privacy" Nutrition Label
On the App Store product page:
- **Recommended Category:** *"Data Not Collected"*.
- **Rationale:** ADBLX collects no identifiers, usage data, diagnostics, or contact info. The third-party DNS resolver is an external network endpoint selected by user policy to perform network resolution, not an in-app telemetry service.
- **Pre-Submission Requirement:** Final declaration must be checked against Apple's current published App Privacy Details documentation and reviewed with counsel or App Review specialist prior to App Store Connect submission.

---

## 5. Consequences & Boundaries

- **Positive:** Completely solves the dynamic resolver blocker with 100% public APIs, zero sandbox violations, full transparency, and zero user IP logging.
- **Limitation (ADR-0007):** Corporate split-horizon domains requiring local DHCP DNS will fail unless the user configures their local router IP as their custom resolver. This boundary is documented in product FAQs.
- **Status:** **ADR-0006 IS FULLY CLOSED AND ADOPTED.**
