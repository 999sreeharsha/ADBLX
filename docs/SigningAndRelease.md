# ADBLX Signing & Release Reference

Nov 22, 2026 · @Harsha

## Overview

The SHIELD app only accepts a filter catalog (`manifest.json`) signed with one of your two keys. The first signed catalog went live on 21 November 2026.

- **Why:** the app downloads its filter lists from your GitHub Pages site. Without signing, anyone who took over the site could push bad rules to every user. With signing, the app ignores any catalog you didn't sign.
- **K1** is your everyday key. It lives inside the Mac mini's security chip, can't be copied, and asks for your Mac password each time it signs.
- **K2** is the spare key for emergencies. It lives only on two encrypted pen drives.
- **The public keys** of K1 and K2 are built into the app. They aren't secret.
- **Live catalog:** version `2026-11-21T17:20:57Z`, SHA-256 `8017d15ef6a1d132f500c98c344f74338ff82987d0220e71dbbd090063126d2a`.

## Where everything lives

Private keys never go into the project folder, git or GitHub. Public keys are meant to be shared.

| Item | Location | In git? |
| --- | --- | --- |
| K1 private key `adblx-manifest-k1.key` | `~/Keys` on the Mac mini | Never |
| K1 backup `adblx-manifest-k1.backup.key` | `~/Keys` on the Mac mini | Never |
| K1 copy | Both pen drives (works only on this Mac) | Never |
| K2 private key `adblx-manifest-k2.key` | Pen drives `ADBLX-K2-A` and `ADBLX-K2-B` only | Never |
| Public keys file `adblx-public-keys` | Documents, and both pen drives | No |
| Public keys inside the app | `ManifestTrust.swift` | Yes |
| Pen drive passwords | Password manager | Never |
| App code | `~/Work/ADBLX`, branch `dev`, pushed to GitHub `999sreeharsha/ADBLX` | Yes |
| Website (catalog + lists) | Branch `gh-pages`, folder `.gh-pages-worktree` | Yes |

**Public keys** (as pinned in the app):

- K1: `qxqESy6v3djL4Nh8RYL+Y0sb8Htav7t0kLd1e+C6pN0DldrCptoEi5VjZA6HhXujqP/KVNsFSFwJ6VeADEOUFw==`
- K2: `2PiVSmbkdA10tLgpXdNJx6IQw+0qlSKFm2rOLRFxbSQXZY3QA/oSkTMKgbW9raXuy3PzFF4wwSYKmowpUdSn8A==`

**K2 file check:** both drives hold an identical K2 file with SHA-256 `0208dbb69172f5685d190b718218aefded0679cd3156f7d34df8bbbac6e197e1`. Run `shasum -a 256` on it once a year to confirm.

## Publishing a new signed catalog

Run these yourself, at the Mac mini, screen unlocked, from `~/Work/ADBLX` on branch `dev`. Only you can run step 3, because it uses K1. Ignore the two "unhandled file" warnings the tool prints.

1. **Check the folder is clean:**

   ```
   cd ~/Work/ADBLX && git status
   ```

   It should say `On branch dev` and `nothing to commit`.
2. **Build the catalog** with a new version (date and time):

   ```
   swift run --package-path backend/tools/Publisher Publisher generate \
     --publish-base-url https://999sreeharsha.github.io/ADBLX \
     --manifest-version "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```
3. **Sign with K1.** A password box appears; enter your Mac login password.

   ```
   swift run --package-path backend/tools/Publisher Publisher sign --signing-key-file ~/Keys/adblx-manifest-k1.key
   ```

   Note the signature's file name (a long hex number ending in `.sig`).
4. **Verify** against both public keys. It must end with `✓ Signature verifies`.

   ```
   swift run --package-path backend/tools/Publisher Publisher verify \
     --public-key qxqESy6v3djL4Nh8RYL+Y0sb8Htav7t0kLd1e+C6pN0DldrCptoEi5VjZA6HhXujqP/KVNsFSFwJ6VeADEOUFw== \
     --public-key 2PiVSmbkdA10tLgpXdNJx6IQw+0qlSKFm2rOLRFxbSQXZY3QA/oSkTMKgbW9raXuy3PzFF4wwSYKmowpUdSn8A==
   ```
