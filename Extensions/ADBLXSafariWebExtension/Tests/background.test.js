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
    // SEC-18: nothing verified it, so it's no longer passed on, even from a host that still sends it.
    assert.equal("checksum" in config, false);

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

// Regression (device-observed, 2026-09-06): mid-session the content script logged
// "mountPlayer: SKIPPED — layer3Enabled= false" after it had previously been true.
// Cause: any transient sendNativeMessage failure (versionRes === null) set
// entitlementState = "unavailable" and persisted it, permanently disabling Layer 3 for
// the session. The event-page background is suspended and woken constantly, so a single
// bridge hiccup on wake was enough. A transport failure is not evidence that the user
// stopped being premium — it carries no entitlement information at all. This is distinct
// from the bridge successfully REPORTING "unavailable"/"free", which must still fail
// closed immediately (see the two tests above; ADR-0012).
test("Bridge transport failure keeps recently-verified premium entitlement within grace", async () => {
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
            lastVersionCheckWallClockMs: now - 16 * 60 * 1000
        }
    });

    // Bridge does not answer at all — no entitlement information conveyed.
    env.queueNativeResponse(null);

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, true,
        "a transport failure must not be treated as loss of entitlement");
});

test("Bridge transport failure past the entitlement grace window disables Layer 3", async () => {
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
            // Last successful verification is older than the 4h grace ceiling.
            lastVersionCheckWallClockMs: now - (5 * 60 * 60 * 1000)
        }
    });

    env.queueNativeResponse(null);

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, false,
        "entitlement must not be trusted indefinitely across bridge failures");
    assert.equal(config.reason, "entitlement_unavailable");
});

test("Bridge transport failure with the device clock set backwards disables Layer 3", async () => {
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
            // Verified "in the future": the clock has since been moved back. The age is
            // negative, which must not read as "within the grace window".
            lastVersionCheckWallClockMs: now + (30 * 24 * 60 * 60 * 1000)
        }
    });

    env.queueNativeResponse(null);

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();

    assert.equal(config.layer3Enabled, false,
        "a negative entitlement age must fail closed, not extend the grace window");
    assert.equal(config.reason, "entitlement_unavailable");
});

test("Forced refresh with the clock set backwards and a failing bridge disables Layer 3", async () => {
    // Isolates the grace-window clause: force skips the freshness fast path, so the
    // transport-failure branch runs with a negative entitlement age.
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
            lastVersionCheckWallClockMs: now + (30 * 24 * 60 * 60 * 1000)
        }
    });
    env.queueNativeResponse(null);

    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State(true);

    assert.equal(config.layer3Enabled, false);
    assert.equal(config.reason, "entitlement_unavailable");
});

test("validUntil: cached premium is disabled once validUntilMs has passed, even inside the freshness window", async () => {
    const env = createMockEnvironment();
    const now = Date.now();
    env.setStorageData({
        adblx_layer3_cache: {
            generation: 5,
            generationStatus: "ok",
            entitlementState: "premiumActive",
            validUntilMs: now - 1,
            rules: { schemaVersion: 1, cached: true },
            checksum: "c",
            rulesFetchedAtWallClockMs: now - 1000,
            lastVersionCheckWallClockMs: now - 1000
        }
    });
    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();
    assert.equal(config.layer3Enabled, false);
    assert.equal(config.reason, "entitlement_expired");
    assert.equal(env.getNativeMessagesSent().length, 0);
});

test("validUntil: cached premium stays enabled while validUntilMs is in the future", async () => {
    const env = createMockEnvironment();
    const now = Date.now();
    env.setStorageData({
        adblx_layer3_cache: {
            generation: 5,
            generationStatus: "ok",
            entitlementState: "premiumActive",
            validUntilMs: now + 60000,
            rules: { schemaVersion: 1, cached: true },
            checksum: "c",
            rulesFetchedAtWallClockMs: now - 1000,
            lastVersionCheckWallClockMs: now - 1000
        }
    });
    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();
    assert.equal(config.layer3Enabled, true);
});

test("validUntil: absent validUntilMs (lifetime / legacy) never expires", async () => {
    const env = createMockEnvironment();
    const now = Date.now();
    env.setStorageData({
        adblx_layer3_cache: {
            generation: 5,
            generationStatus: "ok",
            entitlementState: "premiumActive",
            rules: { schemaVersion: 1, cached: true },
            checksum: "c",
            rulesFetchedAtWallClockMs: now - 1000,
            lastVersionCheckWallClockMs: now - 1000
        }
    });
    const bg = loadBackgroundWithMock(env);
    const config = await bg.getLayer3State();
    assert.equal(config.layer3Enabled, true);
});

test("validUntil: bridge-reported validUntilMs is persisted and enforced on the next fast-path read", async () => {
    const env = createMockEnvironment();
    env.queueNativeResponse({
        generation: 1,
        generationStatus: "ok",
        entitlementState: "premiumActive",
        validUntilMs: Date.now() + 60000,
        checkedAt: 1
    });
    env.queueNativeResponse({
        generation: 1, generationStatus: "ok", rules: { schemaVersion: 1 }, checksum: "c"
    });
    const bg = loadBackgroundWithMock(env);
    await bg.getLayer3State();
    const stored = env.getStorageData()[bg.STORAGE_KEY];
    assert.ok(stored.validUntilMs > Date.now());
});
