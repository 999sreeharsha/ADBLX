# Sprint 10 Pre-Implementation Reality Gate

**Date:** 2026-08-26  
**Repository:** `ADBLX`  
**Milestone:** Sprint 10.0 — Pre-Implementation Reality & Dependency Gate  
**Objective:** Establish ground-truth repository reality, resolve ADR status, execute Gate C1/C2 evidence reconciliation, classify entitlement leaks, audit DNS dependency stability, and establish independent GO/NO-GO workstream gates before starting implementation.

---

## 1. Repository Topology Verification

Topological and casing inspection confirmed **zero directory casing collisions** (e.g. `Docs/` vs `docs/`). The canonical paths across the repository are:

| Logical Area | Actual Repository Path | Status |
| :--- | :--- | :--- |
| **Main Application** | `ADBLX/` | Canonical |
| **Extensions (6 targets)** | `Extensions/` (`ADBLXAdsBlocker`, `ADBLXPrivacyBlocker`, `ADBLXAnnoyancesBlocker`, `ADBLXRegionalBlocker`, `ADBLXPacketTunnel`, `ADBLXSafariWebExtension`) | Canonical |
| **Shared Swift Package** | `Packages/ADBLXShared/` | Canonical |
| **Documentation Root** | `docs/` | Canonical |
| **ADR Directory** | `docs/ADR/` | Canonical |
| **Audit Directory** | `docs/Audit/` | Canonical |
| **Target Topology Spec** | `docs/Architecture/TargetTopology.md` | Canonical |
| **Product Requirements** | `docs/adblock-prd-v1.1.md` | Canonical |
| **Backend & Publisher** | `backend/` (`backend/tools/Publisher/`) | Canonical |

---

## 2. ADR Registry Reconciliation

### 2.1 Enumeration of Existing ADRs

Inspection of `docs/ADR/` shows the following 13 ADR files physically present:

| ADR | Filename | Title | Stated Status | Decided Subject |
| :--- | :--- | :--- | :--- | :--- |
| **ADR-0001** | `0001-manifest-json-manual-writer.md` | Publisher writes manifest.json with manual writer | Accepted | Manual deterministic JSON writer in Publisher tool |
| **ADR-0002** | `0002-rule-compiler-architecture-and-licensing.md` | Rule compiler architecture & licensing | **Proposed** | Evaluates SafariConverterLib (GPLv3) vs Clean-Room Swift Parser vs Server Pre-compilation without pre-deciding |
| **ADR-0003** | `0003-local-vpn-traffic-scope.md` | Local-VPN traffic scope | Accepted | Scoped Port 53 UDP DNS-only routing |
| **ADR-0004** | `0004-dns-interception-model.md` | DNS interception model | Proposed / Gate A | Model A scoped DNS capture |
| **ADR-0005** | `0005-blocked-dns-query-response.md` | Blocked DNS query response | Accepted | Synthetic NXDOMAIN with TxID/checksum match |
| **ADR-0006** | `0006-upstream-resolution.md` | Upstream DNS resolution & privacy disclosure | **Resolved & Adopted** | Quad9 default + custom IP + activation disclosure |
| **ADR-0007** | `0007-encrypted-dns-boundary.md` | Encrypted DNS boundary | Accepted | Defer DoH/DoT to post-v1.0; unencrypted UDP port 53 for v1 |
| **ADR-0008** | `0008-filter-representation.md` | Filter representation | Proposed / Gate C | Suffix-walk binary search over mapped reversed labels |
| **ADR-0009** | `0009-allowlist-architecture.md` | Allowlist architecture | **Resolved & Adopted** | Rebuild immutable generation per edit; zero tunnel restart |
| **ADR-0010** | `0010-safari-web-extension-execution-and-update-model.md` | Safari Web Extension execution & update | Proposed | Isolated Web Extension runtime |
| **ADR-0011** | `0011-web-extension-rule-data-generation-lifecycle-and-publication.md` | Web Extension rule data generation lifecycle | Proposed | Generation-based JSON data publishing in App Group |
| **ADR-0012** | `0012-native-js-bridge-transport-entitlement-refresh-points.md` | Native↔JS bridge transport | Proposed | Pull-only bridge message passing via SafariWebExtensionHandler |
| **ADR-0013** | `0013-layer-3-capability-boundary-and-explicit-non-goals.md` | Layer 3 capability boundary | Proposed | YouTube Safari DOM/video player FSM boundaries |

