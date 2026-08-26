# 0002 — Rule Compiler Architecture & Licensing Decision Framework

**Date:** 2026-08-26  
**Status:** Proposed  
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
3. No formal ADR has yet been decided for the Layer 1 compilation pipeline.

---

## 2. Decision Options Under Evaluation

Three architectural and licensing options are identified:

### Option A: Link `SafariConverterLib` (GPL-3.0)
* **Mechanism:** Integrate AdGuard's open-source `SafariConverterLib` (C++/Swift library) to perform parsing of network rules, cosmetic CSS element hiding rules, and scriptlets.
* **Licensing Implication:** `SafariConverterLib` is licensed under GNU GPLv3. Linking this library directly into the ADBLX main app binary creates GPLv3 copyleft obligations for the linking target, requiring the associated application source code to be released under GPLv3.
* **Tradeoffs:**
  * *Pros:* Battle-tested syntax support, handles advanced modifier edge cases out of the box, existing reference implementation.
  * *Cons:* GPL-3.0 licensing constraints on the commercial iOS application; binary size overhead from C++ converter code.

### Option B: Clean-Room Native Swift ABP Rule Compiler (MIT / Proprietary)
* **Mechanism:** Author an independent, clean-room Swift parser implementing standard ABP/AdGuard rule syntax translation to Safari Content Blocker JSON triggers and actions:
  * Network rules (`||domain.com^`, `|http://`, `^`, `$third-party`, `$image`, `$script`) $\rightarrow$ `{"type": "block"}` with regex triggers.
  * Cosmetic rules (`domain.com##.ad-class`) $\rightarrow$ `{"type": "css-display-none"}` with `if-domain` selector triggers.
  * Exception rules (`@@||domain.com^`) $\rightarrow$ `{"type": "ignore-previous-rules"}` triggers.
* **Licensing Implication:** Fully owned, clean-room codebase with zero GPL copyleft obligations. Can be licensed under MIT or kept proprietary.
* **Tradeoffs:**
  * *Pros:* Zero licensing risk; pure Swift concurrency compatibility; zero external binary dependencies; full control over memory allocations and the 150,000 rule budget during compilation.
  * *Cons:* Requires dedicated implementation and unit test coverage for ABP syntax tokenization and regex translation.

### Option C: Server-Side Pre-Compilation via CDN Publisher
* **Mechanism:** Move rule compilation entirely to the backend Publisher tool (`backend/tools/Publisher`). The server converts ABP text lists into pre-compiled Safari Content Blocker JSON payloads and publishes `.json` files directly to the CDN.
* **Licensing Implication:** Compiler runs on the build/publish server; client receives only compiled JSON data.
* **Tradeoffs:**
  * *Pros:* Zero compilation computation on user devices; immediate client-side JSON ingestion with no client parser required.
  * *Cons:* Precludes on-device user custom list import via arbitrary URLs (PRD FR-15); increases CDN bandwidth consumption (Safari JSON is significantly larger than raw ABP text); ties filter group composition strictly to server-side manifest configurations.

---

## 3. Decision Criteria & Open Evaluation

The decision between Option A, Option B, and Option C remains **OPEN** pending founder and architectural selection. 

Evaluation criteria:
1. **Licensing Isolation:** Whether commercial proprietary distribution requires strict clean-room isolation from GPLv3 copyleft.
2. **On-Device Independence:** Whether on-device custom URL list import (FR-15) and dynamic group composition are mandatory on-device requirements.
3. **Engine Footprint:** Execution speed (<10s on A14) and memory ceiling (<200MB resident) per PRD NFR-01.

---

## 4. Consequences

* Once an option is chosen, the implementation of `RuleCompiler` will replace `PassthroughRuleCompiler` in `ADBLX/Filtering/Compilation/`.
* `FilterValidator` will be updated to validate raw input format appropriate to the chosen architecture.
* Stale comments referencing "ADR-0001" for compiler licensing will be retired across the codebase.
