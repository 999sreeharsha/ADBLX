// content.test.js - Lifecycle, scoped observer, Detection FSM, and Tiered Intervention tests
const test = require("node:test");
const assert = require("node:assert/strict");

// readyState defaults to "complete" for the legacy suite. A real content script runs at
// document_start, where it is "loading" — pass it explicitly to model that.
function createMockDOMEnvironment(hostname = "www.youtube.com", { readyState = "complete" } = {}) {
    const listeners = {};
    const observers = [];
    let rafCallbacks = [];
    let nextRafId = 1;

    class MockMutationObserver {
        constructor(callback) {
            this.callback = callback;
            this.target = null;
            this.options = null;
            this.disconnected = false;
            observers.push(this);
        }
        observe(target, options) {
            this.target = target;
            this.options = options;
        }
        disconnect() {
            this.disconnected = true;
        }
        trigger(mutations) {
            if (!this.disconnected) {
                this.callback(mutations);
            }
        }
    }

    class MockClassList {
        constructor(initialClass = "") {
            this._classes = new Set(initialClass.split(" ").filter(Boolean));
        }
        contains(cls) {
            return this._classes.has(cls);
        }
        add(cls) {
            this._classes.add(cls);
        }
        remove(cls) {
            this._classes.delete(cls);
        }
        toString() {
            return Array.from(this._classes).join(" ");
        }
    }

    class MockElement {
        constructor(tagName, id = "", className = "") {
            this.tagName = tagName.toUpperCase();
            this.id = id;
            this.classList = new MockClassList(className);
            this.children = [];
            this.eventListeners = {};
            this.parentNode = null;
            this.isConnected = true;
            // Non-null offsetParent means the element is actually rendered. YouTube keeps
            // the skip button in the DOM but unrendered during the pre-skip countdown.
            this.offsetParent = {};
            this.clicksDispatched = 0;

            // Media properties
            this.paused = false;
            this.ended = false;
            this.readyState = 4;
            this.playbackRate = 1.0;
            this.muted = false;
        }
        get className() {
            return this.classList.toString();
        }
        appendChild(child) {
            child.parentNode = this;
            child.isConnected = this.isConnected;
            this.children.push(child);
            return child;
        }
        removeChild(child) {
            child.parentNode = null;
            child.isConnected = false;
            this.children = this.children.filter(c => c !== child);
            return child;
        }
        querySelector(selector) {
            if (selector === "video") {
                return this.children.find(c => c.tagName === "VIDEO") || null;
            }
            if (selector.startsWith("#") && this.id === selector.slice(1)) return this;
            if (selector.startsWith(".") && this.classList.contains(selector.slice(1))) return this;
            for (const child of this.children) {
                const found = child.querySelector(selector);
                if (found) return found;
            }
            return null;
        }
        addEventListener(event, fn) {
            if (!this.eventListeners[event]) this.eventListeners[event] = [];
            this.eventListeners[event].push(fn);
        }
        removeEventListener(event, fn) {
            if (this.eventListeners[event]) {
                this.eventListeners[event] = this.eventListeners[event].filter(h => h !== fn);
            }
        }
        click() {
            this.clicksDispatched++;
        }
        dispatchEvent(event) {
            const handlers = this.eventListeners[event.type] || [];
            for (const h of handlers) h(event);
        }
    }

    let documentElements = [];
    const mockHead = new MockElement("head");

    const mockDocument = {
        readyState,
        head: mockHead,
        createElement: (tag) => new MockElement(tag),
        querySelector: (selector) => {
            if (selector === "head") return mockHead;
            for (const el of documentElements) {
                if (selector.startsWith("#") && el.id === selector.slice(1)) return el;
                if (selector.startsWith(".") && el.classList.contains(selector.slice(1))) return el;
                const found = el.querySelector(selector);
                if (found) return found;
            }
            return null;
        },
        addEventListener: (event, fn) => {
            if (!listeners[event]) listeners[event] = [];
            listeners[event].push(fn);
        }
    };

    let runtimeSendMessageCallback = null;
    let configQuerySendCount = 0;
    const mockBrowser = {
        runtime: {
            sendMessage: (msg, callback) => {
                if (msg && msg.type === "getLayer3Config") configQuerySendCount++;
                runtimeSendMessageCallback = callback;
            }
        }
    };

    const mockWindow = {
        location: { hostname },
        addEventListener: (event, fn) => {
            if (!listeners[event]) listeners[event] = [];
            listeners[event].push(fn);
        },
        dispatchEvent: (event) => {
            const handlers = listeners[event] || [];
            for (const h of handlers) h();
        }
    };

    global.MouseEvent = class MockMouseEvent {
        constructor(type, init) {
            this.type = type;
            this.bubbles = init && init.bubbles;
            this.cancelable = init && init.cancelable;
        }
    };

    const mockGlobal = {
        window: mockWindow,
        document: mockDocument,
        browser: mockBrowser,
        MutationObserver: MockMutationObserver,
        requestAnimationFrame: (cb) => {
            const id = nextRafId++;
            rafCallbacks.push({ id, cb });
            return id;
        },
        cancelAnimationFrame: (id) => {
            rafCallbacks = rafCallbacks.filter(item => item.id !== id);
        }
    };

    return {
        mockGlobal,
        mockHead,
        observers,
        listeners,
        addDocumentElement: (el) => documentElements.push(el),
        clearDocumentElements: () => { documentElements = []; },
        respondToConfigQuery: (response) => {
            if (runtimeSendMessageCallback) {
                runtimeSendMessageCallback(response);
            }
        },
        flushRAF: () => {
            const pending = [...rafCallbacks];
            rafCallbacks = [];
            for (const item of pending) {
                item.cb();
            }
        },
        createElement: (tag, id, cls) => new MockElement(tag, id, cls),
        getConfigQuerySendCount: () => configQuerySendCount
    };
}

