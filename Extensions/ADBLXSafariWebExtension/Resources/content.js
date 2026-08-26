// content.js - Safari Web Extension Content Script (ADBLX Layer 3 YouTube Engine)
// Conforms to ADR-0010, ADR-0013, Task 1 Playback Contract, Sprint 9 Phase 3 Lifecycle, Phase 4 FSM, and Phase 5 Tiered Interventions.

"use strict";

(function () {
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

    // Engine Lifecycle State
    let playerGeneration = 0;
    let currentConfig = null;
    let isInitialized = false;

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

        // 1. Candidate A: Cosmetic Suppression
        if (!disableMask.cosmeticHidingDisabled) {
            applyCosmeticSuppression();
        }

        // 2. Candidate B: Synthetic Skip Activation
        let skipDispatched = false;
        if (!disableMask.skipClickDisabled) {
            skipDispatched = dispatchCandidateBSkip(player, gen);
        }

        if (skipDispatched) {
            return;
        }

        // 3. Candidate C: Playback Acceleration (Compiled, Remotely Disabled by Default)
        let accelDispatched = false;
        if (!disableMask.accelerationDisabled) {
            accelDispatched = dispatchCandidateCAcceleration(video, gen);
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
        if (!currentConfig || !currentConfig.layer3Enabled) return;

        const player = resolvePlayerElement();
        if (!player) return;

        activePlayerElement = player;

        const video = player.querySelector("video");
        if (video) {
            activeVideoElement = video;
            bindMediaEvents(video, gen);
        }

        if (typeof MutationObserver !== "undefined") {
            activeClassObserver = new MutationObserver((mutations) => {
                if (gen !== playerGeneration) return;
                onPlayerClassMutation(mutations, gen);
            });

            activeClassObserver.observe(player, {
                attributes: true,
                attributeFilter: ["class"]
            });
        }

        evaluateFSM(gen);
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
     * Fetches Layer 3 configuration from background.js.
     */
    function fetchConfiguration(onComplete) {
        if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendMessage) {
            return;
        }

        const capturedGen = playerGeneration;

        browser.runtime.sendMessage({ type: "getLayer3Config" }, (response) => {
            if (capturedGen !== playerGeneration && playerGeneration > 0) return;

            if (browser.runtime.lastError || !response) {
                currentConfig = { layer3Enabled: false, reason: "background_unavailable" };
            } else {
                currentConfig = response;
            }

            if (onComplete) onComplete(currentConfig);
        });
    }

    /**
     * Initializes content script on page load.
     */
    function initialize() {
        if (!isAuthorizedOrigin()) return false;
        if (isInitialized) return true;
        isInitialized = true;

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

        fetchConfiguration((config) => {
            if (config && config.layer3Enabled) {
                mountPlayer(playerGeneration);
            }
        });
        return true;
    }

    if (typeof window !== "undefined") {
        initialize();
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
            fetchConfiguration
        };
    }
})();
