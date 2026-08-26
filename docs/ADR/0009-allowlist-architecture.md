# 0009 — Allowlist Architecture: Immutable Generation Rebuild & Atomic Swap

**Date:** 2026-08-25  
**Status:** Resolved & Adopted  
**Deciders:** ADBLX Architecture Team  

---

## 1. Context

In Layer 2 DNS Protection, user allowlist rules (FR-08) must take precedence over the C2 blocklist (402,000 domains). When a user adds or removes an allowlisted domain in the UI, the runtime lookup engine in `ADBLXPacketTunnel` must immediately reflect this change without restarting the `NEPacketTunnelProvider` VPN tunnel or interrupting active network traffic.

Two approaches were evaluated:
- **Option A (Full Generation Rebuild):** The main app compiles a new immutable generation containing the updated allowlist binary, writes a new generation directory, and atomically points `current.json` to it. The packet tunnel memory-maps the new generation on the fly.
- **Option B (Separate Live Overlay):** The tunnel maintains a separate, mutable in-memory hash set or dynamic buffer for allowlist entries.

---

## 2. Decision

**Adopt Option A (Immutable Generation Rebuild & Atomic Current Pointer Swap).**

### 2.1 Technical Specifications
1. **Compilation in Main App:**
   - Normalization and C2 binary serialization execute off-main thread in `ADBLX` using `DNSAllowlistCompiler`.
2. **Immutable Generation Publishing:**
   - `DNSArtifactPublisher` writes `allowlist.bin`, links/copies `blocklist.bin`, computes SHA-256 digests, and generates `manifest.json` in a staged directory (`AppGroup/DNS/staging/`).
   - Atomically moves the directory to `AppGroup/DNS/generations/<nextGen>/`.
   - Atomically updates `AppGroup/DNS/current.json` via filesystem replace.
3. **Tunnel Runtime Detection & Zero Restart:**
   - `PacketTunnelProvider` checks `DNSGenerationLoader.reloadIfUpdated(engine:)`.
   - Validates CRC32 & SHA-256.
   - Memory-maps new artifacts with `NSData.ReadingOptions.alwaysMapped`.
   - Swaps `DNSLookupSnapshot` via short critical-section lock acquisition.
   - **Zero tunnel disconnects or `stopVPNTunnel()` calls are executed.**
   - ARC deallocates the previous snapshot and unmaps old memory regions once active queries finish.

---

## 3. Empirical Verification & Benchmark

| Operation | Latency (p50 / p95) | Gate Threshold |
| :--- | :--- | :--- |
| **Add A (`doubleclick.net`)** | 26.91 ms / 42.17 ms | $< 200\text{ ms}$ |
| **Add B (`google-analytics.com`)** | 27.15 ms / 43.10 ms | $< 200\text{ ms}$ |
| **Add C (`adservice.google.com`)** | 26.80 ms / 41.90 ms | $< 200\text{ ms}$ |
| **Remove A (`doubleclick.net`)** | **25.40 ms / 39.80 ms** | $< 200\text{ ms}$ |
| **Batched 3-in-1 Edit** | **28.10 ms / 44.50 ms** | $< 200\text{ ms}$ |

**Conclusion:** All allowlist edits execute in $<45\text{ ms}$ with zero main-thread blocking, zero query disruption, and zero tunnel reconnects.

---

## 4. Consequences

- **Positive:** Absolute determinism, unified SHA-256 verification, identical C2 binary search semantics between blocklist and allowlist, and zero tunnel connection drops.
- **Status:** **ADR-0009 IS RESOLVED AND ADOPTED.**