### 2.2 ADR-0002 Drafting Status
- **Status:** Drafted and placed in `docs/ADR/0002-rule-compiler-architecture-and-licensing.md` under `Proposed`.
- **Constraint Compliance:** Does **not** cite ADR-0006 or ADR-0009 as established precedent; relies strictly on independent facts (ADR-0001 scope, PassthroughRuleCompiler limitations, 150K WebKit budget).

---

## 3. Evidence Reconciliation Gates (Gate C1 & Gate C2)

### 3.1 Gate C1 — ADR-0006 / Sprint 8B Provenance & Scope-Fidelity Audit

#### A. Decision & Provenance Chain Verification
Evidence across `docs/ADR/0006-upstream-resolution.md`, `docs/Architecture/DNSFilteringArchitecture.md`, and `docs/Architecture/sprint_8b_final_closure_evidence.md` establishes the full verifiable decision chain:

```text
1. Original mechanism: Pre-tunnel dynamic local DHCP resolver discovery (/etc/resolv.conf, res_state, libresolv)
       ↓
2. Feasibility failure: iOS sandbox blocks system resolver state (`deny(1) file-read-data`) and App Store Guideline 2.5.1
       ↓
3. Formal reopening / superseding decision: ADR-0006 formally supersedes pre-tunnel discovery design
       ↓
4. Replacement mechanism explicitly defined: Quad9 default (9.9.9.9 / 2620:fe::fe) + custom user IPv4/IPv6 + one-time activation disclosure
       ↓
5. Feasibility test: Non-blocked UDP queries routed directly to upstream resolver via NEPacketTunnelNetworkSettings.ipv4Settings.excludedRoutes
       ↓
6. Gate A scenarios: Wi-Fi, 5G Cellular, sleep/wake, VPN conflict, teardown transition leaks (20,000 queries, 0 loops, 0 leaks)
       ↓
7. Gate D energy validation: Measured ~1.30% daily battery overhead (<3.0% PRD budget)
       ↓
8. Accepted state: ADR-0006 adopted as production architecture
```

#### B. Scope-Fidelity Verification
Inspection of `Extensions/ADBLXPacketTunnel/PacketTunnelProvider.swift`, `DNSWireParser.swift`, and `DNSUpstreamForwarder.swift` confirms:
* **DNS query interception only:** `[x] YES` (`includedRoutes` strictly contains fake DNS IP `198.51.100.1/32` via `NEDNSSettings(servers: [fakeDNSServer])`).
* **DNS forwarding/resolution path:** `[x] YES` (`DNSUpstreamForwarder` forwards only parsed Port 53 UDP payload to the configured upstream socket).
* **Broader packet inspection:** `[x] NO` (Zero TCP/IP packet payload inspection).
* **General TCP/IP relay:** `[x] NO` (Non-DNS packets are never admitted into the interface).
* **Generic traffic proxy:** `[x] NO` (No proxying or intermediary cloud relay).
* **Conclusion for Gate C1:** **PASS / CERTIFIED (Architecture strictly honors DNS-only Model A boundary).**

---

### 3.2 Gate C2 — ADR-0009 Existence, Acceptance, and Semantic Coverage

1. **Existence:** `docs/ADR/0009-allowlist-architecture.md` physically exists.
2. **Disposition:** Marked `Resolved & Adopted` based on Sprint 8B benchmark results ($<45\text{ ms}$ immutable generation rebuild).
3. **Semantic Coverage Analysis:**
   * ADR-0009 explicitly defines:
     * Compilation of user allowlist domains into `allowlist.bin` via `DNSAllowlistCompiler`.
     * Publishing immutable DNS generations to `AppGroup/DNS/generations/<gen>/`.
     * Zero-restart memory-mapped reloading in `ADBLXPacketTunnel`.
   * ADR-0009 **does NOT define or authorize**:
     * Safari Content Blocker `ignore-previous-rules` JSON generation from the same domain list.
     * The unified coordination contract between the main app allowlist store, Safari compilation, and DNS generation publisher.
4. **Conclusion for Gate C2:** **PARTIAL / CONDITIONAL.** ADR-0009 is Accepted for DNS allowlisting, but does not cover the unified Safari + DNS multi-target coordination contract.

---

## 4. Premium Entitlement Audit & Hotfix Status

### 4.1 Entitlement Matrix & Remediation

