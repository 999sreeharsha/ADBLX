# PRD — SHIELD: iOS Ad Blocker
**Version:** 1.1 · **Status:** Draft · **Owner:** Harsha · **Date:** 2026-07-10
**Changelog v1.1:** merged research note (reference architectures, Indian ad-network list) as Appendices B–C; added NG6 (on-device ML blocking); resolved Open Question 3 direction.
**Working title:** SHIELD (rename before launch)

---

## 1. Overview

SHIELD is a privacy-first ad blocker for iPhone, iPad, and Mac (Catalyst) that blocks ads, trackers, and annoyances in Safari and — for premium users — across the whole device via on-device DNS filtering. It competes with AdGuard, 1Blocker, Wipr, and Magic Lasso on three axes: **blocking effectiveness (incl. YouTube in Safari), zero data collection, and effortless onboarding.**

### Problem
- Mobile ads degrade page load, battery, and data usage; trackers follow users across apps and sites.
- Existing blockers either require heavy configuration (AdGuard, uBlock Origin Lite), collect data (several free blockers), or lack system-wide/YouTube blocking (Wipr).
- The #1 purchase driver in this category is YouTube ad blocking in Safari; the #1 churn driver is broken sites with no easy fix.

### Solution
One app, three blocking layers, a dynamically updatable filter catalog, and a freemium subscription with a lifetime option.

---

## 2. Goals & Non-Goals

### Goals
- G1: Block ≥ 95% of ads/trackers on top-500 sites in Safari (AdBlock Tester score ≥ 95/100).
- G2: Block YouTube ads in Safari (premium).
- G3: System-wide DNS-level blocking with zero traffic leaving the device (premium).
- G4: Filter lists update in the background without app updates; new lists launchable server-side.
- G5: Zero data collection — no analytics SDKs that touch browsing data; publishable privacy audit.
- G6: Onboarding completion (Safari extensions enabled) ≥ 70% of installs.

