# AdBlock Tester Failure Root-Cause Audit

**Date:** 2026-08-27  
**Scope:** Systematic end-to-end trace of 5 representative test failures on AdBlock Tester against upstream filter lists ([`easylist.txt`](file:///Users/sreeharshag/Work/ADBLX/ADBLX/Resources/Filters/easylist.txt), [`easyprivacy.txt`](file:///Users/sreeharshag/Work/ADBLX/ADBLX/Resources/Filters/easyprivacy.txt), [`fanboy-annoyances.txt`](file:///Users/sreeharshag/Work/ADBLX/ADBLX/Resources/Filters/fanboy-annoyances.txt)), the [`NativeABPRuleCompiler`](file:///Users/sreeharshag/Work/ADBLX/Packages/ADBLXShared/Sources/ADBLXShared/Compiler/NativeABPRuleCompiler.swift), and the generated Safari Content Blocker JSON artifacts.

---

## 1. Audit Summary Matrix

| # | Failed Test Category | Representative Request URL | Source Filter & Rule | Compiler Translation Status | Compiled Safari JSON Trigger/Action | Root-Cause Classification |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | **Contextual Advertising** | `https://googleads.g.doubleclick.net/pagead/ads` | `easylist.txt` (Line 59045)<br>`\|\|g.doubleclick.net^` | ✅ Successfully Compiled | `"url-filter": "^https?://([a-zA-Z0-9-]+\\.)*g\\.doubleclick\\.net([:/]|$)"`<br>`"action": {"type": "block"}` | **(3) & (4) Multi-Blocker / Deployment Gap**<br>Rule was present in EasyList corpus, but in the previous test run only the 70-rule synthetic fallback was loaded. |
| **2** | **Analytics Tools** | `https://www.google-analytics.com/analytics.js` | `easyprivacy.txt` (Line 4921)<br>`\|\|google-analytics.com^$script,third-party,xmlhttprequest` | ✅ Successfully Compiled | `"url-filter": "^https?://([a-zA-Z0-9-]+\\.)*google-analytics\\.com([:/]|$)"`<br>`"load-type": ["third-party"]`<br>`"resource-type": ["script", "xmlhttprequest"]`<br>`"action": {"type": "block"}` | **(1) & (4) Extension Pipeline Gap**<br>Rule is in EasyPrivacy (`Privacy.json`). When Privacy Blocker was disabled/unpopulated, Ads blocker alone did not catch it. |
| **3** | **Analytics Tools** | `https://mc.yandex.ru/metrika/watch.js` | `easyprivacy.txt` (Line 11914)<br>`\|\|mc.yandex.ru^` | ✅ Successfully Compiled | `"url-filter": "^https?://([a-zA-Z0-9-]+\\.)*mc\\.yandex\\.ru([:/]|$)"`<br>`"action": {"type": "block"}` | **(1) & (4) Extension Pipeline Gap**<br>Present in EasyPrivacy (`Privacy.json`). Requires active `ADBLXPrivacyBlocker` extension. |
| **4** | **Error Monitoring** | `https://browser.sentry-cdn.com/bundle.min.js` | `easyprivacy.txt` (Line 5906)<br>`\|\|sentry-cdn.com^$third-party,domain=~sentry.dev\|~sentry.io` | ✅ Successfully Compiled | `"url-filter": "^https?://([a-zA-Z0-9-]+\\.)*sentry-cdn\\.com([:/]|$)"`<br>`"load-type": ["third-party"]`<br>`"unless-domain": ["*sentry.dev", "*sentry.io"]`<br>`"action": {"type": "block"}` | **(1) & (4) Extension Pipeline Gap**<br>Present in EasyPrivacy (`Privacy.json`). Requires active `ADBLXPrivacyBlocker` extension. |
| **5** | **Banner Advertising** | `https://adblock-tester.com/pr_advertising_ads_banner.png` | `easylist.txt` (Line 4699)<br>`###pr_advertising` | ✅ Successfully Compiled (as cosmetic rule) | `"url-filter": ".*"`<br>`"action": {"type": "css-display-none", "selector": "#pr_advertising"}` | **(3) & (4) Safari Platform / Cosmetic Semantic Limitation**<br>First-party synthetic benchmark asset. EasyList hides DOM element `#pr_advertising` via CSS display none, but provides no first-party network block rule for the image URL. |

---

## 2. Detailed End-to-End Traces

### Case 1: Google DoubleClick / Ads (`googleads.g.doubleclick.net/pagead/ads`)

* **Request URL:** `https://googleads.g.doubleclick.net/pagead/ads?client=...`
* **Expected Behavior:** Request blocked at network layer.
* **Upstream Search:**
  * In `easylist.txt`: Line 59045 contains `||g.doubleclick.net^`.
  * Additional network rules: `||googlesyndication.com/pagead/` (Line 63271).
* **Compiler Trace (`NativeABPRuleCompiler`):**
  1. `ABPLexer.lex` classifies line as `.network(isException: false, rawPattern: "||g.doubleclick.net^", rawOptions: "")`.
  2. `ABPParser.parse` parses pattern into AST `.domainAnchor("g.doubleclick.net")`.
  3. `ABPSemanticValidator.validate` confirms supported network disposition.
  4. `SafariRuleGenerator.generateUrlFilter` converts `.domainAnchor("g.doubleclick.net")` to:
     ```regex
     ^https?://([a-zA-Z0-9-]+\.)*g\.doubleclick\.net([:/]|$)
     ```
  5. Emits `SafariContentBlockerRule(trigger: ..., action: .init(type: "block"))`.
* **Output Artifact:** Present in compiled `Compiled/Ads.json` (73,313 rules).
* **Failure Root Cause in Previous Test:** In previous test runs, `ADBLX` bootstrapped the synthetic 70-rule fallback fixture (`ads1.example.com`), omitting `easylist.txt`. Once the real `Ads.json` is deployed, this rule is active in WebKit.

---

### Case 2: Google Analytics (`www.google-analytics.com/analytics.js`)

* **Request URL:** `https://www.google-analytics.com/analytics.js`
* **Expected Behavior:** Network script request blocked.
* **Upstream Search:**
  * In `easyprivacy.txt`: Line 4921 contains `||google-analytics.com^$script,third-party,xmlhttprequest`.
* **Compiler Trace (`NativeABPRuleCompiler`):**
  1. `ABPParser.parse` identifies `.domainAnchor("google-analytics.com")` with modifiers `script,third-party,xmlhttprequest`.
  2. `ABPSemanticValidator.validate` maps `third-party` $\rightarrow$ `loadType = .thirdParty`, and `script,xmlhttprequest` $\rightarrow$ `resourceTypes = [.script, .xmlhttprequest]`.
  3. `SafariRuleGenerator` emits:
     ```json
     {
       "trigger": {
         "url-filter": "^https?://([a-zA-Z0-9-]+\\.)*google-analytics\\.com([:/]|$)",
         "load-type": ["third-party"],
         "resource-type": ["script", "xmlhttprequest"]
       },
       "action": {
         "type": "block"
       }
     }
     ```
* **Output Artifact:** Present in compiled `Compiled/Privacy.json` (55,817 rules).
* **Failure Root Cause in Previous Test:** EasyList does not contain general telemetry blocking rules for Google Analytics; they reside exclusively in EasyPrivacy. Because the previous test only had `ADBLXAdsBlocker` active with synthetic rules, all analytics requests passed through.

---

### Case 3: Yandex Metrica (`mc.yandex.ru/metrika/watch.js`)

* **Request URL:** `https://mc.yandex.ru/metrika/watch.js`
* **Expected Behavior:** Third-party tracking beacon blocked.
* **Upstream Search:**
  * In `easyprivacy.txt`: Line 11914 contains `||mc.yandex.ru^`.
* **Compiler Trace (`NativeABPRuleCompiler`):**
  1. `ABPParser.parse` identifies `.domainAnchor("mc.yandex.ru")`.
  2. `SafariRuleGenerator` emits:
     ```json
     {
       "trigger": {
         "url-filter": "^https?://([a-zA-Z0-9-]+\\.)*mc\\.yandex\\.ru([:/]|$)"
       },
       "action": {
         "type": "block"
       }
     }
     ```
* **Output Artifact:** Present in compiled `Compiled/Privacy.json` (55,817 rules).
* **Failure Root Cause in Previous Test:** Sits in the `Privacy` filter group. Requires `ADBLXPrivacyBlocker` extension to read `Compiled/Privacy.json`.

---

### Case 4: Sentry Error Monitoring (`browser.sentry-cdn.com/bundle.min.js`)

* **Request URL:** `https://browser.sentry-cdn.com/bundle.min.js`
* **Expected Behavior:** Error reporting beacon blocked on third-party domains.
* **Upstream Search:**
  * In `easyprivacy.txt`: Line 5906 contains `||sentry-cdn.com^$third-party,domain=~sentry.dev|~sentry.io`.
  * Line 5908 contains `||sentry.io^$third-party`.
* **Compiler Trace (`NativeABPRuleCompiler`):**
  1. `ABPParser.parse` parses pattern `.domainAnchor("sentry-cdn.com")` and negative domain modifier `~sentry.dev|~sentry.io`.
  2. `ABPSemanticValidator.validate` converts domain inversion into `unlessDomains: ["*sentry.dev", "*sentry.io"]`.
  3. `SafariRuleGenerator` emits:
     ```json
     {
       "trigger": {
         "url-filter": "^https?://([a-zA-Z0-9-]+\\.)*sentry-cdn\\.com([:/]|$)",
         "load-type": ["third-party"],
         "unless-domain": ["*sentry.dev", "*sentry.io"]
       },
       "action": {
         "type": "block"
       }
     }
     ```
* **Output Artifact:** Present in compiled `Compiled/Privacy.json` (55,817 rules).
* **Failure Root Cause in Previous Test:** Error monitoring is part of EasyPrivacy and not EasyList. `ADBLXPrivacyBlocker` was unpopulated.

---

### Case 5: Synthetic Ad Banner (`adblock-tester.com/pr_advertising_ads_banner.png`)

* **Request URL:** `https://adblock-tester.com/pr_advertising_ads_banner.png`
* **Expected Behavior in Test Suite:** Benchmark tests both (a) whether `#pr_advertising` is hidden, and (b) whether the image asset load is blocked.
* **Upstream Search:**
  * In `easylist.txt`: Line 4699 contains generic element hiding rule `###pr_advertising`.
  * No first-party network blocking rule exists for `||adblock-tester.com/pr_advertising_ads_banner.png` in upstream EasyList.
* **Compiler Trace (`NativeABPRuleCompiler`):**
  1. `ABPParser.parse` identifies `.cosmetic(domains: [], isException: false, selector: "#pr_advertising")`.
  2. `SafariRuleGenerator.generateCosmetic` converts it to:
     ```json
     {
       "trigger": {
         "url-filter": ".*"
       },
       "action": {
         "type": "css-display-none",
         "selector": "#pr_advertising"
       }
     }
     ```
* **Output Artifact:** Present in compiled `Compiled/Ads.json`.
* **Failure Root Cause:**
  * **Safari Content Blocker Semantic Limitation / Benchmark Design:** `css-display-none` hides the element in the DOM after page load, but Safari Content Blockers do not block the underlying network request for a `css-display-none` rule unless an accompanying `block` network rule matches the URL.
  * Because the image is served from the first-party domain (`adblock-tester.com`) without a dedicated network filter in EasyList, the network request succeeds, even though the visual element is hidden.

---

## 3. Structural Conclusions & Actionable Insights

1. **Compiler Correctness:** `NativeABPRuleCompiler` correctly parses network rules, load types (`third-party`), resource types (`script`, `xmlhttprequest`), domain constraints (`unless-domain`), and cosmetic CSS selectors. No rules among the audited cases were erroneously dropped by the parser.
2. **The 46/100 Root Cause:**
   * In previous test runs, `ADBLX` was only bootstrapping the synthetic 70-rule fallback fixture into `Ads.json`.
   * The `Privacy`, `Annoyances`, and `Regional` extensions were not populated with real rules.
   * Because categories like **Analytics (Google Analytics, Yandex)** and **Error Monitoring (Sentry, Bugsnag)** reside exclusively in **EasyPrivacy**, and banner ad networks reside in **EasyList**, activating both `AdsBlocker` (73k rules) and `PrivacyBlocker` (55k rules) addresses the majority of the failed test cases.
3. **Synthetic Benchmark Nuance (Cosmetic vs. Network):**
   * First-party synthetic image checks (like `pr_advertising_ads_banner.png`) rely on cosmetic hiding in EasyList (`###pr_advertising`). WebKit applies the CSS display none rule in Safari, but network-level assertions on first-party images will pass unless specific network rules exist.
