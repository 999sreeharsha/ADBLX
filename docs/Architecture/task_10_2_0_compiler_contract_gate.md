# Task 10.2.0 — Compiler Contract Gate (Task 10.2.0A Update)

**Date:** 2026-08-26  
**Status:** COMPLETE (Binding Contract Frozen — GO Decision)  
**Corpus Analyzed:** EasyList (78,321 lines), EasyPrivacy (56,649 lines), Fanboy Annoyances (50,336 lines) — Total: 185,306 lines  

---

## 1. Empirical Modifier Frequency & Combination Inventory

An exhaustive scan across all 185,306 lines of the configured filter catalog identified all active modifier constructs and combinations:

### Modifier Frequency Inventory

| Modifier | Count | Semantic Classification | WebKit Action |
|---|---|---|---|
| `$third-party` | 6,823 | Supported | `"load-type": ["third-party"]` |
| `$~third-party` | 761 | Supported | `"load-type": ["first-party"]` |
| `$domain=` | 1,471 | Supported | `"if-domain": [...]`, `"unless-domain": [...]` |
| `$script` | 1,345 | Supported | `"resource-type": ["script"]` |
| `$image` | 698 | Supported | `"resource-type": ["image"]` |
| `$xmlhttprequest` (`$xhr`) | 320 | Supported | `"resource-type": ["raw"]` |
| `$subdocument` | 210 | Supported | `"resource-type": ["subdocument"]` |
| `$media` | 82 | Supported | `"resource-type": ["media"]` |
| `$stylesheet` (`$css`) | 76 | Supported | `"resource-type": ["style-sheet"]` |
| `$ping` | 61 | Supported | `"resource-type": ["raw"]` |
| `$font` | 1 | Supported | `"resource-type": ["font"]` |
| `$websocket` | 5 | Supported | `"resource-type": ["websocket"]` |
| `$~<type>` (negated resource) | 168 | Supported (Complement Mapping) | `"resource-type": [all types EXCEPT <type>]` |
| `$popup` | 3,053 | **Unsupported Semantic Modifier** | **SKIP RULE + COUNT** |
| `$document` | 603 | **Unsupported Semantic Modifier** (on block rules) | **SKIP RULE + COUNT** (Exception `@@...$document` supported) |
| `$generichide` | 181 | **Unsupported Semantic Modifier** | **SKIP RULE + COUNT** |
| `$redirect` / `$redirect-rule` | 27 | **Unsupported Semantic Modifier** | **SKIP RULE + COUNT** |
| `$important` | 10 | **Unsupported Semantic Modifier** | **SKIP RULE + COUNT** |
| `$rewrite` | 8 | **Unsupported Semantic Modifier** | **SKIP RULE + COUNT** |
| `$csp` | 5 | **Unsupported Semantic Modifier** | **SKIP RULE + COUNT** |

---

## 2. Strict Semantic Safety Policy

To prevent semantic corruption or unintentional over-blocking:

| Construct | Compiler Action | Telemetry / Output |
|---|---|---|
| **Exact Supported Mapping** (e.g. `||domain.com^$script,third-party`) | Compile to WebKit rule | Emits `SafariContentBlockerRule` |
| **Negated Resource Type** (e.g. `$~script`) | Compile to complement resource list | Emits positive list omitting `script` |
| **$domain= Complex Syntax** (`multi_include`, `multi_exclude`, `mixed`) | Parse include/exclude domains | Emits `if-domain` and `unless-domain` |
| **Cosmetic Element Hiding** (`##.selector`, `domain##.selector`) | Compile to CSS rule | Emits `action.type: "css-display-none"` |
| **Exception Rules** (`@@||domain^`, `@@||domain^$document`) | Compile to unblock rule | Emits `action.type: "ignore-previous-rules"` |
| **Unsupported Semantic Modifier** (`$popup`, `$csp`, `$redirect`, etc.) | **SKIP ENTIRE RULE** (Do NOT compile broader base rule) | `CompilationReport.unsupportedSemanticModifiers[mod] += 1` |
| **Deferred Layer 2 Syntax** (`##+js(...)`, `#?#`) | Skip Layer 1 compile | `CompilationReport.deferredToWebExtensionCount += 1` |
| **$badfilter** | Skip Layer 1 compile | `CompilationReport.badfilterCount += 1` |
| **Invalid / Malformed Syntax** | Skip compile | `CompilationReport.invalidRulesCount += 1` |

---

## 3. Estimated Rule Budget Capacity

> [!NOTE]
> All budget numbers below are **pre-compilation estimates**. Actual publish capacity is verified upon physical artifact generation and budget check in Task 10.2.3.

| Filter Group | Source Lines | Estimated Skipped (Comments/Unsupported) | Estimated Compiled Rules | Budget Ceiling | Headroom |
|---|---|---|---|---|---|
| **Ads Group** | 78,321 | ~3,500 (comments + popups + scriptlets) | **~74,800** | 150,000 | **~50.1%** |
| **Privacy Group** | 56,649 | ~800 (comments) | **~55,800** | 150,000 | **~62.8%** |
| **Annoyances Group** | 50,336 | ~1,900 (comments + procedural) | **~48,400** | 150,000 | **~67.7%** |
| **Regional Group** | ~20,000 | ~500 | **~19,500** | 150,000 | **~87.0%** |

---

## 4. Layer Placement & Performance Budget

* **Shared Compiler Core (`Packages/ADBLXShared/`):**
  * `ABPLexer`, `ParsedRule`, `ABPSemanticValidator`, `SafariRuleGenerator`, `CompilationReport`.
  * Pure, platform-independent, zero I/O, `Sendable`.
* **Main App (`ADBLX/Filtering/Compilation/`):**
  * `NativeABPRuleCompiler` (conforming to `RuleCompiler`), integrated into `FilterPipeline`.
* **Performance Budget (PRD NFR-01):**
  * 100K rules in $<10\text{ s}$ on A14; transient peak memory $<200\text{ MB}$.
  * Line-by-line streaming / bounded batching to prevent unbounded memory spike.
  * Zero execution on `@MainActor`.

---

## 5. Gate Decision: GO

* **Modifier Frequency Inventory:** 100% complete across all 185,306 lines.
* **Semantic Safety Policy:** Frozen (unsupported semantic modifiers skip entire rule; zero silent over-blocking).
* **Verdict:** **GO** for Task 10.2.1 implementation.
