// ADBLX/Filtering/Validation/PublicSuffixList.swift
import Foundation

/// Clean-room implementation of Public Suffix List rules for accurate eTLD+1 registrable domain extraction.
public struct PublicSuffixList: Sendable {
    /// Curated set of multi-part public suffixes covering standard international ccTLDs and platforms.
    private static let multiPartSuffixes: Set<String> = [
        // UK
        "co.uk", "org.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "ac.uk", "gov.uk", "nhs.uk",
        // Australia
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        // India
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in", "gov.in", "mil.in", "ac.in", "edu.in", "res.in",
        // Japan
        "co.jp", "ne.jp", "or.jp", "ac.jp", "ad.jp", "ed.jp", "go.jp", "gr.jp", "lg.jp",
        // New Zealand
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "geek.nz", "school.nz",
        // Brazil
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br", "dev.br",
        // South Africa
        "co.za", "net.za", "org.za", "gov.za", "ac.za", "edu.za",
        // Singapore
        "com.sg", "net.sg", "org.sg", "gov.sg", "edu.sg", "per.sg",
        // Canada
        "gc.ca", "ab.ca", "bc.ca", "mb.ca", "nb.ca", "nl.ca", "ns.ca", "nt.ca", "nu.ca", "on.ca", "pe.ca", "qc.ca", "sk.ca", "yk.ca",
        // France / Germany / EU ccTLD subdomains
        "tm.fr", "asso.fr", "nom.fr", "prd.fr", "presse.fr", "com.de",
        // Common hosting / platforms
        "github.io", "gitlab.io", "pages.dev", "web.app", "firebaseapp.com", "appspot.com",
        "myshopify.com", "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com",
        "vercel.app", "netlify.app", "herokuapp.com", "fly.dev", "deno.dev"
    ]

    /// Second-level labels that country registries use as categories (`co.kr`, `com.mx`,
    /// `or.jp`). Under a two-letter TLD, one of these not in `multiPartSuffixes` means the
    /// registrable domain is uncertain.
    private static let registryLikeSecondLevels: Set<String> = [
        "ac", "co", "com", "edu", "gen", "go", "gob", "gov", "gv", "id", "info", "int", "ltd",
        "me", "mil", "ne", "net", "nom", "or", "org", "plc", "sch", "web"
    ]

    /// Extracts the eTLD+1 (effective top-level domain + 1 label, i.e. the registrable domain).
    /// For example:
    /// - `news.bbc.co.uk` -> `bbc.co.uk`
    /// - `docs.github.io` -> `docs.github.io`
    /// - `api.v1.example.com` -> `example.com`
    /// - `example.com` -> `example.com`
    public static func extractETLDPlusOne(from host: String) -> String {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = clean.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return clean }

        // Check if last 2 labels form a known multi-part public suffix (e.g. co.uk, com.au, github.io)
        if labels.count >= 3 {
            let twoSuffix = "\(labels[labels.count - 2]).\(labels[labels.count - 1])"
            if multiPartSuffixes.contains(twoSuffix) {
                // If 3+ labels, take [count - 3].[count - 2].[count - 1] (e.g. bbc.co.uk)
                return "\(labels[labels.count - 3]).\(twoSuffix)"
            }
        }

        // A country code whose second level looks like a registry (co.kr, com.mx, ac.th) that
        // the curated set doesn't know: the last two labels would be the suffix itself, and
        // allowlisting it would cover every site under it (SEC-10). Keep the full host instead:
        // narrower, never wider.
        let tld = labels[labels.count - 1]
        if tld.count == 2, registryLikeSecondLevels.contains(labels[labels.count - 2]) {
            return clean
        }

        // Standard 2-label TLD extraction (e.g. example.com from sub.example.com)
        return "\(labels[labels.count - 2]).\(labels[labels.count - 1])"
    }
}
