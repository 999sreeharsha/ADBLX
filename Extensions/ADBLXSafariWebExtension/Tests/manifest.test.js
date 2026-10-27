// manifest.test.js - Manifest/permission contract tests.
//
// These guard the class of defect where the extension's JavaScript calls a
// WebExtension API whose permission the manifest never declared. Such a call
// fails at runtime via `browser.runtime.lastError` rather than throwing at load,
// and background.test.js cannot catch it because it mocks the browser APIs —
// a mock never enforces permissions.
//
// Regression: `background.js` called `browser.runtime.sendNativeMessage` while
// `permissions` listed only ["storage", "*://*.youtube.com/*"]. Every
// `checkVersion` resolved null, entitlementState pinned to "unavailable",
// `layer3Enabled` was always false, and the YouTube engine never mounted.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const RESOURCES_DIR = path.join(__dirname, "..", "Resources");
const manifest = JSON.parse(
    fs.readFileSync(path.join(RESOURCES_DIR, "manifest.json"), "utf8")
);

function readResource(name) {
    return fs.readFileSync(path.join(RESOURCES_DIR, name), "utf8");
}

/** WebExtension APIs used in source -> the permission each one requires. */
const API_PERMISSION_REQUIREMENTS = [
    { api: "browser.runtime.sendNativeMessage", permission: "nativeMessaging" },
    { api: "browser.storage.local", permission: "storage" }
];

test("manifest declares a permission for every gated WebExtension API the source calls", () => {
    const sources = ["background.js", "content.js"]
        .map(readResource)
        .join("\n");
    const declared = new Set(manifest.permissions || []);

    for (const { api, permission } of API_PERMISSION_REQUIREMENTS) {
        if (sources.includes(api)) {
            assert.ok(
                declared.has(permission),
                `Source calls ${api} but manifest.permissions is missing "${permission}". ` +
                `Declared: ${JSON.stringify([...declared])}`
            );
        }
    }
});

test("manifest declares nativeMessaging (Layer 3 bridge is the only entitlement path)", () => {
    const declared = new Set(manifest.permissions || []);
    assert.ok(
        declared.has("nativeMessaging"),
        "nativeMessaging is required for browser.runtime.sendNativeMessage; " +
        "without it checkVersion always resolves null and Layer 3 stays disabled."
    );
});

// ADR-0010 Decision 1: Sprint 9 targets manifest_version 3, not the scaffold's V2.
test("manifest targets Manifest V3 per ADR-0010", () => {
    assert.equal(
        manifest.manifest_version,
        3,
        "ADR-0010 Decision 1 mandates manifest_version: 3"
    );
});

// ADR-0010 Decision 2: event-page form, NOT service_worker — Safari's
// service_worker background has an Apple-acknowledged debugging bug.
test("background uses the scripts (event-page) form, never service_worker", () => {
    assert.ok(manifest.background, "manifest.background missing");
    assert.ok(
        Array.isArray(manifest.background.scripts),
        "ADR-0010 Decision 2 requires background.scripts (event-page form)"
    );
    assert.equal(
        manifest.background.service_worker,
        undefined,
        "ADR-0010 Decision 2 forbids background.service_worker on Safari"
    );
});

test("host permissions cover the YouTube hosts the engine allowlists", () => {
    const hostPerms = [
        ...(manifest.host_permissions || []),
        ...(manifest.permissions || [])
    ].join(" ");
    assert.ok(
        hostPerms.includes("youtube.com"),
        "No host permission covers youtube.com"
    );
});

test("content script matches the YouTube hosts the engine allowlists", () => {
    const contentSource = readResource("content.js");
    const allowedHostsMatch = contentSource.match(
        /ALLOWED_HOSTS\s*=\s*new Set\(\[([^\]]*)\]\)/
    );
    assert.ok(allowedHostsMatch, "Could not locate ALLOWED_HOSTS in content.js");

    const engineHosts = allowedHostsMatch[1]
        .split(",")
        .map((s) => s.trim().replace(/^["']|["']$/g, ""))
        .filter(Boolean);

    const declaredMatches = (manifest.content_scripts || [])
        .flatMap((entry) => entry.matches || [])
        .join(" ");

    for (const host of engineHosts) {
        assert.ok(
            declaredMatches.includes(host),
            `content.js allowlists "${host}" but no content_scripts match pattern covers it`
        );
    }
});

// Safari requires the extension's Info.plist to point at the web-extension resource
// directory via NSExtension.SFSafariWebExtensionManifestPath. Without it Safari loads
// the appex as a native extension only: the toggle appears in Settings and can be
// switched on, but manifest.json is never read, so no content script is ever injected
// and no [ADBLX-L3] output appears on youtube.com.
//
// Regression: the plist declared only NSExtensionPointIdentifier and
// NSExtensionPrincipalClass, so content.js never ran on any page.
test("Info.plist declares SFSafariWebExtensionManifestPath", () => {
    const plistPath = path.join(__dirname, "..", "Info.plist");
    const plist = fs.readFileSync(plistPath, "utf8");
    assert.ok(
        plist.includes("SFSafariWebExtensionManifestPath"),
        "Info.plist is missing NSExtension.SFSafariWebExtensionManifestPath; " +
        "Safari will never load manifest.json and no content script will inject."
    );
});

test("project.yml generates SFSafariWebExtensionManifestPath for the extension target", () => {
    const projectYml = fs.readFileSync(
        path.join(__dirname, "..", "..", "..", "project.yml"), "utf8"
    );
    assert.ok(
        projectYml.includes("SFSafariWebExtensionManifestPath"),
        "project.yml does not declare SFSafariWebExtensionManifestPath, so " +
        "`xcodegen generate` will strip it from Info.plist on the next run."
    );
});