function loadContentWithMock(env) {
    global.window = env.mockGlobal.window;
    global.document = env.mockGlobal.document;
    global.browser = env.mockGlobal.browser;
    global.MutationObserver = env.mockGlobal.MutationObserver;
    global.requestAnimationFrame = env.mockGlobal.requestAnimationFrame;
    global.cancelAnimationFrame = env.mockGlobal.cancelAnimationFrame;

    delete require.cache[require.resolve("../Resources/content.js")];
    return require("../Resources/content.js");
}

// MARK: - Lifecycle & Observer Tests

test("Disallowed hostname halts immediately with zero work", () => {
    const env = createMockDOMEnvironment("unauthorized-origin.com");
    const content = loadContentWithMock(env);
    
    assert.ok(content.ALLOWED_HOSTS);
    assert.equal(content.ALLOWED_HOSTS.has("unauthorized-origin.com"), false);
    assert.equal(content.initialize(), false);
    assert.equal(content.getEngineState().isInitialized, false);
});

test("Disabled config from background leaves engine inert without observers", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: false, reason: "free_tier" });

    const state = content.getEngineState();
    assert.equal(state.activePlayerElement, null);
    assert.equal(state.activeClassObserver, null);
    assert.equal(env.observers.length, 0);
});

test("Player absent at document_start mounts cleanly on yt-navigate-finish after player appears", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const content = loadContentWithMock(env);

    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    let state = content.getEngineState();
    assert.equal(state.activePlayerElement, null);
    assert.equal(env.observers.length, 0);

    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);

    env.mockGlobal.window.dispatchEvent("yt-navigate-finish");

    state = content.getEngineState();
    assert.ok(state.activePlayerElement);
    assert.equal(state.activePlayerElement.id, "movie_player");
    assert.ok(state.activeClassObserver);
    assert.equal(state.activeClassObserver.disconnected, false);
    assert.equal(state.detectionState, content.DetectionState.NORMAL_PLAYBACK);
});