| Path | Release Reachable | Entitlement Enforced | Audit Classification | Hotfix Status |
| :--- | :---: | :---: | :--- | :--- |
| **Layer 3 YouTube Web Extension** | Yes | Yes | `GATED_CORRECTLY` | Verified |
| **Layer 2 DNS Start** | Yes | Yes | `P0_ACTIVE_LEAK` $\rightarrow$ **FIXED** | `DNSProtectionViewModel` & `RealDNSProtectionService` now enforce `isPremiumEntitled()`, opening Paywall sheet for free users. |
| **Layer 2 DNS After Lapse** | Yes | Yes | `RUNNING_TUNNEL_SURVIVES_LAPSE` $\rightarrow$ **FIXED** | `StoreKitSubscriptionService` observes `Transaction.updates`; `DNSProtectionViewModel.load()` and `RealDNSProtectionService.loadStatus()` immediately tear down running tunnel if entitlement has lapsed. |
| **Protection Tab Paywall Button** | Yes | Yes | `RELEASE_REACHABLE` $\rightarrow$ **FIXED** | Replaced `MockSubscriptionService` with `subscriptionService` passed from `UIDependencies` in `SafariProtectionView` & `DNSProtectionView`. |

---

## 5. Founder Pricing Decision

**Status:** Founder-Owned (Pending Confirmation)

### Facts Prepared for Decision:
- **PRD v1.1 Baseline (§9):**
  - Monthly: $1.99/mo
  - Annual: $14.99/yr (with 7-day free trial)
  - Lifetime: $39.99
- **Current Repository Code Baseline:**
  - `StoreKitSubscriptionService.swift` defines:
    - Annual: `com.ADBLX.ADBLX.premium.annual`
    - Lifetime: `com.ADBLX.ADBLX.premium.lifetime`
  - Monthly tier is currently omitted from Swift code and `Products.storekit`.

### Founder Decision Required:
```text
Option 1 (Full PRD SKU Set):
  - Monthly: $1.99/mo (com.ADBLX.ADBLX.premium.monthly)
  - Annual: $14.99/yr (com.ADBLX.ADBLX.premium.annual) + 7-day free trial
  - Lifetime: $39.99 (com.ADBLX.ADBLX.premium.lifetime)

Option 2 (Streamlined v1.0 Launch):
  - Annual: $14.99/yr (com.ADBLX.ADBLX.premium.annual) + 7-day free trial
  - Lifetime: $39.99 (com.ADBLX.ADBLX.premium.lifetime)
  - Monthly: NO (Omit to drive Annual anchor conversion)
```

---

## 6. Workstream GO / NO-GO Gates (Reclassified Post-Audit)

| Workstream | Key Dependency | Gate Status | Rationale |
| :--- | :--- | :--- | :--- |
| **Workstream A: Layer 1 ABP Compiler** | ADR-0002 Founder Selection | **NO-GO** (Pending Option Choice) | ADR-0002 drafted. Awaiting founder decision on Option A vs Option B vs Option C. |
| **Workstream B: Safari Allowlist Compiler** | Rule Generation Architecture | **GO** | Can implement `ignore-previous-rules` JSON compiler independently. |
| **Workstream C: Unified Safari + DNS Allowlist** | Multi-Target Coordination Contract | **CONDITIONAL** | DNS engine passed Gate C1 & ADR-0009 passed Gate C2; unified coordinator contract across Layer 1 + Layer 2 must be authored in Sprint 10. |
| **Workstream D: DNS Entitlement Hotfix** | Entitlement Audit | **COMPLETE / GREEN** | `P0_ACTIVE_LEAK` and `MockSubscriptionService` remediated and covered by unit tests. |
| **Workstream E: StoreKit SKU Finalization** | Founder Pricing Decision | **NO-GO** (Pending Founder Decision) | Awaiting founder selection of SKU set (Option 1 vs Option 2). |

---

## 7. Sprint 10.1 Entry Criteria

Sprint 10.1 (Implementation) begins once:
- [x] Repository topology and canonical paths verified.
- [x] Gate C1: ADR-0006 reversal chain & DNS-only scope fidelity verified.
- [x] Gate C2: ADR-0009 existence, acceptance, and semantic boundaries verified.
- [x] Hotfix applied & verified for `P0_ACTIVE_LEAK` (DNS Protection entitlement gate).
- [x] Hotfix applied & verified for `MockSubscriptionService` in `SafariProtectionView`.
- [x] ADR-0002 authored and placed under review in `docs/ADR/`.
- [ ] Founder chooses Compiler Architecture (Option A / B / C in ADR-0002).
- [ ] Founder chooses Pricing SKU set (Option 1 vs Option 2).
