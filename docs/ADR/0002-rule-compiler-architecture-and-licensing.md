# 0002 — Rule Compiler Architecture & Licensing Decision

**Date:** 2026-08-26  
**Status:** Accepted  
**Deciders:** ADBLX Architecture Team, Founder  
**Supersedes:** Unassigned placeholder references in early documentation and source comments

---

## 1. Context & Problem Statement

ADBLX ships 4 Safari Content Blocker extensions (`ADBLXAdsBlocker`, `ADBLXPrivacyBlocker`, `ADBLXAnnoyancesBlocker`, `ADBLXRegionalBlocker`), each constrained by WebKit to a ceiling of 150,000 compiled rules. Filter compilation must execute exclusively within the main application process (`ADBLX`), as Content Blocker extensions are constrained to a ~6MB resident memory limit where compilation is not viable.

Currently, Layer 1 in the main app ships with `PassthroughRuleCompiler` and `FilterValidator`, which assume and require that input filter payloads are pre-formatted Safari Content Blocker JSON arrays (`[{"trigger": ..., "action": ...}]`). 

However, upstream ad-blocking filters (e.g. EasyList, EasyPrivacy, Fanboy Annoyances) and community filter lists are distributed in standard Adblock Plus (ABP) / AdGuard declarative text syntax (e.g. `||ads.example.com^`, `##.banner-ad`, `@@||exception.example.com^$generichide`). 

Consequently, the client application cannot compile standard upstream filter list text files downloaded via the update pipeline into valid Safari Content Blocker JSON. Furthermore:
1. `ADR-0001` in this repository establishes manual deterministic JSON writing for the Publisher manifest generator tool (`docs/ADR/0001-manifest-json-manual-writer.md`).
2. Early design documents and source comments in `RuleCompiler.swift` and `TargetTopology.md` contained placeholder references to an unauthored "ADR-0001" or "ADR-0002" concerning GPL licensing and `SafariConverterLib`.
3. A formal architectural decision is required to select between linking a third-party library, authoring a clean-room native Swift compiler, or server-side pre-compilation.

---

## 2. Decision Options Evaluated

### Option A: Link `SafariConverterLib` (GPL-3.0)
* **Mechanism:** Integrate AdGuard's open-source `SafariConverterLib` (C++/Swift library) to perform parsing of network rules, cosmetic CSS element hiding rules, and scriptlets.
* **Licensing Implication:** `SafariConverterLib` is licensed under GNU GPLv3. Linking this library directly into the ADBLX main app binary creates GPLv3 copyleft obligations for the linking target.
* **Tradeoffs:**
  * *Pros:* Battle-tested syntax support, existing reference implementation.
  * *Cons:* GPL-3.0 licensing constraints on the commercial iOS application; binary size overhead from C++ converter code.

### Option B: Clean-Room Native Swift ABP Rule Compiler (MIT / Proprietary) — ACCEPTED
* **Mechanism:** Author an independent, clean-room Swift parser implementing standard ABP/AdGuard rule syntax translation to Safari Content Blocker JSON triggers and actions:
  * Network rules (`||domain.com^`, `|http://`, `^`, `$third-party`, `$image`, `$script`) $\rightarrow$ `{"type": "block"}` with regex triggers.
  * Cosmetic rules (`domain.com##.ad-class`) $\rightarrow$ `{"type": "css-display-none"}` with `if-domain` selector triggers.
  * Exception rules (`@@||domain.com^`) $\rightarrow$ `{"type": "ignore-previous-rules"}` triggers.
* **Licensing Implication:** Fully owned, clean-room codebase with zero GPL copyleft obligations.
* **Tradeoffs:**
  * *Pros:* Zero licensing risk; pure Swift concurrency compatibility; zero external binary dependencies; full control over memory allocations and the 150,000 rule budget during compilation; enables fully on-device user custom list import (PRD FR-15).
  * *Cons:* Requires dedicated implementation and unit test coverage for ABP syntax tokenization and regex translation.

### Option C: Server-Side Pre-Compilation via CDN Publisher — REJECTED
* **Mechanism:** Move rule compilation entirely to the backend Publisher tool (`backend/tools/Publisher`).
* **Rejection Rationale:** 
  1. Conflicts directly with PRD FR-15 (on-device custom filter-list import by arbitrary URL).
  2. Supporting arbitrary runtime user imports would require a dedicated live conversion backend service, which is outside the privacy-first, on-device architecture.
  3. Inflates CDN payload distribution sizes significantly compared to raw text.

---

## 3. Decision

**SHIELD adopts Option B: Clean-room native Swift compiler.**

SHIELD will implement an on-device, clean-room Swift compiler for a deliberately scoped subset of ABP/AdGuard filter syntax. The compiler will run exclusively in the main application process and will emit Safari Content Blocker JSON for the configured filter catalog and supported user-imported lists.

The supported grammar will not be assumed by this ADR. Task 10.2.0 will inspect the actual filter corpus and establish the binding compiler contract. Unsupported syntax must be explicitly detected, classified, counted, and surfaced through `CompilationReport`; it must never be silently dropped or approximately converted.

---

## 4. Consequences

* **FR-15:** Remains achievable with fully on-device compilation.
* **Licensing:** No SafariConverterLib dependency or associated GPL linkage question in the shipping app.
* **Maintenance Ownership:** We own parser correctness and must track syntax evolution in upstream lists.
* **Grammar Scope:** Explicitly bounded and measured from the real configured corpus in **Task 10.2.0**.
* **Unsupported Syntax:** Count-and-report via `CompilationReport`; zero silent degradation.
* **Performance:** Compilation stays off the main actor. Acceptance budget remains **100K rules <10 seconds on A14-class hardware and <200 MB transient memory** (PRD NFR-01).
* **Disk I/O:** Compile to staged artifacts and publish atomically; rollback to last-known-good output on failure.
* **Battery / Network:** No continuous runtime cost. Compilation is CPU-intensive only during filter updates or custom-list imports; introduces no additional radio activity beyond list downloads.
* **Content Blocker Extensions:** No parsing or compilation work occurs in extensions; extensions only consume published artifacts.