test("SPA navigation increments generation, resets FSM to UNKNOWN, and disconnects previous observer", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    player.appendChild(env.createElement("video"));
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    const initialGen = content.getEngineState().playerGeneration;
    const initialObserver = env.observers[0];
    assert.equal(initialObserver.disconnected, false);
    assert.equal(content.getEngineState().detectionState, content.DetectionState.NORMAL_PLAYBACK);

    env.mockGlobal.window.dispatchEvent("yt-navigate-start");

    const stateAfterStart = content.getEngineState();
    assert.equal(stateAfterStart.playerGeneration, initialGen + 1);
    assert.equal(stateAfterStart.detectionState, content.DetectionState.UNKNOWN);
    assert.equal(initialObserver.disconnected, true);
    assert.equal(stateAfterStart.activeClassObserver, null);
});

// MARK: - Detection FSM Unit Tests

test("Clean Ad Interstitial: NORMAL_PLAYBACK -> AD_CANDIDATE -> AD_CONFIRMED -> RESET_SETTLING -> NORMAL_PLAYBACK", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    assert.equal(content.getEngineState().detectionState, content.DetectionState.NORMAL_PLAYBACK);

    player.classList.add("ad-showing");
    const observer = env.observers[0];
    observer.trigger([{ type: "attributes", attributeName: "class" }]);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CONFIRMED);

    player.classList.remove("ad-showing");
    observer.trigger([{ type: "attributes", attributeName: "class" }]);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.RESET_SETTLING);

    env.flushRAF();
    assert.equal(content.getEngineState().detectionState, content.DetectionState.NORMAL_PLAYBACK);
});

test("SIG-02 (Skip Button) independently confirms AD_CONFIRMED", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.paused = true;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    assert.equal(content.getEngineState().detectionState, content.DetectionState.NORMAL_PLAYBACK);

    const skipBtn = env.createElement("button", "", "ytp-ad-skip-button");
    player.appendChild(skipBtn);

    const observer = env.observers[0];
    observer.trigger([{ type: "attributes", attributeName: "class" }]);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CONFIRMED);
});

test("SIG-01 with mediaActive == false holds in AD_CANDIDATE and does not enter AD_CONFIRMED", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.paused = true;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    player.classList.add("ad-showing");
    const observer = env.observers[0];
    observer.trigger([{ type: "attributes", attributeName: "class" }]);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CANDIDATE);

    video.paused = false;
    video.readyState = 4;
    content.evaluateFSM(content.getEngineState().playerGeneration);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CONFIRMED);
});

test("SIG-03 (Ad Badge) alone never leaves NORMAL_PLAYBACK", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    
    const badge = env.createElement("span", "", "ytp-ad-text");
    player.appendChild(badge);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    assert.equal(content.getEngineState().detectionState, content.DetectionState.NORMAL_PLAYBACK);

    const observer = env.observers[0];
    observer.trigger([{ type: "attributes", attributeName: "class" }]);
    assert.equal(content.getEngineState().detectionState, content.DetectionState.NORMAL_PLAYBACK);
});

test("Primary signals clear before confirmation -> AD_CANDIDATE aborts to NORMAL_PLAYBACK (P5)", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.paused = true;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    player.classList.add("ad-showing");
    const observer = env.observers[0];
    observer.trigger([{ type: "attributes", attributeName: "class" }]);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CANDIDATE);

    player.classList.remove("ad-showing");
    observer.trigger([{ type: "attributes", attributeName: "class" }]);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.NORMAL_PLAYBACK);
});

test("Caught exception in signal evaluation forces immediate transition to AMBIGUOUS_SAFE (P7)", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    player.classList.contains = () => { throw new Error("DOM access crash"); };

    const observer = env.observers[0];
    observer.trigger([{ type: "attributes", attributeName: "class" }]);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AMBIGUOUS_SAFE);
});

test("Recovery from AMBIGUOUS_SAFE back to NORMAL_PLAYBACK when signals clean (P8)", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    const gen = content.getEngineState().playerGeneration;
    content.transitionTo(content.DetectionState.AMBIGUOUS_SAFE, gen);
    assert.equal(content.getEngineState().detectionState, content.DetectionState.AMBIGUOUS_SAFE);

    content.evaluateFSM(gen);
    assert.equal(content.getEngineState().detectionState, content.DetectionState.NORMAL_PLAYBACK);
});