### Non-Goals (v1)
- NG1: Blocking ads inside the native YouTube/Facebook apps (not technically possible; never promise it).
- NG2: Android version.
- NG3: Bundled VPN with remote servers (local tunnel only).
- NG4: Custom user-authored regex rules UI (v2; power-user feature).
- NG5: Parental controls / DNS-over-HTTPS resolver service of our own.
- NG6: On-device ML/"AI" ad classification. Per-query inference sits on the tunnel hot path (violates NFR-02 battery budget), false positives break sites (#1 churn driver), and passive domain observation violates G5. A server-side variant (classify candidate domains from public feeds to seed the proprietary list) is acceptable post-launch — see Open Questions.

---

## 3. Target Users

| Persona | Description | Willingness to pay |
|---|---|---|
| **Casual Casey** | Wants ads gone, will never open settings twice. Installs, enables, forgets. | Low → free tier; may convert on YouTube |
| **Privacy-minded Priya** | Reads privacy policies, uses Signal, wants tracker blocking + no data collection. | Medium → annual sub |
| **Power-user Pavan** | Wants regional filters, per-site allowlist, custom lists, sync, Mac support. | High → lifetime IAP |

---

## 4. Competitive Positioning

| | AdGuard | 1Blocker | Wipr | Magic Lasso | **SHIELD** |
|---|---|---|---|---|---|
| Safari content blocking | ✅ | ✅ | ✅ | ✅ | ✅ free |
| System-wide (DNS/local VPN) | ✅ paid | ❌ | ❌ | partial | ✅ premium |
| YouTube (Safari) | partial | ✅ paid | ❌ | ✅ paid | ✅ premium |
| Zero data collection | partial | ⚠️ | ✅ | ✅ | ✅ |
| Setup effort | high | medium | none | low | **low** |
| Lifetime option | ✅ | ✅ $39.99 | one-time $5 | ✅ | ✅ |

**Positioning statement:** "Wipr's simplicity with AdGuard's power — and nothing about you ever leaves your phone."

---

## 5. Product Scope

### 5.1 Feature matrix (Free vs Premium)

| Feature | Free | Premium |
|---|---|---|
| Safari ad blocking (base filters) | ✅ | ✅ |
| Tracker blocking (EasyPrivacy) | ✅ | ✅ |
| Automatic filter updates | ✅ (weekly) | ✅ (daily + push-triggered) |
| Per-site allowlist | ✅ | ✅ |
| Cookie-banner / annoyance filters | ❌ | ✅ |
| Regional filter lists | ❌ | ✅ |
| YouTube ad blocking in Safari (web extension) | ❌ | ✅ |
| System-wide DNS blocking (local tunnel) | ❌ | ✅ |
| iCloud sync of settings/allowlist | ❌ | ✅ |
| Custom filter list URL import | ❌ | ✅ |
| Mac (Catalyst) app | ❌ | ✅ |

### 5.2 Priorities
- **P0 (MVP / v1.0):** Safari content blockers ×4, filter registry + update pipeline, onboarding, allowlist, paywall + subscriptions.
- **P1 (v1.1):** Local-tunnel DNS blocking, YouTube web extension, iCloud sync.
- **P2 (v1.2+):** Regional lists UI, custom list import, Mac Catalyst, Safari toolbar extension ("report broken site" / one-tap allowlist).

---

## 6. Architecture

### 6.1 Blocking layers

```
┌──────────────────────────────────────────────────────┐
│ Main App (SwiftUI)                                   │
│  onboarding · filter catalog · paywall · settings    │
│  FilterUpdateManager · RuleCompiler (SafariConverter)│
└──────────────┬───────────────────────────────────────┘
               │ App Group (shared container)
   ┌───────────┼──────────────┬────────────────┐
   ▼           ▼              ▼                ▼
Content     Content        Safari Web      Packet Tunnel
Blocker ×4  Blocker rules  Extension       (NEPacketTunnel-
(Ads/Priv/  JSON per ext   (YouTube,       Provider, local
Annoy/Reg)                 cosmetic,       DNS filtering,
                           anti-adblock)   premium)
```

- **Layer 1 — Safari Content Blockers (4 extensions):** declarative WebKit rules; ≤ 150K rules per extension. Groups: Ads, Privacy, Annoyances, Regional. Zero runtime cost.
- **Layer 2 — Local DNS tunnel (premium):** `NEPacketTunnelProvider` running on-device; filters DNS queries against hosts-format lists (OISD/HaGeZi). No remote servers; no traffic logged. Conflicts with real VPNs — detect and message.
- **Layer 3 — Safari Web Extension (premium):** JS injection for YouTube ads in Safari, cosmetic filtering, anti-adblock walls.

### 6.2 Filter registry & update pipeline

**Server side (CDN + cron):**
- Cron pulls upstream lists (EasyList, EasyPrivacy, AdGuard Base, OISD, HaGeZi, Fanboy Annoyances, Peter Lowe, regional), validates, republishes to CDN, bumps manifest.
- `manifest.json` on CDN describes every list: `id, name, group, sourceUrl, version (date-based), checksum (sha256), ruleCount, enabledByDefault, premium`.
- New lists are launched by editing the manifest only — no app update required.

**Client side:**
1. `BGAppRefreshTask` (12–24h) **and** foreground check (throttled 6h) fetch manifest with ETag.
2. Diff manifest vs `installed_filters.json`; download changed lists; verify checksum.
3. Convert filter syntax → Safari JSON via SafariConverterLib **in the main app only** (extensions have ~6MB memory).
4. Partition rules across the 4 extensions respecting the 150K budget; write atomically (temp + rename) into App Group.
5. `SFContentBlockerManager.reloadContentBlocker` per affected extension; surface errors ("enable in Settings") instead of failing silently.
6. Keep previous compiled JSON for rollback; report bad list versions to backend.
- App binary ships a bundled snapshot of compiled rules for day-one blocking.

### 6.3 Data & privacy
- All state in App Group container; settings sync via iCloud key-value/CloudKit (premium).
- No third-party analytics SDK. First-party, aggregate, opt-in telemetry only (update success rate, crash reports via Apple).
- DNS filtering entirely on-device; no request logging.

---

## 7. Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| FR-01 | App ships 4 content blocker extensions, each ≤ 150K compiled rules | P0 |
| FR-02 | Bundled rule snapshot active on first launch, pre-network | P0 |
| FR-03 | Fetch manifest via ETag; update only changed, enabled lists | P0 |
| FR-04 | Verify sha256 checksum before accepting a downloaded list | P0 |
| FR-05 | Atomic write of compiled JSON; rollback to last-good on failure | P0 |
| FR-06 | Reload affected extensions after compile; report per-extension status in UI | P0 |
| FR-07 | Onboarding detects whether each Safari extension is enabled and guides user | P0 |
| FR-08 | Per-site allowlist editable in-app; applied across all extensions | P0 |
| FR-09 | Filters screen renders catalog dynamically from manifest (groups, versions, rule-count meter per extension) | P0 |
| FR-10 | Paywall with free trial; products: monthly, annual, lifetime (StoreKit 2) | P0 |
| FR-11 | Local packet tunnel filters DNS against hosts lists; on/off toggle; VPN-conflict detection | P1 |
| FR-12 | Web extension blocks YouTube ads on youtube.com in Safari | P1 |
| FR-13 | iCloud sync of enabled filters + allowlist | P1 |
| FR-14 | "Report broken site" action → auto-allowlist prompt + report to backend | P1 |
| FR-15 | Custom filter list import by URL, with rule budget warning | P2 |

## 8. Non-Functional Requirements

- NFR-01: Filter compile (100K rules) < 10s on A14; memory < 200MB during compile.
- NFR-02: No measurable battery impact from content blockers; tunnel overhead < 3% battery/day.
- NFR-03: Update pipeline success rate ≥ 99% (excluding offline).
- NFR-04: CDN manifest fetch p95 < 300ms; lists served compressed (br/gzip).
- NFR-05: App cold start < 1.5s.
- NFR-06: All UI accessible (VoiceOver, Dynamic Type).

---

## 9. Monetization

- **Free:** Safari blocking with base filters (genuinely good — trust builder and App Store rating driver).
- **Premium subscription:** $1.99/mo · **$14.99/yr** (anchor) · 7-day free trial.
- **Lifetime IAP:** $39.99 — critical for this audience's subscription aversion.
- Upsell moments: YouTube detected in Safari history is out of scope (privacy) — instead upsell contextually: after onboarding success, on Annoyances toggle tap, on "Update now" for free users.
- Target: 5% free→paid conversion @ 90 days; 60% of paid revenue from annual, 30% lifetime, 10% monthly.

---

## 10. App Store Compliance & Risks

| Risk | Mitigation |
|---|---|
| Rejection for VPN entitlement misuse | Tunnel is local-only, clearly described as on-device DNS filtering; no traffic monetization; request Network Extension entitlement early |
| "Blocks YouTube app ads" claims | Never claim app-level YouTube blocking; marketing copy says "YouTube in Safari" |
| Filter list licensing (EasyList CC BY-SA/GPL dual, others) | Attribution screen in-app; comply with each list's license; legal review pre-launch |
| Upstream list breaks sites at scale | Server-side validation + canary devices before republish; client rollback (FR-05) |
| One-VPN-at-a-time conflict angers VPN users | Detect active VPN config, explain tradeoff, offer Safari-only mode |
| BGAppRefresh unreliability → stale filters | Foreground check + silent push trigger for premium |
| Apple policy changes to Content Blocker API | Track WWDC/releases; abstraction layer over rule compilation |

---

## 11. Success Metrics

| Metric | Target (90 days post-launch) |
|---|---|
| Onboarding completion (all extensions enabled) | ≥ 70% |
| AdBlock Tester score | ≥ 95/100 |
| D30 retention | ≥ 35% |
| Free→paid conversion | ≥ 5% |
| App Store rating | ≥ 4.6 |
| Filter update success rate | ≥ 99% |
| Broken-site reports per WAU | < 0.5% |

---

## 12. Milestones (sprint plan)

| Sprint | Duration | Deliverable |
|---|---|---|
| S1 | 2 wk | Project scaffold: app + 4 CB extensions + App Group; bundled snapshot blocking works end-to-end |
| S2 | 2 wk | Filter registry: CDN manifest, server cron, FilterUpdateManager (fetch/diff/verify/compile/reload), rollback |
| S3 | 2 wk | Onboarding flow + extension status detection; Filters catalog UI; allowlist |
| S4 | 2 wk | StoreKit 2 paywall (trial, monthly/annual/lifetime); free-tier gating; App Store submission #1 (Safari-only MVP) |
| S5 | 3 wk | Packet tunnel DNS blocking + VPN-conflict UX (entitlement lead time runs in parallel from S1) |
| S6 | 3 wk | YouTube web extension + cosmetic filtering; iCloud sync |
| S7 | 2 wk | Polish, broken-site reporting, Mac Catalyst spike, launch marketing |

---

## 13. Open Questions

1. Own filtering DNS brand later (NextDNS-style service) or stay 100% on-device forever? (Affects privacy positioning.)
2. Build proprietary top-up filter list from day one, or post-launch once broken-site reports flow in? → Leaning day one for the **Indian web ad-network list** (Appendix C): small (2–5K rules), high differentiation, fits Regional extension budget.
3. ~~Regional list priority~~ **Resolved:** India first (Appendix C), then EasyList regional variants by user-base signal.
4. Silent-push update trigger: worth the server infra in v1.1, or defer?
5. Server-side ML domain classification (cert-transparency + new-domain feeds → candidate rules for proprietary list): post-launch experiment. Zero on-device cost; marketing angle "AI-curated filters" without touching user data.
6. Name/brand + App Store keyword strategy (category is keyword-saturated).

---

## 14. Appendix A — Filter sources (initial catalog)

| List | Group | Layer | License |
|---|---|---|---|
| EasyList | Ads | CB | CC BY-SA 3.0 / GPLv3 |
| EasyPrivacy | Privacy | CB | CC BY-SA 3.0 / GPLv3 |
| AdGuard Base | Ads | CB | GPLv3 |
| Fanboy Annoyances | Annoyances | CB | CC BY-SA 3.0 |
| Peter Lowe's | Privacy | CB + DNS | McRae GPL-like |
| OISD (small/big) | Ads/Privacy | DNS | CC0-ish (verify) |
| HaGeZi Multi | Ads/Privacy | DNS | GPLv3 |
| EasyList regional variants | Regional | CB | per-list |
| SHIELD proprietary fixes | Ads | CB | internal |

---

## 15. Appendix B — Reference architectures (study material)

Corrected and consolidated from research note (2026-07).

### B.1 Facts baseline (corrections applied)
- Safari content blocker rule limit is **150K per extension** (since Safari 15 / iOS 15), not 50K. SHIELD budget: 150K × 4 extensions.
- These are **Content Blocker app extensions** (`SafariServices`, `SFContentBlockerManager`) — not "Safari App Extensions" (a macOS extension type). Use the iOS docs and Info.plist keys accordingly.
- Rule actions available in Safari JSON: `block`, `block-cookies`, `css-display-none`, `ignore-previous-rules`, `make-https`. No request-body access; URL/header/resource-type triggers only; no JS from content blockers (JS = Layer 3 web extension).
- Rules are static per compile — updates require recompile in main app + `reloadContentBlocker` (see §6.2).

### B.2 Primary references
| Codebase | Why study it | License |
|---|---|---|
| **AdGuard for iOS** (github.com/AdguardTeam/AdguardForiOS) | Closest open-source analog: two-tier design (declarative CB JSON + web-extension advanced rules) maps 1:1 to our Layer 1/Layer 3 split. Study AdGuardSDK structure, extension layout, rule partitioning. | GPL-3.0 — **study architecture; do not copy code** unless we accept GPL obligations (we don't for the app; see legal) |
| **SafariConverterLib** (github.com/AdguardTeam/SafariConverterLib) | Our planned converter (§6.2). Handles EasyList/AdGuard syntax → Safari JSON, Safari version differences, and flags "advanced" rules for the web extension. | GPL-3.0 — same caveat; evaluate linking implications before shipping, or treat as spec for a clean-room converter |
| **uBlock Origin** (github.com/gorhill/uBlock) | Filter syntax reference (network + cosmetic rule semantics). | GPL-3.0 |
| Brave iOS (brave-core) | In-browser blocking reference only; different distribution model, low priority. | MPL-2.0 |

**Dropped from study list:** Pi-hole (network-side DNS sinkhole with server/dashboard — wrong model; our Layer 2 is on-device `NEPacketTunnelProvider`, no server, per NG3/NG5. Only overlap is hosts-list format, already covered by OISD/HaGeZi). Better Blocker (maintenance status unclear; superseded by AdGuard references).

**Legal action item:** GPL-3.0 status of SafariConverterLib vs App Store distribution needs counsel review before S2 (§10 licensing risk). Options: (a) ship it and open-source the linking target, (b) clean-room converter from the AdGuard syntax spec, (c) server-side conversion (conflicts with on-device story for custom lists — FR-15).

### B.3 Two-tier blocking pattern (adopted)
Tier 1: declarative CB JSON (fast, zero runtime cost, privacy-preserving — Safari never reports matches). Tier 2: rules inexpressible in JSON (scriptlets, procedural cosmetic filters, YouTube) → Layer 3 web extension. SafariConverterLib performs this split automatically by marking unsupported rules "advanced."

---

## 16. Appendix C — Indian web ad-network filter list (proprietary, Regional extension)

**Scope correction:** the gap is **web-side**, not in-app SDKs. InMobi-class SDK networks are invisible to Safari content blockers and only partially degradable via DNS (SDK traffic often rides first-party/CDN domains). MoPub no longer exists (shut down 2022, absorbed into AppLovin). Do not build around SDK networks.

**Target (Layer 1 CB JSON + Layer 2 DNS hosts):**
| Category | Examples to research | Layer |
|---|---|---|
| Publisher ad servers / native-ad widgets on Indian news & entertainment sites | Times Internet "Colombia", Adgebra, Zedo | CB + DNS |
| Video ad injectors common on Indian publishers | Vdo.ai and similar outstream players | CB + DNS |
| Regional-language content-farm ad domains | To be compiled from top Telugu/Hindi/Tamil publisher audits | CB + DNS |
| Cross-site trackers prevalent in Indian web properties | To be compiled | DNS |

**Build approach:**
1. Audit top ~100 Indian publishers (news, cricket, entertainment, regional-language) with devtools; extract ad/tracker domains not covered by EasyList/EasyPrivacy/OISD.
2. Publish as `shield-india` list in the manifest (group: regional, `premium: true` per §5.1).
3. Maintain via FR-14 broken-site/missed-ad reports post-launch.

**Budget:** est. 2–5K rules — negligible against the Regional extension's 150K budget. DNS entries similarly small vs hosts-list sizes.

**Success metric tie-in:** AdBlock-Tester-style audit on Indian top-50 sites ≥ 95% blocked (extends G1 to the differentiation market).
