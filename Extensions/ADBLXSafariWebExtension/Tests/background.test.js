// background.test.js - Comprehensive lifecycle and caching test suite for background.js
const test = require("node:test");
const assert = require("node:assert/strict");

function createMockEnvironment() {
    let storageData = {};
    let nativeMessageResponses = [];
    let nativeMessagesSent = [];
    let messageListeners = [];

    const mockBrowser = {
        storage: {
            local: {
                get: async (key) => {
                    return { [key]: storageData[key] ? JSON.parse(JSON.stringify(storageData[key])) : undefined };
                },
                set: async (obj) => {
                    storageData = { ...storageData, ...JSON.parse(JSON.stringify(obj)) };
                }
            }
        },
        runtime: {
            lastError: null,
            sendNativeMessage: (msg, callback) => {
                nativeMessagesSent.push(msg);
                const nextResponse = nativeMessageResponses.shift();
                if (nextResponse instanceof Error) {
                    mockBrowser.runtime.lastError = nextResponse;
                    callback(null);
                    mockBrowser.runtime.lastError = null;
                } else {
                    callback(nextResponse || null);
                }
            },
            onMessage: {
                addListener: (fn) => {
                    messageListeners.push(fn);
                }
            }
        }
    };

    return {
        mockBrowser,
        getStorageData: () => storageData,
        setStorageData: (data) => { storageData = data; },
        queueNativeResponse: (res) => nativeMessageResponses.push(res),
        getNativeMessagesSent: () => nativeMessagesSent,
        dispatchRuntimeMessage: (msg) => {
            return new Promise((resolve) => {
                for (const listener of messageListeners) {
                    listener(msg, {}, resolve);
                }
            });
        }
    };
}

function loadBackgroundWithMock(env) {
    global.browser = env.mockBrowser;
    // Clear require cache to get fresh background.js instance
    delete require.cache[require.resolve("../Resources/background.js")];
    return require("../Resources/background.js");
}

test("Cold boot: checkVersion -> fetchGeneration -> storage.local persisted", async () => {
    const env = createMockEnvironment();
    env.queueNativeResponse({
        generation: 1,
        generationStatus: "ok",
        entitlementState: "premiumActive",
        checkedAt: 1000
    });
    env.queueNativeResponse({
        generation: 1,
        generationStatus: "ok",
        rules: { schemaVersion: 1, youtube: { enabled: true } },
        checksum: "sha256_mock"
    });

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, true);
    assert.equal(config.generation, 1);
    assert.deepEqual(config.rules, { schemaVersion: 1, youtube: { enabled: true } });
    assert.equal(config.checksum, "sha256_mock");

    const sent = env.getNativeMessagesSent();
    assert.equal(sent.length, 2);
    assert.equal(sent[0].type, "checkVersion");
    assert.equal(sent[1].type, "fetchGeneration");
    assert.equal(sent[1].generation, 1);

    // Verify storage.local received the warm cache
    const stored = env.getStorageData()[bg.STORAGE_KEY];
    assert.ok(stored);
    assert.equal(stored.generation, 1);
    assert.equal(stored.entitlementState, "premiumActive");
});

test("Warm cache: fast path without bridge calls when within 15-minute freshness ceiling", async () => {
    const env = createMockEnvironment();
    const now = Date.now();
    env.setStorageData({
        [ "adblx_layer3_cache" ]: {
            generation: 5,
            generationStatus: "ok",
            entitlementState: "premiumActive",
            rules: { schemaVersion: 1, cached: true },
            checksum: "sha256_5",
            rulesFetchedAtWallClockMs: now - 60000, // 1 min ago
            lastVersionCheckWallClockMs: now - 60000 // 1 min ago (< 15 min)
        }
    });

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, true);
    assert.equal(config.generation, 5);
    assert.deepEqual(config.rules, { schemaVersion: 1, cached: true });

    // Native bridge should NOT have been queried
    assert.equal(env.getNativeMessagesSent().length, 0);
});

test("15-minute freshness expiry: triggers checkVersion", async () => {
    const env = createMockEnvironment();
    const now = Date.now();
    env.setStorageData({
        [ "adblx_layer3_cache" ]: {
            generation: 5,
            generationStatus: "ok",
            entitlementState: "premiumActive",
            rules: { schemaVersion: 1, cached: true },
            checksum: "sha256_5",
            rulesFetchedAtWallClockMs: now - 20 * 60 * 1000,
            lastVersionCheckWallClockMs: now - 16 * 60 * 1000 // 16 min ago (> 15 min)
        }
    });

    // Native bridge returns generation 5 unchanged
    env.queueNativeResponse({
        generation: 5,
        generationStatus: "ok",
        entitlementState: "premiumActive",
        checkedAt: now
    });

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, true);
    assert.equal(config.generation, 5);

    // Only checkVersion called, not fetchGeneration (since generation unchanged)
    const sent = env.getNativeMessagesSent();
    assert.equal(sent.length, 1);
    assert.equal(sent[0].type, "checkVersion");
});

