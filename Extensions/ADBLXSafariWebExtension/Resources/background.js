// background.js - Safari Web Extension Background Script (ADBLX Layer 3)
// Conforms to ADR-0010, ADR-0011, ADR-0012, and Sprint 9 Lifecycle Contract.

"use strict";

const FRESHNESS_CEILING_MS = 15 * 60 * 1000;      // 15 minutes
const GRACE_PERIOD_CEILING_MS = 4 * 60 * 60 * 1000; // 4 hours
const STORAGE_KEY = "adblx_layer3_cache";

// In-memory cache for the current background execution lifetime
let inMemoryState = {
    isHydrated: false,
    generation: 0,
    generationStatus: "unavailable",
    entitlementState: "unavailable",
    // Epoch ms after which premiumActive must be treated as expired; 0 = no expiry.
    validUntilMs: 0,
    rules: null,
    rulesFetchedAtWallClockMs: 0,
    lastVersionCheckWallClockMs: 0
};

// Single in-flight Promise gate to deduplicate concurrent requests
let inFlightRefreshPromise = null;

/**
 * Hydrates in-memory state from browser.storage.local on cold background boot.
 */
async function hydrateFromStorage() {
    if (inMemoryState.isHydrated) return;
    try {
        const stored = await browser.storage.local.get(STORAGE_KEY);
        if (stored && stored[STORAGE_KEY]) {
            const data = stored[STORAGE_KEY];
            inMemoryState.generation = data.generation || 0;
            inMemoryState.generationStatus = data.generationStatus || "unavailable";
            inMemoryState.entitlementState = data.entitlementState || "unavailable";
            inMemoryState.validUntilMs = data.validUntilMs || 0;
            inMemoryState.rules = data.rules || null;
            inMemoryState.rulesFetchedAtWallClockMs = data.rulesFetchedAtWallClockMs || 0;
            inMemoryState.lastVersionCheckWallClockMs = data.lastVersionCheckWallClockMs || 0;
        }
    } catch (e) {
        // Storage read error: proceed with default blank state
    } finally {
        inMemoryState.isHydrated = true;
    }
}

/**
 * Persists current in-memory cache to browser.storage.local.
 */
async function persistToStorage() {
    try {
        const data = {
            generation: inMemoryState.generation,
            generationStatus: inMemoryState.generationStatus,
            entitlementState: inMemoryState.entitlementState,
            validUntilMs: inMemoryState.validUntilMs,
            rules: inMemoryState.rules,
            rulesFetchedAtWallClockMs: inMemoryState.rulesFetchedAtWallClockMs,
            lastVersionCheckWallClockMs: inMemoryState.lastVersionCheckWallClockMs
        };
        await browser.storage.local.set({ [STORAGE_KEY]: data });
    } catch (e) {
        // Storage write error is non-fatal
    }
}

/**
 * Sends a native message to SafariWebExtensionHandler.swift with Promise wrapping.
 */
function sendNativeMessage(msg) {
    return new Promise((resolve) => {
        try {
            browser.runtime.sendNativeMessage(msg, (response) => {
                if (browser.runtime.lastError || !response) {
                    resolve(null);
                } else {
                    resolve(response);
                }
            });
        } catch (e) {
            resolve(null);
        }
    });
}

/**
 * Evaluates effective Layer 3 configuration based on authorization and rule-data freshness.
 */
function evaluateEffectiveConfig(nowWallClock) {
    // 1. Authorization: MUST be premiumActive. Fail-closed on 'free' or 'unavailable'.
    if (inMemoryState.entitlementState !== "premiumActive") {
        return {
            layer3Enabled: false,
            reason: inMemoryState.entitlementState === "free" ? "free_tier" : "entitlement_unavailable",
            generation: inMemoryState.generation,
            rules: null
        };
    }

    // 1b. Expiry: the app may not run again before validUntil, so the extension enforces it
    // itself with a single comparison. Fail closed.
    if (inMemoryState.validUntilMs > 0 && nowWallClock >= inMemoryState.validUntilMs) {
        return {
            layer3Enabled: false,
            reason: "entitlement_expired",
            generation: inMemoryState.generation,
            rules: null
        };
    }

    // 2. Rule Data: Must have parsed rules within the 4-hour grace ceiling.
    if (inMemoryState.rules) {
        const rulesAgeMs = nowWallClock - inMemoryState.rulesFetchedAtWallClockMs;
        if (rulesAgeMs <= GRACE_PERIOD_CEILING_MS || inMemoryState.generationStatus === "ok") {
            return {
                layer3Enabled: true,
                generation: inMemoryState.generation,
                rules: inMemoryState.rules,
                isGracePeriod: inMemoryState.generationStatus === "unavailable"
            };
        }
    }

    // 3. No valid rules or rules exceeded 4-hour grace bound
    return {
        layer3Enabled: false,
        reason: "rules_unavailable_or_expired",
        generation: inMemoryState.generation,
        rules: null
    };
}

