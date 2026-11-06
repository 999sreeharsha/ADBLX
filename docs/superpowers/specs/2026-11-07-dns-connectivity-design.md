# DNS Protection connectivity: investigation and design

Status: **proposal, no behaviour changed.** Investigated 2026-11-07 on `feat/plan-state-downgrade`
(`3ae2aa6`). Closes nothing in `docs/gotchas.md` ("DNS Protection breaks app connectivity and
payments") until the device checks in section 6 are run. DNS stays off in Release/TestFlight
meanwhile (`Scripts/check-release-no-dns.sh`, SEC-04).

## Decisions (owner, 2026-11-07)

1. **Payments must work with the tunnel up.** Pause is a fallback, not the fix. So the work
   below fixes the tunnel and the lists first; section 2.4 stays a safety valve.
2. **Upstream is undecided.** Not locked to Quad9 for everything. Section 2.7 compares it with
   the network's own resolver for payment and never-block names; the owner decides after the
   pass-through device test.
3. **Logging.md: option A, counts only.** No "Recently blocked" list (2.6 options B and C are
   dropped).

Built so far (commits on `feat/plan-state-downgrade`): testable route settings, TCP DNS and
fail-fast, DEBUG counters with a pass-through switch, and the never-block list. Sections 2.2, 2.1
and 2.3 say what each did and what is left for a device.

Every `file:line` below is in the tree at the commit named at the top (before that work). Anything marked **(hypothesis)** was not
reproduced; it names the device check that would settle it.

## 1. Findings

### 1.1 Routes: the tunnel does not capture the default route

`PacketTunnelProvider.swift:47-75`:

| Setting | Value | Verdict |
|---|---|---|
| DNS servers | one fake IPv4 server `198.51.100.1`, `matchDomains = [""]` (all names) (`:47-52`) | All DNS goes to the fake server. No IPv6 DNS server is configured. |
| IPv4 `includedRoutes` | only `198.51.100.1/32` (`:56-58`) | **Correct.** Not the default route. |
| IPv4 `excludedRoutes` | the upstream `/32` (+ `9.9.9.9/32`) (`:59-65`) | Correct, keeps the forwarder's own socket off the tunnel. |
| IPv6 | `fd00::2/128`, `excludedRoutes` only, **no `includedRoutes`** (`:69-75`) | Not the default route. Whether an unset `includedRoutes` adds an implicit route is **(hypothesis)**: not confirmed; read the interface's routes on device. |

So suspect 1 in gotchas.md ("routes capture more than DNS") is **unlikely**. The cause is more
likely what happens to the DNS packets the tunnel does receive.

### 1.2 Packets the tunnel silently drops (most likely cause)

`DNSPacketParser` accepts only UDP, unfragmented, `qdCount >= 1`, no compression pointer in the
question (`DNSPacketParser.swift:45`, `:72`, `:39`, `:131`, `:154`). The read loop discards
everything else without a reply (`PacketTunnelProvider.swift:169-171`).

- **TCP to `198.51.100.1:53` is dropped.** Resolvers retry over TCP when a UDP answer has the TC
  bit set. The upstream answer is passed back untouched (`DNSUpstreamForwarder.swift:196-201`), so
  a truncated answer reaches the client, the client opens TCP to the fake server, and the SYN is
  never answered. The app waits for its connect timeout. Large answers are exactly what CDN and
  payment-gateway hostnames produce (long CNAME chains, many A/AAAA, HTTPS/SVCB records).
  **Strongest lead.**
- A name with no labels, a second question with a pointer, or a fragmented query is also dropped.
  These are rare; the cost is the same silent hang.

### 1.3 Failure paths that give the client no answer

| Case | Where | What the client sees |
|---|---|---|
| Upstream does not answer within 5 s | `DNSUpstreamForwarder.swift:215-219`; timeout 5.0 at `PacketTunnelProvider.swift:98` | Nothing. The pending entry is dropped and only a log line is written. The client waits for its own timeout and retries. Not fail-fast. |
| Upstream socket send fails (`ENETUNREACH`, etc.) | `DNSUpstreamForwarder.swift:157-164`; `DNSUpstreamSocket.swift:80-84` | Nothing. The result is ignored (`PacketTunnelProvider.swift:198`). |
| No socket for the family | `DNSUpstreamForwarder.swift:115-117` | Nothing. |
| 512 queries in flight | `DNSUpstreamForwarder.swift:87-100` | SERVFAIL synthesised. Correct. |

Only the capacity case answers the client. A single upstream (Quad9 over UDP/53) with no second
server and no retry means one bad network path makes every name fail.

### 1.4 IPv6 and carrier networks **(hypothesis)**

The fake DNS server is IPv4, so clients always query over IPv4 and the IPv6 socket is never used
for ingress (`DNSUpstreamForwarder.swift:108-113`). The forwarder then reaches Quad9 through an
IPv4 literal (`9.9.9.9`). On an IPv6-only mobile network (Indian mobile networks, Jio in
particular, are reported to be IPv6-only with 464XLAT; I did not verify this), whether an IPv4 literal from a Network Extension process reaches the internet depends
on CLAT availability for that process. If it does not, step 1.3's second row applies to every
query. The upstream IPv6 address is only ever used for IPv6 ingress, which does not occur.
Check: run on Jio/Airtel mobile data with the pass-through switch (section 2.1) and count send
errors (section 2.1 counters).

AAAA handling: AAAA and HTTPS queries are forwarded like any other type (`qtype` is parsed but not
used to decide); a blocked name returns NXDOMAIN for every type (`NXDOMAINResponseBuilder`). That
is correct and not a connectivity risk.

### 1.5 Behaviours that are not bugs but matter

- `matchDomains = [""]` sends **all** names, including the carrier's and the network's private
  names (captive portals, VoWiFi, corporate), to Quad9. The network's own resolver is never
  consulted. This is a product decision to confirm (section 7, question 3).
- There is no handling of network changes (no `NWPathMonitor`, no `reasserting`). The UDP sockets
  are unconnected and created once (`DNSUpstreamSocket.swift:25-36`); whether they survive a
  Wi-Fi to cellular switch is **(hypothesis)**.
- `handleAppMessage` returns `nil` (`PacketTunnelProvider.swift:152-155`), so counters
  (`:14-17`) exist but nothing can read them.
- Memory: the blocklist is memory-mapped and its SHA-256 is computed over the whole file at start
  and at each reload (`DNSGenerationLoader.swift:117-125`). Reading the whole file makes it
  resident. Network Extension processes have a memory ceiling that Apple does not publish
  (commonly cited as 50 MB on current iOS); measure rather than assume (section 6).

### 1.6 Default lists

Counts below come from running the app's own `DNSDomainNormalizer` over the bundled files
(`ADBLX/Resources/Filters/DNS/`), the same code `DNSBlocklistCompiler` uses.

| List | Lines | Domains kept after normalising |
|---|---|---|
| OISD (`oisd.txt`) | 59,389 | 59,378 |
| Peter Lowe (`peter-lowe.txt`) | 3,551 | 3,537 |
| Union | | 61,292 |

A blocked name blocks all its subdomains (suffix walk, `DNSLookupEngine.swift:60-68`). The
allowlist is checked first (`:46-56`).

### 1.7 Payment, bank and Apple domains: fixed set checked on the Mac

I checked 73 domains (gateways, UPI/NPCI, wallets, banks, Apple, bank anti-fraud, controls)
against the compiled lists. The set and the script stay outside the repo for now; section 6.1
proposes a fixture. Results:

- **Not blocked:** every payment gateway, UPI/NPCI/wallet, bank and Apple domain in the set.
- **Blocked (by Peter Lowe unless noted):**
  - `online-metrix.net`, the ThreatMetrix device-profiling domain many bank and fintech apps
    call during login and payment.
  - `branch.io` hosts (`cdn.branch.io`, and `api2.branch.io` via OISD), used for deep links by
    many fintech apps.
  - `app-measurement.com` and `fpjs.io` (device fingerprinting, also OISD).
  - Controls `doubleclick.net` and `googleadservices.com` are blocked, as expected.

NXDOMAIN on these is a plausible cause of **payment-only** failures, not of "many apps can't reach
the internet". Two separate problems, so two separate fixes.

### 1.8 Existing test coverage

| Area | Covered | Not covered |
|---|---|---|
| Wire parser | v4/v6 parse, malformed and non-UDP rejected (`DNSWireParserTests`) | What happens to a rejected packet. TCP is asserted to be *rejected*, which is the current hang. |
| Forwarder | correlation, timeout eviction, capacity SERVFAIL, rogue source, shutdown, fast-response race (`DNSUpstreamForwarderTests`) | SERVFAIL on timeout, send failure reaching the client, TC bit, failover, v4 ingress over a v6 upstream. |
| Lookup / loader | precedence, suffix, generation swap, last-known-good (`DNSRuntimeLookupTests`) | Never-block layer; load time and memory. |
| Tunnel settings | none | Routes, DNS servers, IPv6. `startTunnel` builds them inline (`:47-75`), so they cannot be unit-tested. |
| Device | live Quad9, manager, lifecycle, system resolve through tunnel (`DNSRealQuad9ResolutionTests`) | Real apps, TCP fallback, carrier networks. |

### 1.9 Ranked suspects

| # | Suspect | Evidence | Decisive check |
|---|---|---|---|
| 1 | TCP/53 and TC fallback dropped | 1.2, code | Query a name with a large answer through the tunnel with `dig +tcp`; count dropped non-UDP packets. |
| 2 | No answer on timeout or send failure, single upstream | 1.3 | Counters for timeouts and send errors per network (Wi-Fi, Jio, Airtel). |
| 3 | IPv4 literal upstream on IPv6-only mobile (hypothesis) | 1.4 | Same counters, mobile data only. |
| 4 | Banking anti-fraud and deep-link domains blocked | 1.7 | Pass-through on/off while paying. |
| 5 | Bank/UPI app refuses while any VPN is up | not code | Pass-through still fails, "Turn off" works. |
| 6 | Routes capture more than DNS | refuted by 1.1 | Read device routes once. |

## 2. Design

Each item ends with an impact table. "Verify" says how to measure it, not how to unit-test it.

### 2.1 DEBUG pass-through switch plus counters

> **Built, DEBUG only.** `DNSTunnelCounters` (11 integers), `DNSLookupEngine.isPassthrough`, a
> provider-message handler, and a "DNS tunnel" section on the Developer screen. The shared types are
> `#if DEBUG` in `ADBLXShared`; `Scripts/check-release-no-dns.sh` fails a Release app that contains
> them. Pass-through resets when the tunnel restarts.

- A Developer-screen toggle writes `passthrough` into the tunnel's `providerConfiguration`
  (same path as `resolverOption`, `DNSProtectionService.swift:166-172`). In the extension, a
  pass-through decision skips the lookup and forwards every query. It is `#if DEBUG` and the
  tunnel is not built in Release anyway.
- The tunnel keeps integer counters only: ingress, blocked, forwarded, responses, timeouts, send
  errors (split v4/v6 socket), SERVFAIL synthesised, **dropped non-UDP**, **dropped unparsable**,
  TC responses seen. `handleAppMessage` returns them as a small `Codable` struct. Nothing else is
  returned or logged: counts only, per `Logging.md`.
- The Developer screen reads them on demand (no polling).

| | |
|---|---|
| Main thread | None in the extension. App reads once per tap, off the main actor. |
| Memory | About 10 integers. |
| I/O | None. Counters stay in memory; they are read through `sendProviderMessage`, never written to disk. |
| Radio / battery | None. No timers, no network. Increments are in an existing loop. |
| Verify | Instruments (Energy and Time Profiler) on a 10-minute browse with counters on vs. the current build; counters must match a known `dig` script. |

### 2.2 Fail-open for packets and answers

> **Built:** steps 1 and 3, in a different shape than first written. The tunnel now runs a small
> TCP server on the fake DNS address (handshake, length-prefixed queries, answers, close), so
> a client that retries over TCP gets an answer instead of silence. A truncated upstream answer
> is retried over TCP; an answer over the client's UDP limit is cut with TC set. Timeout, send
> failure and no socket give SERVFAIL; the upstream timeout is 2 s. **Not built:** step 2 (retry on
> a second upstream or the other IP family) and step 4 (network-change handling). Known limits:
> TCP is IPv4 only (no IPv6 route reaches the tunnel), the server ignores the client's TCP
> window (DNS answers are small), and a UDP packet that is not a readable DNS question still gets
> no reply because there is nothing to answer.

Order of work, smallest first; each is independently shippable.

1. **Never leave a client waiting.** On timeout (lower to 2 s), send failure, no socket or
   unparsable DNS-to-fake-server packet, synthesise SERVFAIL (the capacity path already does,
   `:87-100`). For TCP/53 reply with a TCP RST so the client fails over at once.
2. **Retry once on the other family and a second upstream** (e.g. `149.112.112.112` for Quad9)
   before giving up. Addresses suspects 2 and 3.
3. **Handle TC upstream.** If an upstream UDP answer has TC set, repeat the query upstream over
   TCP inside the extension (excluded route, `NWConnection`) and return the full answer over UDP
   if it fits the client's EDNS size. Only if telemetry shows many TC answers that do not fit,
   add a minimal TCP front-end on `198.51.100.1:53`. Not before: it is the largest piece.
4. **Network change.** Re-create the upstream sockets on a path change (`NWPathMonitor` in the
   extension) and set `reasserting` while doing so.

| | 1. SERVFAIL/RST | 2. Retry + 2nd upstream | 3. TCP upstream | 4. Path change |
|---|---|---|---|---|
| Main thread | none | none | none | none |
| Memory | none | one more socket (a few KB) | one `NWConnection` per TC query, short-lived | one monitor object |
| I/O | none | none | none | none |
| Radio wakeups | none. Replies are local; shorter timeout lowers retries | extra upstream packet only when the first attempt fails | extra TCP handshake only on TC | none; monitor reacts to events the radio already produced |
| Battery | fewer client retries is a small saving | negligible | negligible | negligible |
| Verify | unit tests with the fake socket (section 6.1); device: `dig` against a blackholed upstream returns SERVFAIL in about 2 s | forwarder tests; device on IPv6-only network | forwarder tests with a TC fixture; device `dig +tcp` | device: toggle Wi-Fi/cellular during a download, tunnel recovers; counters show re-creation |

### 2.3 Never-block list, applied before blocklists

> **Built.** Its own list (`DNSNeverBlockList`, seed `ADBLX/Resources/Filters/DNS/never-block.txt`),
> not the user's allowlist and not a filter list. Compiled into the allowlist artifact at publish
> time (`DNSArtifactPublisher.publish(neverBlockRules:)`), so the tunnel's allowlist-first check
> applies it before every blocklist entry. The manifest gains an optional `dnsNeverBlock` entry
> (version, URL, SHA-256, domain count); `DNSNeverBlockUpdater` installs it only if the download
> is whole, matches the checksum and count, and has at least one domain. **Not done:** the
> Publisher does not emit the entry yet, because `feat/manifest-signing` rewrites the same files
> (`ManifestBuilder`, the golden manifest, `ManifestClient`) and the signed manifest must cover
> the new field. Until both land, the app uses the bundled seed. A new list reaches the tunnel at
> the next DNS start or allowlist edit, not instantly.

- A **never-block** set (payment gateways, UPI/NPCI, bank domains, Apple, device-attestation
  endpoints) ships in the signed manifest (the manifest-signing branch) with a bundled default for
  offline. It is compiled into the **allowlist artifact** at publish time
  (`DNSArtifactPublisher`), so the existing "allowlist first" step (`DNSLookupEngine.swift:46-56`)
  enforces it with no new hot-path code.
- Whether anti-fraud and deep-link domains (`online-metrix.net`, `branch.io`) belong on it is a
  privacy trade (question 4). Default proposal: yes for anti-fraud, no for analytics.
- A never-block entry can never be removed by a list update, only by an app/manifest update.
  The user's own allowlist stays additive.

| | |
|---|---|
| Main thread | None. |
| Memory | The allowlist artifact grows by a few hundred domains (kilobytes); the blocklist is unchanged. |
| I/O | Same publish as today. The artifact is a little larger. |
| Radio | The manifest already exists; no new request. |
| Battery | Same lookup cost. |
| Verify | Unit test: every fixture domain in section 6.1 returns `.allow` with the real bundled lists loaded. Device: pay through a gateway with the lists on. |

### 2.4 "Pause for 15 minutes"

Two modes, because they solve different problems. The first does not help if a banking app
refuses while any VPN is up.

- **Pause filtering.** The app sends `pause(until:)` with `sendProviderMessage`; the extension
  switches to pass-through and resumes by itself using a timer **inside the extension**, so it
  works with the app closed. The tunnel stays up and answers DNS. Fixes over-blocking.
- **Turn off for 15 minutes.** `stopVPNTunnel()` and a scheduled local notification "Tap to turn
  DNS Protection back on". The app cannot restart a tunnel in the background, so resume needs a
  tap or the next app open, and the copy must not promise an automatic restart. Fixes
  VPN-detecting apps. Needs `UNUserNotificationCenter` permission, which the app does not request
  yet (`docs/gotchas.md`, Settings entry).

Minimum iOS versions: `sendProviderMessage` / `handleAppMessage` exist since iOS 9,
`NEVPNConnection.stopVPNTunnel` since iOS 8, `NWPathMonitor` since iOS 12, local notifications
since iOS 10. The app's deployment target is 26.5, so none is a constraint. I could not check
Apple's documentation in this session; confirm these in the docs before quoting them in copy.

Rules: pause is persisted in the App Group as an absolute expiry, so a tunnel restart never
extends it; the clock-backwards guard used by `PlanCardDismissal` applies; at most one pause
active; it is a one-tap action on Home and the DNS screen.

| | Pause filtering | Turn off 15 min |
|---|---|---|
| Main thread | none | none (notification scheduling is async) |
| Memory | one `Date` | none |
| I/O | one small App Group write at start and end | same |
| Radio | none (a timer, no network) | none |
| Battery | one coalesced `DispatchSourceTimer` (set leeway of a few seconds) | none; tunnel is off, so battery improves |
| Verify | device: pause, close the app, confirm resume at 15 min with counters; Instruments timer firing count | device: notification fires, tap restarts tunnel |

### 2.5 Banking-app UX and VPN-conflict detection

- Copy for the pause sheet (draft): "Some banking and UPI apps won't complete a payment while a
  VPN is on. Turn DNS Protection off for 15 minutes, then turn it back on." One sentence, no
  claim about which apps.
- **Detecting another VPN** is weaker than the current code suggests. iOS runs one packet tunnel
  at a time, so starting ours turns the user's other VPN off. The existing `.vpnConflict` fires
  when our manager's status is `.invalid` (`DNSProtectionService.swift:183-184`), which is a
  broken configuration, not another VPN. A real signal is the set of scoped interfaces from
  `CFNetworkCopySystemProxySettings()` (`__SCOPED__` keys such as `utun`, `ipsec`) before our
  start. Treat that as **(hypothesis)** until checked on a device with a second VPN installed.
  Proposal: before starting, warn "Another VPN looks active; starting ADBLX will turn it off".

| | |
|---|---|
| Main thread | One synchronous CFNetwork call at start tap; negligible, but call it off the main actor. |
| Memory / I/O / radio / battery | None. |
| Verify | Device with a second VPN profile active: the warning appears; with none, it does not. |

### 2.6 Logging.md amendment: a "Recently blocked" list

> **Decided: option A.** Options B and C are kept below for the record only. The counters in
> 2.1 are the whole feature.

`Logging.md` forbids domains in logging, diagnostics and crash reports with no exception. A list
the user can see is a different thing from a log, but it needs a written exception or it will be
treated as a violation. Options:

| | Option | Where domains live | Verdict |
|---|---|---|---|
| A | No list; counts only | nowhere | **Recommended for the first TestFlight.** Zero policy change. |
| B | In-memory ring buffer in the extension, at most 50 entries, expires after 10 minutes, cleared on tunnel stop, returned only via `sendProviderMessage` while the app is foreground | extension RAM only | **Recommended if a list is wanted.** Never written to disk, `os_log`, crash reports or metrics. |
| C | Persist in the App Group with a 15-minute TTL | disk | Not recommended. Survives a crash and appears in a backup or file inspection. |

Option B amendment text (draft): "A user-visible list of recently blocked domains is allowed only
if it is held in memory, expires within 10 minutes, is never written to disk, logs, crash reports
or analytics, and never leaves the device." Needs the owner's decision (question 5). A test must
assert that no domain reaches `os_log` (as `noLoggingInFeature` already does for BrokenSite).

| | A | B |
|---|---|---|
| Main thread | none | none; app reads on demand |
| Memory | none | about 50 short strings (a few KB) |
| I/O | none | none |
| Radio / battery | none | none; no timers (expiry is checked on read) |
| Verify | n/a | unit: eviction at 50 and at 10 min; log-scan test; device: sysdiagnose contains no domain |

### 2.7 Resolver for payment and never-block names: Quad9 or the network's own

Nothing is built for this yet; it is the comparison for the owner's decision. Today every name
goes to Quad9 over UDP/53 (`PacketTunnelProvider.swift`, `UpstreamResolverOption`). The question is
whether names on the never-block list (payments, banks, Apple, fraud checks) should instead go to
the resolver the network handed the device (Wi-Fi router, carrier).

| | Quad9 (9.9.9.9 / 2620:fe::fe) | The network's own resolver |
|---|---|---|
| **Latency** | One fixed anycast target; typically tens of ms from India, but a single resolver and a 2 s timeout. Measure p50/p95 per carrier. | Usually the lowest (one hop to the carrier or router). On Wi-Fi it is the router's cache. Measure the same way. |
| **IPv6 reachability** | We reach Quad9 over IPv4 only today (1.4). On an IPv6-only network that depends on CLAT. Adding the v6 address helps only if we send over it. | Works by definition on the network that gave it, including IPv6-only and NAT64 networks, because the carrier's resolver is on-net. |
| **Privacy** | Names go to Quad9, an operator outside the user's carrier, which says it does not log IPs; the carrier still sees the connection, not the names. | The carrier or router sees every name, as it does without the tunnel. For payment names this adds nothing new: the user's bank already resolved through it before. |
| **Geo behaviour** | Anycast and ECS handling differ from the carrier's, so a gateway or bank that routes by resolver location (CDN steering, geo allow-lists) can see Quad9's location, not the user's. Some Indian banks and UPI apps geo-fence. | The carrier's resolver is in the user's region and is what the bank's CDN expects. Lowest risk of a "wrong region" answer. |
| **Blocking and tampering** | No carrier DNS tampering or injected ads. | The carrier may block, redirect or inject on some names; for the never-block set that is the same as having no tunnel. |
| **Captive portals, VoWiFi, private names** | Cannot resolve them; this breaks them for every name today (1.5). | Resolves them. |
| **Code needed** | None. | The extension can't read the network's resolver addresses while the tunnel owns DNS. Options: record `NWPathMonitor` / `res_ninit` resolvers before the tunnel starts (stale after a network change), or ask `NEDNSSettings` per-domain match rules to leave these names alone (`matchDomains` for the never-block set, so the OS resolves them with the network's resolver and they never enter the tunnel). The second needs no extension code and is the simplest way to try the idea. |

How to decide with data: the pass-through test plus the new counters give timeouts and send errors
per network. Add per-resolver latency only as counts in buckets, never a name. If Quad9 shows
timeouts or send errors on any carrier, the network resolver wins for the never-block set. If it
is clean and fast everywhere, keep one resolver and revisit only if a geo-fenced bank fails.

Impact of the `matchDomains` option for never-block names: main thread none; memory a few KB for
the domain list in the tunnel settings; I/O none; radio none (it removes queries from the
tunnel); battery slightly better (fewer packets through the extension). Verify on a device with
a gateway on the never-block list: the name must not appear in the tunnel's counters, and the
payment must complete on Wi-Fi, Jio and Airtel.

## 3. What this spec does not change

Compiler and Safari content blocking, entitlement checks, the DNS allowlist UI, and the upstream
choice (Quad9 default). No file under `ADBLX/` or `Extensions/` is modified by this document.

## 4. Order of work if approved

1. Extract `TunnelNetworkSettingsFactory` (pure function) and test the routes (6.1).
2. Counters and the Debug pass-through switch (2.1). **Run the decisive device test first**
   (6.2); it tells us whether to build 2.2 steps 3-4 or only step 1-2.
3. Fail-open steps 1-2 (2.2).
4. Never-block list (2.3).
5. Pause (2.4), then VPN warning (2.5).
6. Option A of 2.6 until the owner decides.

DNS stays Debug-only until step 2's device test and the 6.2 checklist pass on at least two
carriers and Wi-Fi.

## 5. Risks

- Fixing 2.2 may not fix payments if the cause is suspect 5 (an app that refuses any VPN). Then
  "Turn off for 15 minutes" is the only fix and the feature stays Premium-optional.
- A never-block list is a maintenance and trust burden: an entry that is wrong lets a tracker
  through. Keep it small, signed and reviewed.
- Retrying across upstreams sends one query to two resolvers; both are Quad9 by default.

## 6. Test plan

### 6.1 Unit-testable now (no device)

- **Routes:** `TunnelNetworkSettingsFactory` returns `includedRoutes == [198.51.100.1/32]`, none
  of them default, upstream in `excludedRoutes`, IPv6 has no included route. Expected values are
  literals, not read from the constants the factory uses (`docs/gotchas.md`, set-equality entry).
- **Forwarder:** SERVFAIL on timeout and on send failure; TC answer handling; failover to the
  second upstream; v4 ingress with only a v6 upstream.
- **Parser/loop:** TCP/53 packet yields an RST, not silence (extract the decision from
  `readPackets` so it is testable).
- **Never-block:** a fixture of payment/bank/Apple domains (domains live only in the test file,
  never logged) all `.allow` against the real bundled lists. The Mac check in 1.7 becomes this
  test, plus a negative control that `doubleclick.net` is still blocked.
- **Counters:** counts increment per case; the message reply contains no string fields (assert
  by type).
- **Pause:** absolute expiry, restart does not extend, clock moved backwards does not shorten it.
- **Logging:** a source scan of the tunnel and DNS feature for `Logger` calls interpolating a
  domain.

### 6.2 Device checklist

Run on the iPhone 14, Debug build, with the Developer screen counters visible.

1. Pass-through on, Wi-Fi: browse 5 minutes, open a banking app and a UPI app. **Broken?** Then
   the tunnel, not the lists (suspects 1-3).
2. Same on Jio mobile data and Airtel mobile data. Compare timeout and send-error counters.
3. `dig`-style check from a second device is not possible; use a tiny debug action that resolves
   a large-answer name over UDP and over TCP through the tunnel and reports pass/fail only.
4. Pass-through off, lists on: payment flow with one gateway, one UPI app, one bank app. Note
   which fail; correlate with 1.7.
5. Wi-Fi to cellular switch during a download.
6. Second VPN installed and active: start ours, see the warning (2.5).
7. Tunnel start time and memory: Instruments (Allocations, `os_proc_available_memory`) at start,
   after one reload, and after 30 minutes. Record the ceiling observed.
8. 10-minute energy comparison: tunnel off, pass-through, lists on (Instruments Energy Log).
9. sysdiagnose after a session: confirm no domain appears anywhere.

## 7. Open questions

Answered 2026-11-07: payments must work with the tunnel up (1); upstream choice deferred to the
pass-through test (2, section 2.7); Logging.md option A (3).

1. After the pass-through test: Quad9 for everything, the network's resolver for the never-block
   set (via `matchDomains`, 2.7), or the network's resolver by default?
2. May the Publisher and the signed manifest emit `dnsNeverBlock` once `feat/manifest-signing`
   merges? The app side is ready; this is the order of two branches.
3. Is a second Quad9 address (`149.112.112.112`) acceptable as a failover (2.2 step 2, not built)?
4. Should a never-block entry for a fraud-check domain (`online-metrix.net`) ship in the first
   TestFlight, or wait for the pass-through result? (It is in the seed now.)
5. May a fixture of payment and bank domains stay in the test files? (It does: the never-block
   tests list public hostnames and never log them.)