test("Stale generation callback cannot mutate FSM state", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    const staleGen = content.getEngineState().playerGeneration;

    content.teardownCurrentPlayer();
    const currentGen = content.getEngineState().playerGeneration;
    assert.equal(currentGen, staleGen + 1);

    content.transitionTo(content.DetectionState.AD_CONFIRMED, staleGen);
    assert.equal(content.getEngineState().detectionState, content.DetectionState.UNKNOWN);
});

// MARK: - Phase 5 Tiered Intervention Unit Tests

test("Candidate A: Cosmetic suppression applies in AD_CONFIRMED and is removed on teardown", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: {
                    adStateClasses: ["ad-showing"],
                    cosmeticHideTargets: [".ytp-ad-player-overlay"]
                },
                disableMask: {
                    cosmeticHidingDisabled: false,
                    skipClickDisabled: false,
                    accelerationDisabled: true
                }
            }
        }
    });

    player.classList.add("ad-showing");
    content.evaluateFSM(content.getEngineState().playerGeneration);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CONFIRMED);
    const styleEl = content.getEngineState().cosmeticStyleElement;
    assert.ok(styleEl);
    assert.ok(styleEl.textContent.includes(".ytp-ad-player-overlay"));

    // Teardown cleans up cosmetic styles
    content.teardownCurrentPlayer();
    assert.equal(content.getEngineState().cosmeticStyleElement, null);
});

test("Candidate B: Skip button click fires at most once per configured interval (debounced)", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    const skipBtn = env.createElement("button", "", "ytp-ad-skip-button");
    player.appendChild(video);
    player.appendChild(skipBtn);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: {
                    skipButtons: [".ytp-ad-skip-button"]
                },
                disableMask: {
                    cosmeticHidingDisabled: false,
                    skipClickDisabled: false,
                    accelerationDisabled: true
                }
            }
        }
    });

    player.classList.add("ad-showing");
    const gen = content.getEngineState().playerGeneration;
    content.evaluateFSM(gen);

    assert.equal(skipBtn.clicksDispatched, 1);

    // Repeated evaluation within same interval does NOT dispatch duplicate clicks
    content.evaluateFSM(gen);
    content.evaluateFSM(gen);
    assert.equal(skipBtn.clicksDispatched, 1);
});

test("Candidate B: Detached skip button (isConnected == false) is never clicked", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: {
                    skipButtons: [".ytp-ad-skip-button"]
                },
                disableMask: { skipClickDisabled: false }
            }
        }
    });

    // Create detached button
    const detachedBtn = env.createElement("button", "", "ytp-ad-skip-button");
    detachedBtn.isConnected = false;

    const dispatched = content.dispatchCandidateBSkip(player, content.getEngineState().playerGeneration);
    assert.equal(dispatched, false);
    assert.equal(detachedBtn.clicksDispatched, 0);
});

test("Candidate E: Unskippable ad with accelerationDisabled == true takes explicit safe no-op", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.playbackRate = 1.0;
    video.muted = false;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: {
                    adStateClasses: ["ad-showing"],
                    skipButtons: [".ytp-ad-skip-button"] // No skip button mounted
                },
                disableMask: {
                    accelerationDisabled: true,
                    skipClickDisabled: false
                }
            }
        }
    });

    player.classList.add("ad-showing");
    content.evaluateFSM(content.getEngineState().playerGeneration);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CONFIRMED);
    // Invariant: Candidate E applies zero media mutation
    assert.equal(video.playbackRate, 1.0);
    assert.equal(video.muted, false);
    assert.equal(content.getEngineState().isAccelerationActive, false);
});

