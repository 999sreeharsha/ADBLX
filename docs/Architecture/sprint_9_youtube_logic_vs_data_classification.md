# Sprint 9 — Task 5: Fixed Logic vs. Updatable Data Classification

**Status:** Complete / Ready for Validation  
**Date:** 2026-08-25  
**Governing Documents:** [ADR-0010](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0010-safari-web-extension-execution-and-update-model.md), [ADR-0011](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0011-web-extension-rule-data-generation-lifecycle-and-publication.md), [Task 3 Detection Model](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_detection_state_model.md), [Task 4 Candidate Interventions](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_candidate_interventions.md)

---

## 1. Context & Architectural Boundary

Per **ADR-0010** and **App Store Review Guideline 2.5.2**:
* All executable JavaScript and Swift logic is **fixed at app release**.
* No remote executable code, dynamic script evaluation (`eval()`, `Function()`, dynamic script injection), or Turing-complete rule interpreters are permitted.
* The over-the-air update pipeline (**ADR-0011**) delivers **strictly inert data**: CSS selectors within a validated subset, domain disable masks against a fixed binary allowlist, bounded numeric thresholds, and monotonic disable-only safety switches.

This document classifies every component of the Layer 3 YouTube engine and defines the formal, versioned JSON schema for `rules.json`.

---

## 2. Four-Tier Classification Taxonomy

Every operational concern is classified into exactly one of four categories:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                    CLASSIFICATION TAXONOMY                              │
├────────────────────────────────────────────────────┬────────────────────┤
│ Category                                           │ Location / Medium  │
├────────────────────────────────────────────────────┼────────────────────┤
│ 1. Fixed Executable Logic                          │ Bundled App Binary │
│ 2. Updatable Inert Matching & Configuration Data   │ rules.json (Data)  │
│ 3. Updatable Disable-Only Safety Control (Mask)    │ rules.json (Flags) │
│ 4. REJECTED: Too Behavior-Defining for Remote Data │ Prohibited         │
└────────────────────────────────────────────────────┴────────────────────┘
```

---

## 3. Comprehensive Concern Classification

| Component / Concern | Classification | Update Medium | Architectural Justification |
| :--- | :--- | :--- | :--- |
| **FSM State Machine & Transitions** | **1. Fixed Executable Logic** | Bundled Binary | State transitions and evaluation sequences define algorithmic behavior. |
| **`mediaActive` Predicate Logic** | **1. Fixed Executable Logic** | Bundled Binary | W3C media readiness checks are standard fixed browser algorithms. |
| **Skip-Control Click Dispatcher** | **1. Fixed Executable Logic** | Bundled Binary | Synthetic event creation and DOM click execution are executable code. |
| **Playback Rate Restoration Machine**| **1. Fixed Executable Logic** | Bundled Binary | Saving pre-ad state, muting, and restoring rate/volume is safety-critical logic. |
| **Observer Attachment & Scoping** | **1. Fixed Executable Logic** | Bundled Binary | Lifecycle observation and callback exception handling are fixed code. |
| **Binary Domain Allowlist Ceiling** | **1. Fixed Executable Logic** | Bundled Binary | Hardcoded `["m.youtube.com", "www.youtube.com"]`. Remote data cannot add origins. |
| **Player Container DOM Selectors** | **2. Updatable Inert Data** | `rules.json` | Strings identifying `#player`, `#movie_player`, or mobile player classes. |
| **Player Ad State CSS Classes** | **2. Updatable Inert Data** | `rules.json` | String array of class names (e.g. `["ad-showing", "ad-interrupting"]`). |
| **Skip Button Selectors** | **2. Updatable Inert Data** | `rules.json` | String array of candidate skip buttons (`[".ytp-ad-skip-button", ..."]`). |
| **Cosmetic Overlay Selectors** | **2. Updatable Inert Data** | `rules.json` | String array of elements to hide via `display: none !important`. |
| **Max Acceleration Rate Threshold** | **2. Updatable Inert Data** | `rules.json` | Bounded numeric float ($1.0 \le \text{rate} \le 16.0$). Out-of-range $\implies$ Rejection. |
| **Debounce & Settling Windows** | **2. Updatable Inert Data** | `rules.json` | Bounded integer ms ($10\text{ ms} \le w \le 1000\text{ ms}$). Out-of-range $\implies$ Rejection. |
| **Global YouTube Layer 3 Kill-Switch**| **3. Disable-Only Mask** | `rules.json` | Boolean `youtubeLayer3Disabled: true` halts all YouTube Layer 3 hooks. |
| **Acceleration Feature Kill-Switch** | **3. Disable-Only Mask** | `rules.json` | Boolean `accelerationDisabled: true` disables rate manipulation. |
| **Skip Action Kill-Switch** | **3. Disable-Only Mask** | `rules.json` | Boolean `skipClickDisabled: true` disables click dispatch. |
| **Domain Narrowing Mask** | **3. Disable-Only Mask** | `rules.json` | `disabledDomains: ["m.youtube.com"]` narrows binary allowlist. |
| **Remote JS Scriptlets / Snippets** | **4. REJECTED** | Prohibited | Direct violation of ADR-0010 and App Store Guideline 2.5.2. |
| **Arbitrary DOM Query Predicate Trees**| **4. REJECTED** | Prohibited | Shadow interpreter allowing remote code logic via nested JSON ASTs. |
| **Dynamic Event Handler Scripts** | **4. REJECTED** | Prohibited | Arbitrary execution payload in disguise. |
| **Unbounded State Override Rules** | **4. REJECTED** | Prohibited | Prevents remote data from changing FSM state graph semantics. |
| **Unconstrained CSS Selector Expressions** | **4. REJECTED** | Prohibited | Complex, nested, or injection-adjacent selectors rejected at staging. |

