import Foundation
import ADBLXShared
import OSLog

public enum WebExtensionBootstrap {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX",
        category: "WebExtensionBootstrap"
    )

    public static func ensureInitialWebExtensionRulesInstalled() {
        let entitlementPublisher = WebExtensionEntitlementPublisher()
        do {
            try entitlementPublisher.publish(isPremium: true)
            logger.info("Published active premium entitlement for Layer 3")
        } catch {
            logger.error("Failed to publish WebExtension entitlement: \(error, privacy: .public)")
        }

        let rulePublisher = WebExtensionRulePublisher()
        let rulesData = defaultRulesJSON.data(using: .utf8)!
        do {
            _ = try rulePublisher.publish(rulesData: rulesData)
            logger.info("Published initial Generation 1 rules for Layer 3")
        } catch {
            logger.error("Failed to publish initial WebExtension rules generation: \(error, privacy: .public)")
        }
    }

    public static let defaultRulesJSON = """
    {
      "schemaVersion": 1,
      "generation": 1,
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
          "playerContainers": ["#movie_player", ".html5-video-player", "ytm-mobile-player", "#player-container-id"],
          "adStateClasses": ["ad-showing", "ad-interrupting"],
          "skipButtons": [".ytp-ad-skip-button", ".ytm-skip-ad-button", ".ytp-skip-ad-button", "button.ytp-ad-skip-button-modern"],
          "adBadges": [".ytp-ad-text", ".ytm-ad-badge", ".ytp-ad-simple-ad-badge"],
          "cosmeticHideTargets": [
            ".ytp-ad-player-overlay",
            ".ytp-ad-overlay-container",
            "ytm-promoted-sparkles-web-renderer",
            "ytm-companion-ad-renderer",
            ".ad-container",
            "ytm-promoted-video-renderer"
          ]
        },
        "parameters": {
          "maxAccelerationRate": 16.0,
          "candidateConfirmationWindowMs": 100,
          "safeRecoveryStabilityWindowMs": 500,
          "accelerationSafetyTimeoutMs": 5000
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
    """
}