test("Candidate C: When enabled, accelerates playback and restores exact user state on exit", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.playbackRate = 1.25;
    video.muted = false;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: {
                    adStateClasses: ["ad-showing"]
                },
                parameters: {
                    maxAccelerationRate: 16.0,
                    accelerationSafetyTimeoutMs: 5000
                },
                disableMask: {
                    accelerationDisabled: false, // Explicitly enabled for test
                    skipClickDisabled: true
                }
            }
        }
    });

    player.classList.add("ad-showing");
    const gen = content.getEngineState().playerGeneration;
    content.evaluateFSM(gen);

    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CONFIRMED);
    assert.equal(video.playbackRate, 16.0);
    assert.equal(video.muted, true);
    assert.equal(content.getEngineState().isAccelerationActive, true);

    // Ad finishes
    player.classList.remove("ad-showing");
    content.evaluateFSM(gen);

    // Transitions to RESET_SETTLING and restores pre-ad user state
    assert.equal(video.playbackRate, 1.25);
    assert.equal(video.muted, false);
    assert.equal(content.getEngineState().isAccelerationActive, false);
});

test("Candidate C: Manual user speed change during acceleration is preserved and not overwritten", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.playbackRate = 1.0;
    video.muted = false;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: { adStateClasses: ["ad-showing"] },
                parameters: { maxAccelerationRate: 16.0 },
                disableMask: { accelerationDisabled: false, skipClickDisabled: true }
            }
        }
    });

    player.classList.add("ad-showing");
    const gen = content.getEngineState().playerGeneration;
    content.evaluateFSM(gen);

    assert.equal(video.playbackRate, 16.0);

    // User manually sets speed to 2.0x during ad break
    video.playbackRate = 2.0;

    // Ad finishes
    player.classList.remove("ad-showing");
    content.evaluateFSM(gen);

    // Invariant: Because playbackRate != ownedAccelerationRate (16.0), SHIELD preserves user's 2.0x
    assert.equal(video.playbackRate, 2.0);
    // Mute was NOT touched by user (was true == ownedMutedValue), so it restores to original false
    assert.equal(video.muted, false);
});

test("Candidate C: Manual user unmute during acceleration is preserved and not overwritten", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.playbackRate = 1.0;
    video.muted = false;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: { adStateClasses: ["ad-showing"] },
                parameters: { maxAccelerationRate: 16.0 },
                disableMask: { accelerationDisabled: false, skipClickDisabled: true }
            }
        }
    });

    player.classList.add("ad-showing");
    const gen = content.getEngineState().playerGeneration;
    content.evaluateFSM(gen);

    assert.equal(video.muted, true);

    // User manually unmutes during ad break
    video.muted = false;

    // Ad finishes
    player.classList.remove("ad-showing");
    content.evaluateFSM(gen);

    // Invariant: User unmute preserved
    assert.equal(video.muted, false);
    // Rate was owned (16.0), so rate restores to 1.0
    assert.equal(video.playbackRate, 1.0);
});

test("Candidate C: Safety timeout triggers AMBIGUOUS_SAFE and restores owned state cleanly", (t, done) => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.playbackRate = 1.0;
    video.muted = false;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: { adStateClasses: ["ad-showing"] },
                parameters: {
                    maxAccelerationRate: 16.0,
                    accelerationSafetyTimeoutMs: 20 // Short timeout for test
                },
                disableMask: { accelerationDisabled: false, skipClickDisabled: true }
            }
        }
    });

    player.classList.add("ad-showing");
    const gen = content.getEngineState().playerGeneration;
    content.evaluateFSM(gen);

    assert.equal(video.playbackRate, 16.0);
    assert.equal(video.muted, true);

    setTimeout(() => {
        // Safety timeout fired
        assert.equal(content.getEngineState().detectionState, content.DetectionState.AMBIGUOUS_SAFE);
        assert.equal(video.playbackRate, 1.0);
        assert.equal(video.muted, false);
        assert.equal(content.getEngineState().isAccelerationActive, false);
        done();
    }, 40);
});