---

## 4. Proposed `rules.json` Schema (Schema Version 1.0)

The Layer 3 YouTube data bundle is serialized inside `rules.json` under the `youtube` key:

```json
{
  "schemaVersion": 1,
  "generation": 42,
  "publishedAt": 1787654400,
  "youtube": {
    "disableMask": {
      "youtubeLayer3Disabled": false,
      "skipClickDisabled": false,
      "accelerationDisabled": false,
      "cosmeticHidingDisabled": false,
      "disabledDomains": []
    },
    "selectors": {
      "playerContainers": [
        "#movie_player",
        ".html5-video-player",
        "#player-container-id",
        "ytm-mobile-player"
      ],
      "adStateClasses": [
        "ad-showing",
        "ad-interrupting"
      ],
      "skipButtons": [
        ".ytp-ad-skip-button",
        ".ytp-ad-skip-button-modern",
        ".ytp-skip-ad-button",
        ".ytm-skip-ad-button"
      ],
      "adBadges": [
        ".ytp-ad-text",
        ".ytp-ad-preview-text",
        ".ytm-ad-badge"
      ],
      "cosmeticHideTargets": [
        ".ytp-ad-player-overlay",
        ".ytp-ad-overlay-container",
        "ytm-promoted-sparkles-web-renderer",
        "ytm-companion-ad-renderer",
        "ytd-promoted-sparkles-web-renderer",
        "ytd-companion-ad-renderer"
      ]
    },
    "parameters": {
      "maxAccelerationRate": 16.0,
      "candidateConfirmationWindowMs": 100,
      "safeRecoveryStabilityWindowMs": 500
    }
  },
  "cosmetics": {
    "genericHideSelectors": [],
    "domainSpecificHideSelectors": {}
  },
  "antiAdblock": {
    "knownInterventions": []
  }
}
```

### TypeScript Definition for Schema Validation