/**
 * Retrieves the current Layer 3 configuration, refreshing from native bridge if stale (>15 min).
 */
async function getLayer3State(force = false) {
    await hydrateFromStorage();

    const nowWallClock = Date.now();
    const versionCheckAgeMs = nowWallClock - inMemoryState.lastVersionCheckWallClockMs;
    // A negative age means the wall clock moved backwards since the last check; treat it
    // as stale so a future-dated timestamp cannot keep a cached entitlement "fresh".
    const isVersionCheckStale = versionCheckAgeMs > FRESHNESS_CEILING_MS || versionCheckAgeMs < 0;

    // Fast path: cached version check is fresh (<15 min) and we are not forced
    if (!force && !isVersionCheckStale && inMemoryState.lastVersionCheckWallClockMs > 0) {
        return evaluateEffectiveConfig(nowWallClock);
    }

    // Deduplicate concurrent revalidations through a single in-flight Promise
    if (inFlightRefreshPromise) {
        return inFlightRefreshPromise;
    }

    inFlightRefreshPromise = (async () => {
        try {
            // Captured before the field is overwritten: the transport-failure path below
            // needs the last SUCCESSFUL verification time to age the entitlement grace
            // window, not the timestamp of this (possibly failed) attempt.
            const priorCheckMs = inMemoryState.lastVersionCheckWallClockMs || 0;

            const versionRes = await sendNativeMessage({ type: "checkVersion" });
            const checkTimestamp = Date.now();
            inMemoryState.lastVersionCheckWallClockMs = checkTimestamp;

            if (!versionRes) {
                // Transport failure: the bridge conveyed NO entitlement information, which
                // is not the same as reporting that the user is not entitled. The event
                // page is suspended and woken constantly, so a single hiccup on wake used
                // to disable Layer 3 for the whole session. Keep a previously verified
                // premium entitlement within the same grace ceiling rule data already uses,
                // and fail closed once that window lapses.
                //
                // A bridge that DOES answer with "free"/"unavailable" still fails closed
                // immediately, below — that path is unchanged (ADR-0012).
                inMemoryState.generationStatus = "unavailable";

                const entitlementAgeMs = checkTimestamp - priorCheckMs;
                const withinGrace = inMemoryState.entitlementState === "premiumActive" &&
                    priorCheckMs > 0 &&
                    // A negative age means the wall clock moved backwards since the last
                    // verification; the window cannot be measured, so fail closed.
                    entitlementAgeMs >= 0 &&
                    entitlementAgeMs <= GRACE_PERIOD_CEILING_MS;

                if (!withinGrace) {
                    inMemoryState.entitlementState = "unavailable";
                }

                // Preserve the last successful verification time; overwriting it with this
                // failed attempt would silently extend the grace window on every failure.
                inMemoryState.lastVersionCheckWallClockMs = priorCheckMs;

                await persistToStorage();
                return evaluateEffectiveConfig(checkTimestamp);
            }

            const remoteGen = versionRes.generation || 0;
            const remoteGenStatus = versionRes.generationStatus || "unavailable";
            const remoteEntState = versionRes.entitlementState || "unavailable";

            inMemoryState.generationStatus = remoteGenStatus;
            inMemoryState.entitlementState = remoteEntState;
            inMemoryState.validUntilMs = Number(versionRes.validUntilMs) > 0 ? Number(versionRes.validUntilMs) : 0;

            // If not premium, persist and return fail-closed config immediately
            if (remoteEntState !== "premiumActive") {
                await persistToStorage();
                return evaluateEffectiveConfig(checkTimestamp);
            }

            // If generation available and changed (or no rules in memory), fetch rules
            if (remoteGenStatus === "ok" && (remoteGen !== inMemoryState.generation || !inMemoryState.rules)) {
                const fetchRes = await sendNativeMessage({ type: "fetchGeneration", generation: remoteGen });
                if (fetchRes && fetchRes.generationStatus === "ok" && fetchRes.rules) {
                    inMemoryState.generation = remoteGen;
                    inMemoryState.rules = fetchRes.rules;
                    inMemoryState.rulesFetchedAtWallClockMs = checkTimestamp;
                }
            }

            await persistToStorage();
            return evaluateEffectiveConfig(checkTimestamp);
        } finally {
            inFlightRefreshPromise = null;
        }
    })();

    return inFlightRefreshPromise;
}

// Internal extension message router for content scripts
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === "getLayer3Config") {
        getLayer3State(message.force === true).then(config => {
            sendResponse(config);
        }).catch(err => {
            sendResponse({ layer3Enabled: false, error: err ? err.message : "unknown_error" });
        });
        return true; // Indicates asynchronous response
    }
});

// Export for node/unit testing environment if present
if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        FRESHNESS_CEILING_MS,
        GRACE_PERIOD_CEILING_MS,
        STORAGE_KEY,
        inMemoryState,
        hydrateFromStorage,
        persistToStorage,
        sendNativeMessage,
        evaluateEffectiveConfig,
        getLayer3State
    };
}