test("Entitlement failure: unavailable immediately disables Layer 3 without using cached premium", async () => {
    const env = createMockEnvironment();
    const now = Date.now();
    env.setStorageData({
        [ "adblx_layer3_cache" ]: {
            generation: 5,
            generationStatus: "ok",
            entitlementState: "premiumActive",
            rules: { schemaVersion: 1, cached: true },
            checksum: "sha256_5",
            rulesFetchedAtWallClockMs: now - 60000,
            lastVersionCheckWallClockMs: now - 16 * 60 * 1000 // Stale
        }
    });

    // Native bridge reports entitlement unavailable
    env.queueNativeResponse({
        generation: 5,
        generationStatus: "ok",
        entitlementState: "unavailable",
        checkedAt: now
    });

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, false);
    assert.equal(config.reason, "entitlement_unavailable");
    assert.equal(config.rules, null);
});

test("Entitlement free: explicitly disables Layer 3", async () => {
    const env = createMockEnvironment();
    env.queueNativeResponse({
        generation: 1,
        generationStatus: "ok",
        entitlementState: "free",
        checkedAt: 1000
    });

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, false);
    assert.equal(config.reason, "free_tier");
    assert.equal(config.rules, null);
});

test("Rule data degradation: generation unavailable with cached rules <= 4h serves grace rules", async () => {
    const env = createMockEnvironment();
    const now = Date.now();
    env.setStorageData({
        [ "adblx_layer3_cache" ]: {
            generation: 3,
            generationStatus: "ok",
            entitlementState: "premiumActive",
            rules: { schemaVersion: 1, grace: true },
            checksum: "sha256_3",
            rulesFetchedAtWallClockMs: now - 2 * 60 * 60 * 1000, // 2 hours old (<= 4h)
            lastVersionCheckWallClockMs: now - 16 * 60 * 1000
        }
    });

    // Bridge reports generation unavailable, but entitlement active
    env.queueNativeResponse({
        generation: 0,
        generationStatus: "unavailable",
        entitlementState: "premiumActive",
        checkedAt: now
    });

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, true);
    assert.equal(config.isGracePeriod, true);
    assert.deepEqual(config.rules, { schemaVersion: 1, grace: true });
});

test("Rule data degradation: generation unavailable with cached rules > 4h disables Layer 3", async () => {
    const env = createMockEnvironment();
    const now = Date.now();
    env.setStorageData({
        [ "adblx_layer3_cache" ]: {
            generation: 3,
            generationStatus: "ok",
            entitlementState: "premiumActive",
            rules: { schemaVersion: 1, grace: true },
            checksum: "sha256_3",
            rulesFetchedAtWallClockMs: now - 5 * 60 * 60 * 1000, // 5 hours old (> 4h)
            lastVersionCheckWallClockMs: now - 16 * 60 * 1000
        }
    });

    // Bridge reports generation unavailable, but entitlement active
    env.queueNativeResponse({
        generation: 0,
        generationStatus: "unavailable",
        entitlementState: "premiumActive",
        checkedAt: now
    });

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, false);
    assert.equal(config.reason, "rules_unavailable_or_expired");
    assert.equal(config.rules, null);
});

test("Concurrent queries deduplicated through single in-flight Promise", async () => {
    const env = createMockEnvironment();
    env.queueNativeResponse({
        generation: 1,
        generationStatus: "ok",
        entitlementState: "premiumActive",
        checkedAt: 1000
    });
    env.queueNativeResponse({
        generation: 1,
        generationStatus: "ok",
        rules: { schemaVersion: 1, dedupe: true },
        checksum: "sha256_dedupe"
    });

    const bg = loadBackgroundWithMock(env);
    
    // Fire two requests concurrently
    const [res1, res2] = await Promise.all([
        bg.getLayer3State(),
        bg.getLayer3State()
    ]);

    assert.equal(res1.layer3Enabled, true);
    assert.equal(res2.layer3Enabled, true);
    assert.deepEqual(res1.rules, res2.rules);

    // Exactly one checkVersion and one fetchGeneration should have been sent
    const sent = env.getNativeMessagesSent();
    assert.equal(sent.length, 2);
});

test("Runtime message router handles getLayer3Config", async () => {
    const env = createMockEnvironment();
    env.queueNativeResponse({
        generation: 2,
        generationStatus: "ok",
        entitlementState: "premiumActive",
        checkedAt: 1000
    });
    env.queueNativeResponse({
        generation: 2,
        generationStatus: "ok",
        rules: { schemaVersion: 1, routed: true },
        checksum: "sha256_2"
    });

    loadBackgroundWithMock(env);
    const response = await env.dispatchRuntimeMessage({ type: "getLayer3Config" });

    assert.equal(response.layer3Enabled, true);
    assert.equal(response.generation, 2);
    assert.deepEqual(response.rules, { schemaVersion: 1, routed: true });
});