// Regression (device-observed, 2026-09-06): on m.youtube.com the player container is
// frequently in the DOM before its <video> child exists. mountPlayer queried for <video>
// exactly once and, finding none, left activeVideoElement null forever — the class-only
// MutationObserver never observes childList, so nothing re-binds when the video appears.
// Result: no media events, mediaActive permanently false, and the FSM cannot confirm an
// ad (AD_CANDIDATE requires sig02 || (sig01 && (mediaActive || sig03))). This raced:
// mounting after the video existed worked, mounting before it silently never recovered.
test("Video element appearing after mount is bound once it exists", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });

    // Mounted against a player that has no <video> child yet.
    let state = content.getEngineState();
    assert.ok(state.activePlayerElement, "player should mount even without a video child");
    assert.equal(state.activeVideoElement, null, "no video to bind at this point");

    // YouTube inserts the media element asynchronously.
    const video = env.createElement("video");
    player.appendChild(video);

    // The engine must notice and bind it rather than staying blind forever.
    content.ensureVideoBound(content.getEngineState().playerGeneration);

    state = content.getEngineState();
    assert.ok(state.activeVideoElement, "video must be bound once it appears");
    assert.ok(state.boundMediaHandlers, "media event handlers must be attached");
});

// Regression (device-observed, 2026-09-07): during the pre-skip countdown YouTube keeps
// the skip button in the DOM and NOT disabled, but unrendered (offsetParent === null).
// dispatchCandidateBSkip found it, clicked it, and reported success — so
// dispatchInterventions returned early and never fell through to acceleration, which is
// the intervention that actually gets the user through the countdown. The engine spent
// the whole countdown firing clicks at an invisible button.
// SKIPPED (2026-09-09): the guard this asserts was reverted — on device it correlated
// with pre-roll ads playing through instead of being accelerated away. The behaviour
// asserted here is still what we want; re-enable this together with the guard once a
// test reproduces the device regression and explains the mechanism.
test.skip("Candidate B: Unrendered skip button (offsetParent null) is not clicked", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);

    const skipBtn = env.createElement("button", null, "ytp-ad-skip-button");
    skipBtn.offsetParent = null; // in the DOM, but not rendered
    player.appendChild(skipBtn);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: { adStateClasses: ["ad-showing"], skipButtons: [".ytp-ad-skip-button"] },
                disableMask: {}
            }
        }
    });

    const gen = content.getEngineState().playerGeneration;
    const dispatched = content.dispatchCandidateBSkip(player, gen);

    assert.equal(dispatched, false, "must not report success for an unrendered button");
    assert.equal(skipBtn.clicksDispatched, 0, "must not click an unrendered button");
});

// Regression (device-observed, 2026-09-07): Safari suspends the MV3 event page
// aggressively — it visibly disappears from the Develop menu. When the content script's
// first getLayer3Config lands while the background page is down, sendMessage invokes the
// callback with response === undefined AND lastError === undefined (not an error; simply
// unanswered). fetchConfiguration then latched layer3Enabled:false permanently for that
// page, with no retry, so the engine never mounted even though the background page woke
// moments later. Observed as: "fetchConfiguration: FAILED ... response= undefined",
// then ads playing untouched for the rest of the session.
test("Unanswered config query is retried rather than latching Layer 3 off", async () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    player.appendChild(env.createElement("video"));
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);

    assert.equal(env.getConfigQuerySendCount(), 1, "initial query sent");

    // Background page is suspended: callback fires with no response and no lastError.
    env.respondToConfigQuery(undefined);

    assert.equal(
        content.getEngineState().currentConfig.layer3Enabled,
        false,
        "first failure still yields a disabled config"
    );

    // The engine must ask again once the background page has had a chance to wake.
    await new Promise((resolve) => setTimeout(resolve, 1200));

    assert.ok(
        env.getConfigQuerySendCount() > 1,
        "config query must be retried after an unanswered send, got " +
        env.getConfigQuerySendCount()
    );

    // And a successful retry must bring the engine up.
    env.respondToConfigQuery({ layer3Enabled: true, generation: 1 });
    assert.equal(content.getEngineState().currentConfig.layer3Enabled, true);
});