```typescript
export interface WebExtensionRulesArtifact {
  schemaVersion: 1;
  generation: number;
  publishedAt: number;
  youtube: YouTubeRulesConfiguration;
  cosmetics: CosmeticRulesConfiguration;
  antiAdblock: AntiAdblockConfiguration;
}

export interface YouTubeRulesConfiguration {
  disableMask: {
    youtubeLayer3Disabled: boolean;
    skipClickDisabled: boolean;
    accelerationDisabled: boolean;
    cosmeticHidingDisabled: boolean;
    disabledDomains: string[];                 // Must be subset of binary allowlist
  };
  selectors: {
    playerContainers: string[];                // Validated subset
    adStateClasses: string[];                  // Validated class strings
    skipButtons: string[];                     // Validated subset
    adBadges: string[];                        // Validated subset
    cosmeticHideTargets: string[];             // Validated subset
  };
  parameters: {
    maxAccelerationRate: number;              // Strict: [1.0, 16.0]
    candidateConfirmationWindowMs: number;    // Strict: [10, 1000]
    safeRecoveryStabilityWindowMs: number;    // Strict: [50, 5000]
  };
}
```

---

## 5. Strict Staging Validation Rules & Anti-Pattern Guardrails

The main app validator (**ADR-0011**) enforces these hard rules before publishing any generation:

### 5.1 Domain Allowlist Ceiling (Monotonic Scope)
* **Binary Allowlist:** Hardcoded in the app binary: `["m.youtube.com", "www.youtube.com"]`.
* **Validation Rule:** Any entry in `disabledDomains` not present in the binary allowlist, or any attempt by the schema to define an active domain outside the binary allowlist, results in an **immediate generation validation failure**.

### 5.2 Selector Subset Validation Rules
Selectors in `rules.json` must be strictly declarative:
1. **Length & Depth Caps:**
   * Maximum length per selector string: $\le 256\text{ characters}$.
   * Maximum combinator depth (e.g. `>` or whitespace): $\le 4\text{ levels}$.
   * Maximum selector count per array: $\le 50\text{ items}$.
2. **Prohibited Constructs:**
   * Selectors containing `:has()`, `:is()`, or `:where()` exceeding depth $1$ are rejected.
   * Any substring matching `javascript:`, `expression(`, `-moz-binding`, `<script`, or `eval(` causes immediate staging rejection.

### 5.3 Strict Numeric Rejection (Zero Silent Clamping)
Out-of-range numeric parameters are **rejected**, never clamped:
* $1.0 \le \text{maxAccelerationRate} \le 16.0$
* $10 \le \text{candidateConfirmationWindowMs} \le 1000$
* $50 \le \text{safeRecoveryStabilityWindowMs} \le 5000$
* If any parameter is outside its envelope, staging validation throws and aborts publication.

### 5.4 Monotonic Capability Masking
Effective feature execution is computed as:
$$\text{EffectiveCapability} = \text{BinaryCapability} \land \neg(\text{RemoteDisableFlag})$$
The remote artifact can only narrow or disable capabilities, never introduce or enable behaviors absent from the binary release.

---

## 6. Task 5 Design Targets vs. Task 6 Measurement Contract

### 6.1 Task 5 Architectural Targets
* **Artifact Size:** Expected $< 2\text{ KB}$ uncompressed ($< 500\text{ B}$ compressed).
* **Parsing Budget:** Parsed **once** upon generation arrival in the background context; never reparsed per matched page load.
* **Lookup Overhead:** In-memory selector checks; zero disk I/O during video playback.
* **Memory Footprint:** Expected to be negligible ($< 15\text{ KB}$) in the extension process.

### 6.2 Task 6 Measurement Contract
Task 6 must empirically establish and benchmark:
1. Generation decode & validation latency in Swift and JS.
2. Background-to-content-script transfer latency across native messaging bridge.
3. Content-script startup & selector matching CPU budget on `m.youtube.com` and `www.youtube.com`.
4. `MutationObserver` callback rate, execution duration, and debounce threshold.
5. SPA navigation teardown, remount, and memory accumulation under 50+ video transitions.
6. Battery / energy impact under continuous playback workloads.

---

## 7. Next Steps

With the five architectural amendments applied and validated:
* **Task 5 Status:** **Complete / Ready for Validation**
* **Next Task:** **Task 6 — Performance, Observer Lifecycle, and Battery Budget** (Defining explicit execution timing budgets, observer lifecycle benchmarks, and energy constraints).