5. **Review the changes** with `git status` and `git diff backend/public/manifest.json`. Expect only `manifest.json`, the `signatures` folder, and possibly `FilterRegistry.md`. Anything else: stop and ask.
6. **Commit:**

   ```
   git add backend/public backend/docs && git commit -m "publish: signed manifest"
   ```
7. **Upload to the website:**

   ```
   backend/tools/publish-pages.sh
   ```
8. **Check the live site** after 2 to 5 minutes. The first line must match the signature name from step 3; the second must end in `200`.

   ```
   h=$(curl -s https://999sreeharsha.github.io/ADBLX/manifest.json | shasum -a 256 | cut -d' ' -f1); echo $h
   curl -sI https://999sreeharsha.github.io/ADBLX/signatures/$h.sig | head -1
   ```

   Still the old hash after 15 minutes: check GitHub → Actions for a failed run.
9. **Tell the Claude Code session it's live,** so it runs `Scripts/refresh-bundled-manifest.sh`, reruns the suites, commits and pushes `dev`.

## Recovery

Users are never cut off as long as K2 is safe. Losing both K1 and K2 is the only serious case: nothing could sign new catalogs until an app update with new keys.

| What happened | What to do |
| --- | --- |
| K1 file in `~/Keys` deleted | Copy `adblx-manifest-k1.backup.key` (or the copy on a pen drive) back to `~/Keys/adblx-manifest-k1.key`. |
| Mac mini lost, broken or replaced | 1. Sign catalogs with K2 from a pen drive (`--signing-key-file /Volumes/ADBLX-K2-A/adblx-manifest-k2.key`). 2. On the new Mac, create K3 with `keygen --secure-enclave`. 3. Ship an app update pinning K3 and K2. 4. Then sign with K3. |
| One pen drive fails | Copy K2 from the other drive to a new encrypted drive, and check both copies match with `shasum -a 256`. |
| Drive password forgotten | That drive's K2 copy is unusable. Use the other drive, and make a new second copy. |
| Signing says the key can't be used | Unlock the Mac's screen and try again; the chip refuses while the screen is locked. |

Plug the pen drives into the Mac only for recovery or the yearly check, never for routine work.

### If you lose the keys

First decide whether a key is **lost** (gone, nobody else has it) or **stolen** (someone else may have it). A lost key only needs replacing; a stolen one must also stop being trusted, through an app update.

| Situation | Risk to users | What to do |
| --- | --- | --- |
| K1 lost (both K1 files deleted, Mac wiped or dead) | None. Updates continue with K2. | 1. Sign every catalog with K2 from a pen drive until step 3 ships. 2. Create K3: `keygen --secure-enclave --output ~/Keys/adblx-manifest-k3.key`, copy it to both drives, save its public key in `adblx-public-keys`. 3. Give the session the K3 public key: pin K3 and K2, remove K1, ship an app update. 4. Sign with K3 from then on. |
| Mac stolen, or someone may know your Mac password | Someone at that Mac could sign with K1. | Same steps as "K1 lost", urgently. Change your Mac and Apple ID passwords. Until the update ships, check the live catalog's hash daily (publishing step 8) against what you published. |
| One pen drive lost | Low: the drive is encrypted, and useless without its password. | Make a new encrypted drive from the other one and check the hashes match. With a weak drive password, treat it as "K2 stolen". |
| K2 stolen (drive and its password) | Someone could sign catalogs with K2. | 1. Create a new spare, K3, on two new drives (plain `keygen`). 2. Give the session the K3 public key: pin K1 and K3, remove K2, ship an app update. 3. Destroy the old K2 drives you still have. |
| Both pen drives lost, K1 fine | None today, but no spare. | Create a new spare (K3) on two new drives right away, then ship an app update pinning K1 and K3. |
| K1 **and** K2 both lost | Nothing can sign. Installed apps keep their current filter lists but get no new ones. | 1. Create K3 (Secure Enclave) and K4 (pen drives). 2. Ship an app update pinning K3 and K4. 3. Publish with K3. Only users who update get new filter lists again. |

**What never helps:** making a new key without an app update. The app trusts only the public keys built into it, so a new key works only after an update ships with its public key.

