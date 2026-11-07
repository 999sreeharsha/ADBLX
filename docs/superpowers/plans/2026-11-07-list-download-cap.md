# List download cap (SEC-09, rest)

Design: `docs/Security/ManifestTrust.md` (Size) and SEC-09's size-cap item in
`docs/Security/Findings.md`. Branch: `feat/list-download-cap`, off `feat/plan-state-downgrade`
at `2725c14`. For review before building.

## Problem

`FilterDownloadClient.download` calls `session.data(for:)`, which holds the whole body in
memory before any size check, then writes it to the workspace. A wrong or hostile response
can be any size. The manifest is signed, so the list's checksum is trusted, but the checksum
is checked only after the whole body has arrived.

## What exists today

- The largest list is EasyList at 2.06 MB, then Fanboy Annoyances (1.70 MB) and EasyPrivacy
  (1.50 MB). `shield-fixes` is 355 bytes. No Regional list is published yet.
- The manifest and signature caps are done (`URLSession.data(for:maxBytes:)`, byte by byte).
  That pattern must not be reused for lists (review, 2026-11-07).
- All requests go through the app's one `URLSession`, whose delegate is `RedirectGuard`.
- After the download, `Checksum.verify(fileURL:)` and `UpdateCoordinator` (line 286) each read
  the whole file into memory, and compose and compile hold the list in memory anyway. The cap
  bounds the download, not the later steps.
- 23 call sites construct `FilterDownloadClient(session:)` with a `MockHTTPSession`.

## Decisions to review

1. **Cap: 8 MB per list,** about four times EasyList. One constant,
   `FilterDownloadClient.maxListBytes`, with the reason next to it. A list that grows past it
   needs an app release, so the doc says to revisit it when any list passes 4 MB.
2. **Declared length:** a download task has no "response received" callback before data
   arrives. The earliest point is the first `didWriteData`, which carries
   `totalBytesExpectedToWrite`. The plan checks it there, before more than the first chunk
   (typically ≤ 64 KB) is written, and cancels. A HEAD request first would add a round trip
   to every list for little gain. If "up front" must mean before any byte, say so and I'll
   plan the HEAD.
3. **Over the cap → the run fails,** like a checksum mismatch: thrown before the snapshot,
   nothing written, the throttle not advanced. The open point: a list that is always too big
   (a publishing bug in a signed manifest) costs up to 8 MB per launch on every phone until
   it's fixed. Options are (a) leave it, since it's a publishing bug the signed manifest
   should never carry, and the Publisher could refuse lists over the cap, or (b) advance the
   throttle like a manifest rejection. Recommendation: (a) plus a Publisher check that refuses
   any list over the same 8 MB, so it can't be published.

## Tasks

Each task ends green, with a test that fails without it.

### 1. Spike: confirm the delegate calls on a download task (no production code)

Check on the simulator, with a `URLProtocol` stub, that a per-task delegate
(`URLSessionTask.delegate`, iOS 15+) on a download task created from the app's session gets:
- `didWriteData` with `totalBytesExpectedToWrite` set when the server sends `Content-Length`,
  and `NSURLSessionTransferSizeUnknown` when it doesn't;
- `didFinishDownloadingTo` before the temporary file is deleted;
- and that `RedirectGuard`, the session delegate, still gets `willPerformHTTPRedirection`
  when the task delegate doesn't implement it.

If any of these fails, stop and report: the design below depends on all three.

### 2. `HTTPSession.download(for:maxBytes:to:)`

A new requirement: download to a file the caller names, and throw
`HTTPSessionError.tooLarge` past `maxBytes`.

- **`URLSession`:** a download task with a per-task delegate (`ListDownloadDelegate`):
  - on the first `didWriteData`, cancel if `totalBytesExpectedToWrite` is known and over the cap;
  - on every `didWriteData`, cancel once `totalBytesWritten` passes the cap. A server can omit
    or lie about the length;
  - in `didFinishDownloadingTo`, move the file to the destination before returning, since the
    system deletes it afterwards;
  - complete through a continuation exactly once: success, `tooLarge` or the transport error.
    A cancelled task leaves no file at the destination.
- **Test sessions** (protocol extension default): check the declared length, then the body
  size, then write the body to the destination. This keeps `MockHTTPSession` and the 23 call
  sites working unchanged.

Tests:
- Through a real `URLSession` with a `URLProtocol` stub (no network): a body under the cap
  arrives intact; a declared length over the cap is refused, with no file at the destination;
  a body over the cap with no `Content-Length` is refused, with no file; a declared length
  that understates the body is refused once the bytes pass the cap; a redirect to another host
  is still refused.
- The default implementation: the same three refusals with `MockHTTPSession`.

### 3. `FilterDownloadClient` downloads to the workspace through the cap

- Download straight into `<workspace>/<id>-<uuid>.tmp`; no `Data` of the list is held during
  the download.
- `tooLarge` becomes `FilterDownloadClientError.tooLarge(filterID:)`, thrown before the
  snapshot, so installed rules are untouched and the workspace is cleaned as on every exit.
- Log `list download refused reason=tooLarge` with the byte cap only, no URL or ID
  (`Logging.md`).

Tests:
- An over-cap list fails the run with the installed rules, `installed_filters.json`, the cached
  manifest and the ETag byte-identical, and the workspace empty.
- The existing `FilterDownloadClientTests` and update suites pass unchanged.

### 4. Checksum without loading the file

`Checksum.verify(fileURL:)` reads the file in 64 KB chunks into an incremental SHA-256 instead
of loading it whole. Small, and it removes one full copy of the list from peak memory during
verify. Test: the same digest as the in-memory version for an empty file, a file under one
chunk, and one of several chunks plus a remainder.

### 5. Publisher refuses lists over the cap (if decision 3 is (a))

`Validator` fails `publish` for any payload over 8 MB, with the same figure as the app.
Test in `ValidationTests`.

### 6. Docs and device check

- `ManifestTrust.md` Size, `Findings.md` SEC-09, `TECHNICAL_OVERVIEW.md` update flow, and a
  gotcha if the spike turns up anything surprising.
- Device check (owner, iPhone 14): an Allocations trace during a full update with
  ~150K rules. Peak memory should be about the same with or without the download in flight.
  This is the verification SEC-09 asks for; the simulator can't stand in for it.

## Not in this plan

- Streaming compose and compile. They hold the list in memory by design today.
- Background download sessions (`URLSessionConfiguration.background`). Updates run in the
  foreground at launch.

## Performance

- Main thread: none; delegate callbacks run on the session's delegate queue.
- Memory: during download, only `URLSession`'s buffers; the list is on disk. Task 4 also
  removes one full in-memory copy during verify.
- Disk: one temp file per list, as today, moved rather than rewritten.
- Network: unchanged for valid lists; an over-cap response stops within one chunk of the
  cap, or within the first chunk when the length is declared.
- Energy: no change for valid updates.
