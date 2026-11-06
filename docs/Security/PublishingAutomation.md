# Manifest Publishing Automation (future)

**Status:** not started. Planned design only; nothing here is implemented.
**Decided 2026-11-06:** manifests are signed manually by the owner (Option B).
This document records how publishing could be automated later without weakening that.
Related: [`ManifestTrust.md`](ManifestTrust.md), [`Findings.md`](Findings.md).

## Current process (Option B)

- K1 and K2 are ordinary key files kept offline, never in the repo, CI, a cloud
  session or any folder an AI session can read.
- Each publish is manual: run the Publisher (`generate`, then `sign`), review the
  result, deploy to GitHub Pages.
- Lists update only when the owner publishes. Free users are promised weekly
  updates (PRD §5.1); premium's "daily" wording must change to match what actually
  happens (see Open decisions).

## Rule that applies to any future automation

**No AI agent ever has access to a signing key.** Publishing processes untrusted
input (upstream filter lists from the internet). An LLM-driven agent that reads that
input and can also sign is open to prompt injection: a crafted line in a list could
instruct it to add rules or reveal the key. This holds whether the agent runs in the
cloud or on the owner's Mac.

An AI may be used only to write a human-readable summary of a pending publish, with
no access to the key, the signing command or the deploy credentials.

## Planned design

A deterministic local script, not an AI agent, scheduled on the owner's Mac.

### Components

| Part | Design |
|---|---|
| Scheduler | `launchd` job on the owner's Mac (runs missed jobs after wake) |
| Pipeline | Existing Publisher: fetch upstream lists → `validate` → `generate` → compare with last published manifest |
| Signing key K1 | Secure Enclave key: usable by the job, never exportable |
| Recovery key K2 | Ordinary key file, offline, stored separately from the Mac |
| Deploy credential | GitHub deploy key with write access to the Pages repository only |
| Notification | Local macOS notification for any held publish |

### Publish rules

The job signs and publishes automatically only when the change is normal. Anything
else is held for the owner, who reviews the summary and approves with one command.

Normal (auto-publish), all must hold:
- every list's rule count changed by less than 10% (threshold to be tuned)
- no list added or removed
- no `premium`, `group` or `enabledByDefault` flag changed
- no new download host in any `sourceURL`
- all Publisher validation passes

Held (owner approval): anything outside the above, plus any validation failure,
which is never publishable.

### Accepted risks once built

- Malware running as the owner on that Mac could sign manifests (it still cannot
  copy the key). Higher bar than a stolen CI secret, lower than manual signing.
- Updates stop while the Mac is off or offline; lists go stale but nothing breaks.

## Preconditions before building

1. iOS signature verification, rollback check and built-in minimum version shipped
   (`ManifestTrust.md`).
2. Algorithm decision made (see below), with both public keys pinned in the app.
3. Threshold values set from a few weeks of real upstream change data.

## Open decisions

1. **Algorithm, decide before the first TestFlight build.** The Secure Enclave
   supports P-256, not Ed25519 (the Publisher's current algorithm). Automation needs a
   Secure Enclave K1, so either switch K1 to P-256 now, or stay on Ed25519 and rotate
   to a P-256 key through K2 when automation is built (needs an app update with new
   pinned keys). Recommendation: switch now, while nothing has shipped.
2. **Premium update wording.** With manual publishing, PRD §5.1's "daily" premium
   updates is not guaranteed. Change it to "frequent updates" (and in marketing copy)
   unless the owner commits to daily manual publishes.
3. **Auto-publish vs approve-every-publish** once automation exists. Approving every
   publish with Touch ID is safer but needs the owner daily.