**Pinning new keys:** paste the new public key into the Claude Code session and ask it to replace the old key in `ManifestTrust.swift`, update the archive check, run all suites and commit on `dev`. Then archive and submit the update.

## Routine maintenance

The next deadline is Dec 21, 2026: refresh the bundled catalog before any archive after that date, or the archive fails its 30-day check.

| When | Task |
| --- | --- |
| Before every archive | Run `Scripts/refresh-bundled-manifest.sh` and the live-network tests. |
| Every catalog update | The publishing steps above. |
| Once a year | Plug in each pen drive, check it opens and its K2 hash matches. |
| On any compiler change | Bump `CompiledSources.currentCompilerVersion` (the fingerprint test reminds you). |

## Repository and workflow rules

All work happens on `dev`; the only other branches are `main` (old, left alone) and `gh-pages` (the website).

- **Branches:** a session may make a short-lived branch, then merges it into `dev` and deletes it. No worktrees except `.gh-pages-worktree`.
- **One session at a time** works in the repository. If several run at once, only one merges into `dev`, after telling the others.
- **Each session uses its own simulator,** passed by UDID to every test command.
- **CI is off:** it runs only when started by hand from GitHub → Actions, because Mac runner minutes cost money on a private repository. Pushing `dev` starts nothing.
- **Release checks run when you archive in Xcode:** pinned keys, bundled catalog age, report address, no DNS in Release, matching extension versions, and background modes. A failing check stops the archive.
- **Live-network tests** (real site, real DNS) run only on demand, with `TEST_RUNNER_ADBLX_LIVE_NETWORK=1`.
- **Plans are reviewed before they're built,** and code changes are tested first.
- **DNS Protection** stays out of every release and TestFlight build until its connectivity and payments issue is solved.

## App Store Connect settings decided

| Setting | Choice | Notes |
| --- | --- | --- |
| Billing Grace Period | On: 16 days, paid-to-paid renewals only, sandbox and production | The app, web extension and tunnel all keep premium until the grace end. |
| Family Sharing | Off at launch | Can be turned on later; as far as known, not turned off once on. |

## Still open before TestFlight

All remaining blockers are your decisions or device checks; signing is done.

- [ ] **Brand name and domain.** Then: the report email address, the privacy policy URL, and moving the catalog address in an app release before the site moves.
- [ ] **Trial decision (PD-01):** App Store free trial (needs a payment method, closes SEC-16 and the 3.1.1 review risk) or keep the Keychain trial.
- [ ] **Prices:** PRD and `.storekit` say $1.99 / $14.99 / $39.99; `AppStoreSetup.md` says $19.99 annual / $49.99 lifetime. Check PD-01 and the rupee prices, then pick one.
- [x] **Security scan Area 5** (background-updates staging code): done 2026-11-22, no findings. One bug note (a list that later becomes premium stays installed for a non-entitled user) is open for review in `docs/Security/Findings.md`.
- [ ] **iPhone 14 checks:**
  - background-update timing runs (Wi-Fi, Jio, Airtel, Low Power Mode, compile)
  - near-full disk: does Safari keep its rules after a failed reload
  - extension memory (SEC-02) and the Allocations trace during an update
  - one click per YouTube ad skip (SEC-08)
  - broken-site report opens in a mail app, including Gmail-only
  - day-long Energy Log check
  - G1 blocking re-measurement
- [ ] **DNS session:** 4G re-run and payment flows, on a new simulator.

## Saved messages to paste later

**When you restart the DNS session:**

> Your simulator `adblx-dns` (`12E7EFE3-AB17-4AC9-BC84-E62A2CE69F99`) no longer exists, and neither does any other simulator except `adblx-billing-grace`. Nobody here deleted it. Create a new one for the 4G re-run with `xcrun simctl create "adblx-dns" <device type> <runtime>`, copying the device type and runtime from an existing iPhone in `xcrun simctl list devices -j`. Note its UDID and pass it as `-destination "platform=iOS Simulator,id=<UDID>"` to every test command. Also: work only on short-lived branches merged into `dev`; never commit to `dev` while another session is merging.

**Before handing the repository to a session after you've worked in it:**

> I'm done in the repository; it's yours again. Check `git status` is clean on `dev` before starting.