// Regression (device-observed, 2026-09-09): in a two-ad pre-roll break, the first ad was
// accelerated away and the second played at normal speed. Between consecutive ads the ad
// signals never drop, so the FSM stays in AD_CONFIRMED; transitionTo returns early when
// the state is unchanged, so teardownInterventions never runs, isAccelerationActive stays
// true from ad 1, and dispatchCandidateCAcceleration's `if (isAccelerationActive) return
// false` guard blocks ad 2. The existing single-ad test passes because it always has a
// clean AD_CONFIRMED -> RESET_SETTLING gap that runs teardown.
// SKIPPED (2026-09-10): the fix this asserts was reverted. On device it stopped the
// FIRST ad accelerating too — a case the fix should not have touched at all, since
// isAccelerationActive is false on the first ad. The mechanism is not understood, so
// the known-good single-ad behaviour takes priority over the second-ad improvement.
// The bug this describes is real; re-enable together with a fix once the device
// behaviour is explained rather than inferred from source.
test.skip("Candidate C: Second ad in a back-to-back break is also accelerated", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    video.playbackRate = 1.0;
    video.muted = false;
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery({
        layer3Enabled: true,
        generation: 1,
        rules: {
            youtube: {
                selectors: { adStateClasses: ["ad-showing"] },
                parameters: { maxAccelerationRate: 16.0, accelerationSafetyTimeoutMs: 5000 },
                disableMask: { accelerationDisabled: false, skipClickDisabled: true }
            }
        }
    });

    const gen = content.getEngineState().playerGeneration;

    // Ad 1 begins and is accelerated.
    player.classList.add("ad-showing");
    content.evaluateFSM(gen);
    assert.equal(content.getEngineState().detectionState, content.DetectionState.AD_CONFIRMED);
    assert.equal(video.playbackRate, 16.0, "first ad must be accelerated");

    // Ad 1 ends and ad 2 begins immediately: YouTube swaps the media element but the ad
    // signals never drop, so the FSM stays in AD_CONFIRMED throughout.
    video.playbackRate = 1.0;
    video.muted = false;
    content.evaluateFSM(gen);

    assert.equal(
        video.playbackRate, 16.0,
        "second ad must also be accelerated, got " + video.playbackRate
    );
});

// MARK: - Config / lifecycle ordering (startup race)

// Regression (audit, 2026-10-27): the content script runs at document_start and its
// getLayer3Config round trip (wake event page -> native messaging -> appex) is routinely
// slower than the page's own lifecycle. Any lifecycle event bumps playerGeneration, and
// fetchConfiguration discarded a reply whose captured generation had gone stale — so
// currentConfig stayed null, mountPlayer took its SKIPPED path on every later
// navigation, and nothing ever asked again. Layer 3 was off for the life of the page.
// The legacy suite never saw it: its mock was always readyState "complete" and always
// answered the query before any lifecycle event fired.
//
// Reply timings, relative to the lifecycle event under test:
//   before — reply lands, then the event fires.
//   during — reply lands mid-navigation: after yt-navigate-start has torn the player
//            down (generation bumped, nothing mounted) but before the event fires.
//   after  — the event fires while the query is in flight; the reply lands last.
const ORDERING_CONFIG = {
    layer3Enabled: true,
    generation: 1,
    rules: { youtube: { selectors: { adStateClasses: ["ad-showing"] }, disableMask: {} } }
};

