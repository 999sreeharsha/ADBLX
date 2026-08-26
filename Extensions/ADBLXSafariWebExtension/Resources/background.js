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
    rules: null,
    checksum: null,
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
            inMemoryState.rules = data.rules || null;
            inMemoryState.checksum = data.checksum || null;
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
            rules: inMemoryState.rules,
            checksum: inMemoryState.checksum,
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

    // 2. Rule Data: Must have parsed rules within the 4-hour grace ceiling.
    if (inMemoryState.rules) {
        const rulesAgeMs = nowWallClock - inMemoryState.rulesFetchedAtWallClockMs;
        if (rulesAgeMs <= GRACE_PERIOD_CEILING_MS || inMemoryState.generationStatus === "ok") {
            return {
                layer3Enabled: true,
                generation: inMemoryState.generation,
                rules: inMemoryState.rules,
                checksum: inMemoryState.checksum,
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
    const isVersionCheckStale = (nowWallClock - inMemoryState.lastVersionCheckWallClockMs) > FRESHNESS_CEILING_MS;

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
            const versionRes = await sendNativeMessage({ type: "checkVersion" });
            const checkTimestamp = Date.now();
            inMemoryState.lastVersionCheckWallClockMs = checkTimestamp;

            if (!versionRes) {
                // Native bridge failure: fail closed immediately for entitlement
                inMemoryState.generationStatus = "unavailable";
                inMemoryState.entitlementState = "unavailable";
                await persistToStorage();
                return evaluateEffectiveConfig(checkTimestamp);
            }

            const remoteGen = versionRes.generation || 0;
            const remoteGenStatus = versionRes.generationStatus || "unavailable";
            const remoteEntState = versionRes.entitlementState || "unavailable";

            inMemoryState.generationStatus = remoteGenStatus;
            inMemoryState.entitlementState = remoteEntState;

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
                    inMemoryState.checksum = fetchRes.checksum || null;
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
