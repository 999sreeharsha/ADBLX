extension ManifestTrust {
#if DEBUG
    /// A key for device testing against a manifest signed locally with a test key. Debug
    /// builds only; `Scripts/check-manifest-trust.sh` fails an archive if one of these is in
    /// `productionPublicKeys`. Empty until the owner makes a test key.
    static let debugPublicKeys: [String] = []
#else
    static let debugPublicKeys: [String] = []
#endif
}