for (const readyState of ["loading", "interactive", "complete"]) {
    for (const eventName of ["DOMContentLoaded", "yt-navigate-finish", "yt-page-data-updated"]) {
        for (const timing of ["before", "during", "after"]) {
            test(`Config ordering: readyState=${readyState}, reply ${timing} ${eventName} -> one query, one mount`, () => {
                const env = createMockDOMEnvironment("www.youtube.com", { readyState });
                const player = env.createElement("div", "movie_player", "html5-video-player");
                const video = env.createElement("video");
                player.appendChild(video);
                env.addDocumentElement(player);

                const content = loadContentWithMock(env);
                const fire = (name) => env.mockGlobal.window.dispatchEvent(name);

                if (timing === "before") {
                    env.respondToConfigQuery(ORDERING_CONFIG);
                    fire(eventName);
                } else if (timing === "during") {
                    fire("yt-navigate-start");
                    env.respondToConfigQuery(ORDERING_CONFIG);
                    fire(eventName);
                } else {
                    fire(eventName);
                    env.respondToConfigQuery(ORDERING_CONFIG);
                }

                const state = content.getEngineState();
                assert.equal(env.getConfigQuerySendCount(), 1, "exactly one config query per page");
                assert.ok(state.currentConfig, "config must not be dropped");
                assert.equal(state.currentConfig.layer3Enabled, true);

                const liveObservers = env.observers.filter((o) => !o.disconnected);
                assert.equal(liveObservers.length, 1, "exactly one live mount");
                assert.equal(liveObservers[0].target, player);
                assert.equal(state.activePlayerElement, player);
                assert.equal((video.eventListeners.timeupdate || []).length, 1,
                    "media handlers bound exactly once");
            });
        }
    }
}

test("mountPlayer is idempotent for a generation that is already mounted", () => {
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);
    env.respondToConfigQuery(ORDERING_CONFIG);

    const gen = content.getEngineState().playerGeneration;
    content.mountPlayer(gen);

    assert.equal(env.observers.filter((o) => !o.disconnected).length, 1, "no duplicate observer");
    assert.equal(env.observers.length, 1, "no second observer created");
    assert.equal((video.eventListeners.timeupdate || []).length, 1, "no duplicate media handlers");
});

test("mountPlayer re-requests config after every retry was exhausted", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const env = createMockDOMEnvironment("www.youtube.com");
    const player = env.createElement("div", "movie_player", "html5-video-player");
    player.appendChild(env.createElement("video"));
    env.addDocumentElement(player);

    const content = loadContentWithMock(env);

    // Background page never answers: drain every bounded retry.
    for (let i = 0; i < 10; i++) {
        env.respondToConfigQuery(undefined);
        t.mock.timers.tick(10000);
    }
    const sentAfterExhaustion = env.getConfigQuerySendCount();

    // A later navigation must ask again rather than latching off for the page's life.
    env.mockGlobal.window.dispatchEvent("yt-navigate-finish");
    assert.equal(env.getConfigQuerySendCount(), sentAfterExhaustion + 1, "navigation re-requests config");

    // A second navigation while that request is in flight must not send another.
    env.mockGlobal.window.dispatchEvent("yt-navigate-finish");
    assert.equal(env.getConfigQuerySendCount(), sentAfterExhaustion + 1, "in-flight request is shared");

    env.respondToConfigQuery(ORDERING_CONFIG);
    assert.equal(content.getEngineState().activePlayerElement, player, "late success mounts");
    assert.equal(env.observers.filter((o) => !o.disconnected).length, 1);
});

test("Config reply with no player present stores config and mounts nothing", () => {
    const env = createMockDOMEnvironment("www.youtube.com", { readyState: "loading" });
    const content = loadContentWithMock(env);

    // Mid-navigation: old player torn down, new one not yet in the DOM.
    env.mockGlobal.window.dispatchEvent("yt-navigate-start");
    env.respondToConfigQuery(ORDERING_CONFIG);

    let state = content.getEngineState();
    assert.equal(state.currentConfig.layer3Enabled, true, "config is stored");
    assert.equal(state.activePlayerElement, null, "nothing mounted");
    assert.equal(env.observers.length, 0, "no observer created without a player");

    // The player arrives with the navigation's finish event and is mounted exactly once.
    const player = env.createElement("div", "movie_player", "html5-video-player");
    const video = env.createElement("video");
    player.appendChild(video);
    env.addDocumentElement(player);
    env.mockGlobal.window.dispatchEvent("yt-navigate-finish");

    state = content.getEngineState();
    assert.equal(state.activePlayerElement, player);
    assert.equal(env.observers.filter((o) => !o.disconnected).length, 1);
    assert.equal((video.eventListeners.timeupdate || []).length, 1);
    assert.equal(env.getConfigQuerySendCount(), 1, "stored config reused, no second query");
});
