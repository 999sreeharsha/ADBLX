// content.js - Safari Web Extension Content Script (ADBLX Layer 3 YouTube Engine)
// Conforms to ADR-0010, ADR-0013, Task 1 Playback Contract, Sprint 9 Phase 3 Lifecycle, Phase 4 FSM, and Phase 5 Tiered Interventions.

"use strict";

(function () {
    // DIAGNOSTIC LOGGING. Console output from a content script is readable by anyone with
    // Web Inspector attached, so docs/Architecture/Logging.md applies here in full.
    //
    // diag()  — lifecycle lines. Counts, durations, booleans and fixed state names only:
    //           never a hostname, URL, error text, or anything read from the page.
    // DIAG_VERBOSE — extra dumps (FSM trace, signal booleans, media state, page class
    //           names and element ids) used to debug detection on a device. They can
    //           echo page markup, so they ship OFF; a test fails if this is not false.
    const DIAG = true;
    const DIAG_VERBOSE = false;
    function diag(...args) {
        if (DIAG && typeof console !== "undefined") {
            console.log("[ADBLX-L3]", ...args);
        }
    }

    // First statement to execute. If this line never appears in the console, the content
    // script was never injected at all (manifest/permission problem, not a code problem).
    diag("SCRIPT LOADED at", (typeof document !== "undefined" && document.readyState) || "?",
        "browserAPI:", typeof browser);

    // Surface an exception thrown by this content script, located by line and column only:
    // the message and stack can quote page text or URLs.
    if (DIAG_VERBOSE && typeof window !== "undefined" && window.addEventListener) {
        window.addEventListener("error", (e) => {
            const f = (e && e.filename) || "";
            if (f.indexOf("content.js") !== -1) {
                diag("UNCAUGHT in content.js @", e.lineno + ":" + e.colno);
            }
        });
    }

    // Config fetch retry bounds. Safari's MV3 event page is suspended aggressively, so the
    // first query from a freshly injected content script frequently goes unanswered; these
    // give it time to wake without retrying unboundedly if it never does.
    const CONFIG_FETCH_MAX_ATTEMPTS = 4;
    const CONFIG_FETCH_BASE_RETRY_MS = 500;

    // Placeholder config recorded locally when the background page did not answer. It is
    // not an authoritative answer (unlike "free_tier"), so mountPlayer asks again.
    const BACKGROUND_UNAVAILABLE_REASON = "background_unavailable";

    // 1. Binary Hostname Allowlist (Immutable compiled boundary)
    const ALLOWED_HOSTS = new Set(["m.youtube.com", "www.youtube.com"]);

    function isAuthorizedOrigin() {
        const hostname = typeof window !== "undefined" && window.location ? window.location.hostname : "";
        return ALLOWED_HOSTS.has(hostname);
    }

    // Default candidate selectors for player discovery (fallback if config delayed)
    const DEFAULT_PLAYER_SELECTORS = [
        "#movie_player",
        ".html5-video-player",
        "ytm-mobile-player",
        "#player-control-container",
        ".player-container",
        "#player"
    ];

    // Detection Finite State Machine States (Task 3 Specification)
    const DetectionState = Object.freeze({
        UNKNOWN: "UNKNOWN",
        NORMAL_PLAYBACK: "NORMAL_PLAYBACK",
        AD_CANDIDATE: "AD_CANDIDATE",
        AD_CONFIRMED: "AD_CONFIRMED",
        RESET_SETTLING: "RESET_SETTLING",
        AMBIGUOUS_SAFE: "AMBIGUOUS_SAFE"
    });

    // Diagnostic state (temporary, paired with the DIAG instrumentation above).
    let diagTimeupdateCount = 0;
    let diagLastPlayerClasses = "";

    // Engine Lifecycle State
    let playerGeneration = 0;
    let currentConfig = null;
    let isInitialized = false;

    // Config is page-scoped, not generation-scoped: one in-flight request shared by every
    // caller, cleared only when all attempts fail so a later mount can try again.
    let configRequest = null;
    let configRequestStartedAt = 0;

    function nowMs() {
        return (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
    }

    // Generation that currently has observers and media handlers attached. Guards against
    // a navigation and a late config reply both mounting the same generation.
    let mountedGeneration = -1;

    // Active Detection FSM State (Generation-Scoped)
    let detectionState = DetectionState.UNKNOWN;

    // Active Generation Player & Observer References
    let activePlayerElement = null;
    let activeVideoElement = null;
    let activeClassObserver = null;
    let pendingRAFId = null;

    // Bound Media Event Handlers
    let boundMediaHandlers = null;

    // ==========================================
    // Phase 5: Intervention Dispatcher State
    // ==========================================
    let hasDispatchedSkipClick = false;
    let lastSkipDispatchGeneration = -1;
    let lastSkipDispatchTimestamp = 0;

    let isAccelerationActive = false;
    let ownedAccelerationRate = null;
    let ownedMutedValue = null;
    let preInterventionPlaybackRate = 1.0;
    let preInterventionMuted = false;
    let accelerationSafetyTimer = null;

    let cosmeticStyleElement = null;

    /**
     * Resolves the active player container DOM element.
     */
    function resolvePlayerElement() {
        if (typeof document === "undefined") return null;

        const candidateSelectors = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.selectors &&
            Array.isArray(currentConfig.rules.youtube.selectors.playerContainers))
            ? currentConfig.rules.youtube.selectors.playerContainers
            : DEFAULT_PLAYER_SELECTORS;

        for (const selector of candidateSelectors) {
            try {
                const el = document.querySelector(selector);
                if (el) return el;
            } catch (e) {
                // Invalid selector syntax in remote data ignored safely
            }
        }
        return null;
    }

    /**
     * Predicate: Evaluates whether media is currently actively rendering/playing.
     */
    function isMediaActive(video) {
        if (!video) return false;
        return !video.paused && !video.ended && video.readyState >= 2; // HTMLMediaElement.HAVE_CURRENT_DATA = 2
    }

    /**
     * Signal SIG-01: Checks for ad state indicator classes on the player container.
     */
    function hasSIG01AdClass(player) {
        if (!player) return false;
        const adClasses = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.selectors &&
            Array.isArray(currentConfig.rules.youtube.selectors.adStateClasses))
            ? currentConfig.rules.youtube.selectors.adStateClasses
            : ["ad-showing", "ad-interrupting"];

        for (const cls of adClasses) {
            if (player.classList && player.classList.contains(cls)) return true;
            if (player.querySelector && player.querySelector("." + cls)) return true;
        }
        return false;
    }

    /**
     * Signal SIG-02: Checks for validated skip controls inside the player container.
     */
    function hasSIG02SkipControl(player) {
        if (!player) return false;
        const skipSelectors = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.selectors &&
            Array.isArray(currentConfig.rules.youtube.selectors.skipButtons))
            ? currentConfig.rules.youtube.selectors.skipButtons
            : [
                ".ytp-ad-skip-button",
                ".ytm-skip-ad-button",
                ".ytp-skip-ad-button",
                "button.ytp-ad-skip-button-modern",
                ".ytp-ad-skip-button-slot button",
                "button[class*='skip-button']"
            ];

        for (const selector of skipSelectors) {
            try {
                const btn = player.querySelector(selector);
                if (btn) return true;
            } catch (e) {}
        }
        if (typeof document !== "undefined") {
            for (const selector of skipSelectors) {
                try {
                    const btn = document.querySelector(selector);
                    if (btn) return true;
                } catch (e) {}
            }
        }
        return false;
    }

    /**
     * Signal SIG-03: Checks for corroborating ad badges / sponsored labels.
     * Corroborating ONLY — never independently authorizes ad state.
     */
    function hasSIG03AdBadge(player) {
        if (!player) return false;
        const badgeSelectors = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.selectors &&
            Array.isArray(currentConfig.rules.youtube.selectors.adBadges))
            ? currentConfig.rules.youtube.selectors.adBadges
            : [".ytp-ad-text", ".ytm-ad-badge"];

        for (const selector of badgeSelectors) {
            try {
                const badge = player.querySelector(selector);
                if (badge) return true;
            } catch (e) {}
        }
        if (typeof document !== "undefined") {
            for (const selector of badgeSelectors) {
                try {
                    const badge = document.querySelector(selector);
                    if (badge) return true;
                } catch (e) {}
            }
        }
        return false;
    }

    // ==========================================
    // Phase 5: Tiered Intervention Dispatcher
    // ==========================================

    /**
     * Candidate A: Injects scoped cosmetic CSS hiding ad overlays and banners.
     */
    function applyCosmeticSuppression() {
        if (typeof document === "undefined" || !document.head) return;

        const hideSelectors = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.selectors &&
            Array.isArray(currentConfig.rules.youtube.selectors.cosmeticHideTargets))
            ? currentConfig.rules.youtube.selectors.cosmeticHideTargets
            : [".ytp-ad-player-overlay", ".ytp-ad-overlay-container", "ytm-promoted-sparkles-web-renderer"];

        if (!hideSelectors || hideSelectors.length === 0) return;

        if (!cosmeticStyleElement) {
            cosmeticStyleElement = document.createElement("style");
            cosmeticStyleElement.id = "adblx-cosmetic-styles";
            document.head.appendChild(cosmeticStyleElement);
        }

        const cssRules = hideSelectors.join(", ") + " { display: none !important; opacity: 0 !important; pointer-events: none !important; }";
        if (cosmeticStyleElement.textContent !== cssRules) {
            cosmeticStyleElement.textContent = cssRules;
        }
    }

    /**
     * Removes injected cosmetic styles.
     */
    function removeCosmeticSuppression() {
        if (cosmeticStyleElement && cosmeticStyleElement.parentNode) {
            cosmeticStyleElement.parentNode.removeChild(cosmeticStyleElement);
            cosmeticStyleElement = null;
        }
    }

    /**
     * Candidate B: Programmatic Skip-Control Activation with debouncing.
     */
    function dispatchCandidateBSkip(player, gen) {
        if (!player) return false;

        const skipSelectors = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.selectors &&
            Array.isArray(currentConfig.rules.youtube.selectors.skipButtons))
            ? currentConfig.rules.youtube.selectors.skipButtons
            : [".ytp-ad-skip-button", ".ytm-skip-ad-button"];

        let targetBtn = null;
        for (const selector of skipSelectors) {
            try {
                const btn = player.querySelector(selector);
                if (btn) {
                    targetBtn = btn;
                    break;
                }
            } catch (e) {}
        }

        // Must be currently connected in DOM
        if (!targetBtn || targetBtn.isConnected === false) {
            return false;
        }

        // NOTE (2026-09-09): a guard rejecting unrendered buttons (offsetParent === null)
        // and explicitly disabled buttons was added here and then reverted. On device it
        // correlated with pre-roll ads playing through instead of being accelerated away,
        // even though reading the intervention ladder suggests returning false here should
        // simply fall through to Candidate C. The mechanism was never established, so the
        // guard is out until it can be reintroduced behind a test that reproduces the
        // regression. See the accompanying test, which is skipped for the same reason.

        // Single-click debouncing per ad interval
        const now = Date.now();
        if (hasDispatchedSkipClick && lastSkipDispatchGeneration === gen && (now - lastSkipDispatchTimestamp) < 1000) {
            return false;
        }

        hasDispatchedSkipClick = true;
        lastSkipDispatchGeneration = gen;
        lastSkipDispatchTimestamp = now;

        try {
            if (typeof targetBtn.click === "function") {
                targetBtn.click();
            }
            if (typeof targetBtn.dispatchEvent === "function" && typeof MouseEvent === "function") {
                targetBtn.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
            }
            return true;
        } catch (e) {
            return false;
        }
    }

    /**
     * Candidate C: Playback-Rate Acceleration (Compiled, Remotely Disabled in v1.0).
     */
    function dispatchCandidateCAcceleration(video, gen) {
        if (!video || isAccelerationActive) return false;

        const maxRate = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.parameters &&
            typeof currentConfig.rules.youtube.parameters.maxAccelerationRate === "number")
            ? currentConfig.rules.youtube.parameters.maxAccelerationRate
            : 16.0;

        // Snapshot pre-intervention user state
        preInterventionPlaybackRate = (typeof video.playbackRate === "number") ? video.playbackRate : 1.0;
        preInterventionMuted = (typeof video.muted === "boolean") ? video.muted : false;

        ownedAccelerationRate = maxRate;
        ownedMutedValue = true;
        isAccelerationActive = true;

        // Apply acceleration & mute
        video.muted = true;
        video.playbackRate = maxRate;

        // Arm mandatory safety timeout
        const timeoutMs = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.parameters &&
            typeof currentConfig.rules.youtube.parameters.accelerationSafetyTimeoutMs === "number")
            ? currentConfig.rules.youtube.parameters.accelerationSafetyTimeoutMs
            : 5000;

        if (accelerationSafetyTimer !== null) {
            clearTimeout(accelerationSafetyTimer);
        }

        accelerationSafetyTimer = setTimeout(() => {
            if (gen !== playerGeneration) return;
            teardownInterventions(gen);
            transitionTo(DetectionState.AMBIGUOUS_SAFE, gen);
        }, timeoutMs);

        return true;
    }

    /**
     * Idempotent Teardown and Ownership-Based Restoration of Interventions.
     */
    function teardownInterventions(gen) {
        if (isAccelerationActive && activeVideoElement) {
            const video = activeVideoElement;

            // Restore playbackRate ONLY if currently equal to our owned accelerated rate
            if (video.playbackRate === ownedAccelerationRate) {
                video.playbackRate = preInterventionPlaybackRate;
            }

            // Restore muted ONLY if currently equal to our owned muted value
            if (video.muted === ownedMutedValue) {
                video.muted = preInterventionMuted;
            }

            isAccelerationActive = false;
            ownedAccelerationRate = null;
            ownedMutedValue = null;
        }

        if (accelerationSafetyTimer !== null) {
            clearTimeout(accelerationSafetyTimer);
            accelerationSafetyTimer = null;
        }

        if (detectionState !== DetectionState.AD_CONFIRMED) {
            hasDispatchedSkipClick = false;
        }
    }

    /**
     * Dispatches tiered intervention policy when in AD_CONFIRMED state.
     */
    function dispatchInterventions(gen) {
        if (gen !== playerGeneration) return;

        if (detectionState !== DetectionState.AD_CONFIRMED) {
            teardownInterventions(gen);
            return;
        }

        const player = activePlayerElement;
        const video = activeVideoElement;
        if (!player) return;

        const disableMask = (currentConfig && currentConfig.rules &&
            currentConfig.rules.youtube && currentConfig.rules.youtube.disableMask) || {};

        if (DIAG_VERBOSE) diag("dispatchInterventions: AD_CONFIRMED — disableMask=", JSON.stringify(disableMask));

        // 1. Candidate A: Cosmetic Suppression
        if (!disableMask.cosmeticHidingDisabled) {
            applyCosmeticSuppression();
        }

        // 2. Candidate B: Synthetic Skip Activation
        let skipDispatched = false;
        if (!disableMask.skipClickDisabled) {
            skipDispatched = dispatchCandidateBSkip(player, gen);
        }
        if (DIAG_VERBOSE) diag("dispatchInterventions: skipDispatched=", skipDispatched);

        if (skipDispatched) {
            return;
        }

        // 3. Candidate C: Playback Acceleration (Compiled, Remotely Disabled by Default)
        let accelDispatched = false;
        if (!disableMask.accelerationDisabled) {
            accelDispatched = dispatchCandidateCAcceleration(video, gen);
        }
        if (DIAG_VERBOSE) {
            diag("ACCEL:", "dispatched=", accelDispatched,
                "| maskDisabled=", !!disableMask.accelerationDisabled,
                "| alreadyActive=", isAccelerationActive,
                "| haveVideo=", !!video,
                "| rate=", video && video.playbackRate,
                "| muted=", video && video.muted);
        }

        if (accelDispatched) {
            return;
        }

        // 4. Candidate E: Deliberate Non-Intervention (Terminal Safe No-Op)
        // Zero DOM mutation, zero media mutation. Native playback continues safely.
    }

    /**
     * Generation-guarded state transition function.
     */
    function transitionTo(nextState, gen) {
        if (gen !== playerGeneration) return;
        if (detectionState === nextState) return;

        if (DIAG_VERBOSE) diag("transitionTo:", detectionState, "->", nextState, "(gen", gen, ")");
        detectionState = nextState;

        if (nextState === DetectionState.AD_CONFIRMED) {
            dispatchInterventions(gen);
        } else {
            teardownInterventions(gen);
        }

        if (nextState === DetectionState.RESET_SETTLING) {
            scheduleResetSettlement(gen);
        }
    }

    /**
     * Schedules a single bounded next-frame settlement for RESET_SETTLING.
     */
    function scheduleResetSettlement(gen) {
        scheduleFrame(gen, (settleGen) => {
            if (settleGen !== playerGeneration) return;
            if (detectionState !== DetectionState.RESET_SETTLING) return;

            try {
                const player = activePlayerElement;
                const sig01 = hasSIG01AdClass(player);
                const sig02 = hasSIG02SkipControl(player);

                if (!sig01 && !sig02) {
                    transitionTo(DetectionState.NORMAL_PLAYBACK, settleGen);
                } else {
                    // Ad signals reappeared during settlement
                    transitionTo(DetectionState.AD_CANDIDATE, settleGen);
                    evaluateFSM(settleGen);
                }
            } catch (e) {
                transitionTo(DetectionState.AMBIGUOUS_SAFE, settleGen);
            }
        });
    }

    /**
     * Evaluates the Detection FSM state based on Task 3 deterministic transition rules.
     */
    function evaluateFSM(gen) {
        if (gen !== playerGeneration) return;

        if (!activePlayerElement) {
            transitionTo(DetectionState.UNKNOWN, gen);
            return;
        }

        try {
            const player = activePlayerElement;
            const video = activeVideoElement;
            const sig01 = hasSIG01AdClass(player);
            const sig02 = hasSIG02SkipControl(player);
            const sig03 = hasSIG03AdBadge(player);
            const mediaActive = isMediaActive(video);

            if (DIAG_VERBOSE) {
                // Log the player's class list only when it CHANGES. A static dump cannot
                // distinguish "class marks an ad is playing now" from "class is always
                // present" — and treating an always-present class as an ad signal would
                // false-positive on normal playback, which is the one outcome the Cardinal
                // Rule forbids. The delta shows exactly which classes toggle at ad onset.
                const classesNow = player.className || "";
                if (diagLastPlayerClasses === "") {
                    // Baseline: always print once so the absence of later deltas is meaningful
                    // (it proves the classes are static) rather than ambiguous with "this build
                    // was never installed".
                    diag("CLASS BASELINE @t=", video ? Math.round(video.currentTime) : "?",
                        "|", classesNow.slice(0, 400));
                }
                if (classesNow !== diagLastPlayerClasses) {
                    const before = new Set(diagLastPlayerClasses.split(/\s+/).filter(Boolean));
                    const after = new Set(classesNow.split(/\s+/).filter(Boolean));
                    const added = [...after].filter((c) => !before.has(c));
                    const removed = [...before].filter((c) => !after.has(c));
                    diag("CLASS DELTA @t=", video ? Math.round(video.currentTime) : "?",
                        "| ADDED:", added.join(",") || "(none)",
                        "| REMOVED:", removed.join(",") || "(none)");
                    diagLastPlayerClasses = classesNow;

                    // At each class change, report which ad-ish elements actually exist in the
                    // DOM. SIG-02/SIG-03 may be missing because their selectors are stale
                    // rather than because no ad is present; this shows the real markup.
                    if (typeof document !== "undefined") {
                        const probes = [
                            "[class*='skip']", "[class*='ad-badge']", "[class*='ad-text']",
                            "[class*='ytp-ad']", "[class*='ytm-ad']", "[id*='ad']"
                        ];
                        const found = probes
                            .map((sel) => {
                                try {
                                    const els = document.querySelectorAll(sel);
                                    if (!els.length) return null;
                                    const names = [...els].slice(0, 3)
                                        .map((e) => (e.className || e.id || "?").toString().slice(0, 60));
                                    return sel + "=" + els.length + "[" + names.join(" | ") + "]";
                                } catch (e) { return null; }
                            })
                            .filter(Boolean);
                        diag("AD DOM PROBE:", found.length ? found.join("  ;  ") : "(nothing matched)");
                    }
                }

                // mediaActive is a conjunction of three conditions; when timeupdate is firing
                // but mediaActive reads false, exactly one of them is wrong. Log them apart,
                // plus whether the bound element is still the page's live <video>.
                if ((diagTimeupdateCount % 20) === 1) {
                    const live = (typeof document !== "undefined") ? document.querySelector("video") : null;
                    diag("MEDIA STATE: bound?", !!video,
                        "paused=", video && video.paused,
                        "ended=", video && video.ended,
                        "readyState=", video && video.readyState,
                        "currentTime=", video && Math.round(video.currentTime),
                        "| boundIsLive=", !!video && video === live,
                        "| videosOnPage=", (typeof document !== "undefined") ? document.querySelectorAll("video").length : -1);
                }

                diag("evaluateFSM: state=", detectionState,
                    "sig01(adClass)=", sig01, "sig02(skipBtn)=", sig02,
                    "sig03(adBadge)=", sig03, "mediaActive=", mediaActive);
            }

            switch (detectionState) {
            case DetectionState.UNKNOWN:
                if (!sig01 && !sig02) {
                    transitionTo(DetectionState.NORMAL_PLAYBACK, gen);
                } else {
                    transitionTo(DetectionState.AD_CANDIDATE, gen);
                    evaluateFSM(gen);
                }
                break;

            case DetectionState.NORMAL_PLAYBACK:
                if (sig01 || sig02) {
                    transitionTo(DetectionState.AD_CANDIDATE, gen);
                    evaluateFSM(gen);
                }
                break;

            case DetectionState.AD_CANDIDATE:
                if (sig02 || (sig01 && (mediaActive || sig03))) {
                    transitionTo(DetectionState.AD_CONFIRMED, gen);
                } else if (!sig01 && !sig02) {
                    transitionTo(DetectionState.NORMAL_PLAYBACK, gen);
                }
                break;

            case DetectionState.AD_CONFIRMED:
                if (!sig01 && !sig02) {
                    transitionTo(DetectionState.RESET_SETTLING, gen);
                } else {
                    // Re-dispatch interventions if elements changed while remaining confirmed
                    dispatchInterventions(gen);
                }
                break;

            case DetectionState.RESET_SETTLING:
                break;

            case DetectionState.AMBIGUOUS_SAFE:
                if (!sig01 && !sig02) {
                    transitionTo(DetectionState.NORMAL_PLAYBACK, gen);
                }
                break;
            }
        } catch (err) {
            transitionTo(DetectionState.AMBIGUOUS_SAFE, gen);
        }
    }

    /**
     * Synchronously tears down the active player generation.
     */
    function teardownCurrentPlayer() {
        playerGeneration++;

        // Reset interventions & FSM
        teardownInterventions(playerGeneration);
        removeCosmeticSuppression();
        detectionState = DetectionState.UNKNOWN;

        if (pendingRAFId !== null && typeof cancelAnimationFrame === "function") {
            cancelAnimationFrame(pendingRAFId);
            pendingRAFId = null;
        }

        if (activeClassObserver) {
            activeClassObserver.disconnect();
            activeClassObserver = null;
        }

        if (activeVideoElement && boundMediaHandlers) {
            for (const [eventName, handler] of Object.entries(boundMediaHandlers)) {
                activeVideoElement.removeEventListener(eventName, handler);
            }
            boundMediaHandlers = null;
        }

        activePlayerElement = null;
        activeVideoElement = null;
    }

    /**
     * Mounts observation and media tracking for a specific player generation.
     */
    function mountPlayer(gen) {
        if (gen !== playerGeneration) return;
        if (mountedGeneration === gen) return;
        if (!currentConfig || currentConfig.reason === BACKGROUND_UNAVAILABLE_REASON) {
            // No authoritative config yet. The reply handler mounts whatever generation is
            // current when it lands, so this only has to make sure a request exists.
            diag("mountPlayer: awaiting config (gen", gen, ")");
            ensureConfiguration();
            return;
        }
        if (!currentConfig.layer3Enabled) {
            diag("mountPlayer: SKIPPED — layer3Enabled=", currentConfig.layer3Enabled);
            return;
        }

        const player = resolvePlayerElement();
        if (!player) {
            diag("mountPlayer: no player element resolved yet (gen", gen, ")");
            return;
        }

        diag("mountPlayer: player resolved, engine mounting (gen", gen, ")");
        mountedGeneration = gen;
        activePlayerElement = player;

        ensureVideoBound(gen);

        if (typeof MutationObserver !== "undefined") {
            activeClassObserver = new MutationObserver((mutations) => {
                if (gen !== playerGeneration) return;
                // The <video> child is frequently inserted after the player container
                // exists, so every mutation is also a chance to bind it if we haven't.
                ensureVideoBound(gen);
                onPlayerClassMutation(mutations, gen);
            });

            activeClassObserver.observe(player, {
                attributes: true,
                attributeFilter: ["class"],
                childList: true,
                subtree: true
            });
        }

        evaluateFSM(gen);
    }

    /**
     * Binds media events to the player's `<video>` element, if one exists and we have not
     * already bound it. Idempotent and safe to call repeatedly.
     *
     * YouTube inserts the media element asynchronously — often after the player container
     * is already in the DOM — and swaps it between ad and content playback. Resolving it
     * only once at mount left the engine permanently blind whenever it lost that race.
     */
    function ensureVideoBound(gen) {
        if (gen !== playerGeneration) return;
        if (!activePlayerElement) return;

        const video = activePlayerElement.querySelector("video");
        if (!video || video === activeVideoElement) return;

        // Release handlers bound to a previous (swapped-out) element before rebinding.
        if (activeVideoElement && boundMediaHandlers) {
            for (const [eventName, handler] of Object.entries(boundMediaHandlers)) {
                activeVideoElement.removeEventListener(eventName, handler);
            }
            boundMediaHandlers = null;
        }

        if (DIAG_VERBOSE) diag("ensureVideoBound: binding video element (gen", gen, ")");
        activeVideoElement = video;
        bindMediaEvents(video, gen);
    }

    /**
     * Binds standard W3C HTMLMediaElement listeners for state evaluation.
     */
    function bindMediaEvents(video, gen) {
        boundMediaHandlers = {
            play: () => onMediaEvent("play", gen),
            playing: () => onMediaEvent("playing", gen),
            ended: () => onMediaEvent("ended", gen),
            timeupdate: () => onMediaEvent("timeupdate", gen),
            pause: () => onMediaEvent("pause", gen)
        };

        for (const [eventName, handler] of Object.entries(boundMediaHandlers)) {
            video.addEventListener(eventName, handler);
        }
    }

    /**
     * Handles scoped class mutation on the player container.
     */
    function onPlayerClassMutation(mutations, gen) {
        if (gen !== playerGeneration) return;
        evaluateFSM(gen);
    }

    /**
     * Handles media playback state events.
     */
    function onMediaEvent(eventName, gen) {
        if (gen !== playerGeneration) return;
        // timeupdate fires ~4x/sec; log it sparsely so the console stays readable while
        // still proving media events are reaching the engine at all.
        if (DIAG_VERBOSE) {
            if (eventName !== "timeupdate") {
                diag("mediaEvent:", eventName, "(gen", gen, ")");
            } else if ((diagTimeupdateCount++ % 20) === 0) {
                diag("mediaEvent: timeupdate #", diagTimeupdateCount, "(gen", gen, ")");
            }
        }
        evaluateFSM(gen);
    }

    /**
     * Schedules bounded next-frame settlement with generation check.
     */
    function scheduleFrame(gen, callback) {
        if (typeof requestAnimationFrame !== "function") {
            if (gen === playerGeneration) callback(gen);
            return;
        }

        if (pendingRAFId !== null) {
            cancelAnimationFrame(pendingRAFId);
        }

        pendingRAFId = requestAnimationFrame(() => {
            pendingRAFId = null;
            if (gen !== playerGeneration) return;
            callback(gen);
        });
    }

    /**
     * Handles SPA navigation and lifecycle events.
     */
    function onLifecycleEvent(eventName) {
        if (eventName === "yt-navigate-start") {
            teardownCurrentPlayer();
        } else if (eventName === "yt-navigate-finish" || eventName === "yt-page-data-updated" || eventName === "DOMContentLoaded") {
            teardownCurrentPlayer();
            mountPlayer(playerGeneration);
        } else if (eventName === "popstate") {
            teardownCurrentPlayer();
            mountPlayer(playerGeneration);
        }
    }

    /**
     * Returns the single in-flight Layer 3 configuration request, starting one if needed.
     * Resolves with the resulting config; on success the current generation is mounted.
     */
    function ensureConfiguration() {
        if (!configRequest) {
            configRequestStartedAt = nowMs();
            configRequest = new Promise((resolve) => fetchConfiguration(resolve, 0));
        }
        return configRequest;
    }

    /**
     * Fetches Layer 3 configuration from background.js, retrying unanswered sends.
     *
     * The reply is never discarded for being "stale": page lifecycle events routinely bump
     * playerGeneration before the native-messaging round trip completes, and dropping the
     * reply then left Layer 3 off for the life of the page.
     */
    function fetchConfiguration(onComplete, attempt) {
        if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendMessage) {
            onComplete(null);
            return;
        }

        const tryIndex = attempt || 0;

        diag("fetchConfiguration: sending getLayer3Config (attempt", tryIndex + 1, ")");
        browser.runtime.sendMessage({ type: "getLayer3Config" }, (response) => {
            if (browser.runtime.lastError || !response) {
                currentConfig = { layer3Enabled: false, reason: BACKGROUND_UNAVAILABLE_REASON };
                // Whether each was present, never the lastError text: it can quote URLs.
                diag("fetchConfiguration: FAILED lastError=", !!browser.runtime.lastError, "response=", !!response);

                // Safari suspends the MV3 event page aggressively. An unanswered send
                // (no response AND no lastError) means the background page was down, not
                // that the user lacks entitlement — sending again wakes it. Without this
                // the engine latched off for the life of the page and ads played
                // untouched. Bounded with backoff so a genuinely absent background page
                // does not cause an unbounded retry loop.
                if (tryIndex < CONFIG_FETCH_MAX_ATTEMPTS - 1) {
                    const delayMs = CONFIG_FETCH_BASE_RETRY_MS * Math.pow(2, tryIndex);
                    setTimeout(() => fetchConfiguration(onComplete, tryIndex + 1), delayMs);
                    return; // onComplete runs when an attempt actually resolves
                }
                // Every attempt failed: release the request so the next mount retries.
                configRequest = null;
            } else {
                currentConfig = response;
                diag("fetchConfiguration: got config layer3Enabled=", response.layer3Enabled,
                    "reason=", response.reason,
                    "hasRules=", !!(response.rules && response.rules.youtube),
                    "in", Math.round(nowMs() - configRequestStartedAt) + "ms");
                // Mount synchronously, for whatever generation is current by now.
                mountPlayer(playerGeneration);
            }

            onComplete(currentConfig);
        });
    }

    /**
     * Initializes content script on page load.
     */
    function initialize() {
        if (!isAuthorizedOrigin()) {
            diag("initialize: host not authorized");
            return false;
        }
        if (isInitialized) return true;
        isInitialized = true;
        diag("initialize: authorized host, starting engine");

        if (typeof window !== "undefined") {
            window.addEventListener("yt-navigate-start", () => onLifecycleEvent("yt-navigate-start"));
            window.addEventListener("yt-navigate-finish", () => onLifecycleEvent("yt-navigate-finish"));
            window.addEventListener("yt-page-data-updated", () => onLifecycleEvent("yt-page-data-updated"));
            window.addEventListener("popstate", () => onLifecycleEvent("popstate"));
        }

        if (typeof document !== "undefined") {
            if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", () => onLifecycleEvent("DOMContentLoaded"));
            }
        }

        // No config yet, so this starts the shared request; its reply does the mount.
        mountPlayer(playerGeneration);
        return true;
    }

    if (typeof window !== "undefined") {
        try {
            initialize();
        } catch (err) {
            diag("initialize() THREW:", err && err.name);
        }
    }

    // Export internal engine for unit testing in Node environment
    if (typeof module !== "undefined" && module.exports) {
        module.exports = {
            ALLOWED_HOSTS,
            DetectionState,
            getEngineState: () => ({
                playerGeneration,
                detectionState,
                currentConfig,
                isInitialized,
                activePlayerElement,
                activeVideoElement,
                activeClassObserver,
                pendingRAFId,
                boundMediaHandlers,
                hasDispatchedSkipClick,
                isAccelerationActive,
                ownedAccelerationRate,
                ownedMutedValue,
                preInterventionPlaybackRate,
                preInterventionMuted,
                cosmeticStyleElement
            }),
            setEngineState: (state) => {
                if (state.playerGeneration !== undefined) playerGeneration = state.playerGeneration;
                if (state.detectionState !== undefined) detectionState = state.detectionState;
                if (state.currentConfig !== undefined) currentConfig = state.currentConfig;
                if (state.isInitialized !== undefined) isInitialized = state.isInitialized;
            },
            initialize,
            teardownCurrentPlayer,
            mountPlayer,
            ensureVideoBound,
            resolvePlayerElement,
            evaluateFSM,
            transitionTo,
            isMediaActive,
            hasSIG01AdClass,
            hasSIG02SkipControl,
            hasSIG03AdBadge,
            applyCosmeticSuppression,
            removeCosmeticSuppression,
            dispatchCandidateBSkip,
            dispatchCandidateCAcceleration,
            teardownInterventions,
            dispatchInterventions,
            onLifecycleEvent,
            scheduleFrame,
            ensureConfiguration
        };
    }
})();
