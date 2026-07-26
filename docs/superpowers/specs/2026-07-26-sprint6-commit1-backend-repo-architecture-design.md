# Sprint 6 — Commit 1: Backend Repository Architecture

## Goal

Define the architecture of the ADBLX Filter Distribution Backend.

This backend is not an API server. Its sole responsibility is to distribute
trusted filter updates to ADBLX clients.

At the end of this commit there is no code — only a frozen directory
structure and ownership model, added to the existing ADBLX repository.

## Scope

This commit answers only:

- Where does everything live?
- Who owns each file?
- What is committed to Git?
- What is generated?
- What is published?

It deliberately does not answer:

- Manifest schema
- Update workflow
- GitHub Actions
- Filter sources
- Compilation
- Signing

Those are later commits.

## Repository

**Revision note:** the original draft of this spec proposed a separate
`adblx-backend` repository. That decision was reversed before implementation
— see "Why a monorepo, not a separate repository" below. The backend lives
inside the existing `ADBLX` repository, under a top-level `backend/`
directory.

### Why a monorepo, not a separate repository

For a solo developer, a second repository adds process overhead (separate
clone, issue tracker, PR flow, release history) without a matching benefit
today. The backend is static distribution data, not a running application,
and it will evolve in lockstep with the iOS client for the foreseeable
future — e.g. a manifest schema change and the Swift client code that parses
it belong in the same commit and the same PR review, which a two-repo split
would force apart.

Splitting later is a low-cost move (extracting `backend/` into its own repo
via `git subtree`/`git filter-repo` preserves history) specifically because
this design keeps the backend fully self-contained under one top-level
directory now — nothing outside `backend/` will ever need to reach into it,
and nothing inside `backend/` will depend on iOS app internals.

Split into a dedicated `adblx-backend` repository if any of the following
becomes true:

- The backend gets its own CI/CD pipeline, independent of the app's.
- Multiple people work on backend distribution independently of the iOS app.
- Hosting moves to a system (e.g. Cloudflare R2) with its own deploy cadence
  that no longer maps cleanly to app repository commits.
- The backend becomes shared infrastructure for other clients (Android,
  Windows, etc.), not just ADBLX for iOS.

None of these are true today, so Commit 1 adopts the monorepo layout.

## Branch Strategy

No new branch strategy is introduced. `backend/` follows the existing ADBLX
repository's branching model (currently `main`/`dev`). There is no separate
release cycle for backend content in Commit 1 — a future commit may
introduce path-scoped automation (e.g. a GitHub Action that only triggers on
`backend/public/**` changes) without requiring a branch strategy change.

## Repository Layout (frozen)

```text
ADBLX/                      # existing iOS app repository root
├── ADBLX/                  # existing iOS app source
├── ADBLXAdsBlocker/        # existing extension target(s)
├── docs/                   # existing app-level docs
├── project.yml             # existing XcodeGen config
├── ...                     # existing app repository contents, unchanged
│
└── backend/
    ├── README.md
    ├── docs/
    ├── metadata/
    ├── licenses/
    ├── tools/
    └── public/
        ├── manifest.json
        └── filters/
            ├── ads/
            ├── privacy/
            ├── annoyances/
            └── regional/
```

`backend/` is a self-contained module: a reviewer or tool can treat it as an
independent unit without needing to understand the rest of the ADBLX
repository, and nothing under `backend/` references iOS app code or targets.

## Directory Ownership

### `backend/public/`

The sole publish boundary. Only the contents of `backend/public/` are ever
exposed to clients. Everything else under `backend/` (and everything outside
`backend/` entirely) is repository-internal and never served.

If hosting later moves from GitHub to Cloudflare R2, GitHub Pages, or another
static host, the deployment step becomes: publish the contents of
`backend/public/`.

### `backend/public/manifest.json`

The one public contract. The app downloads this first; everything else
starts here.

### `backend/public/filters/`

The actual downloadable filter files, organized by **ADBLX FilterGroup**
(`ads/`, `privacy/`, `annoyances/`, `regional/`), not by upstream provider.

This mirrors the client's compilation model — the app compiles by
`FilterGroup`, so the backend reflects that same grouping.

### `backend/docs/`

Human documentation only (backend architecture, publishing guide,
onboarding). Never consumed by the app.

### `backend/metadata/`

Not downloaded directly by clients. Contains information used to generate
the manifest (versions, checksums, statistics). Kept flat and organized by
**upstream filter identity** (e.g. `versions.json`, `checksums.json`,
`statistics.json` describing sources like EasyList, EasyPrivacy), not by
ADBLX FilterGroup — a single upstream source can feed multiple groups, so
grouping metadata by ADBLX group would create false coupling.

### `backend/licenses/`

License text for every upstream filter list (e.g. `EasyList.txt`,
`EasyPrivacy.txt`), kept flat and organized by upstream identity for the same
reason as `metadata/`. Keeps attribution separate from filter content.

### `backend/tools/`

Utility scripts (future: checksum generation, manifest generation,
validation). No automation exists in Commit 1.

### `backend/README.md`

Required to exist. Content is deferred — final manifest schema, publishing
workflow, and release process aren't decided yet, so writing an outline now
would likely be rewritten after Sprint 6 completes.

## Ownership Model

```
Upstream Filter Lists
        │
        ▼
ADBLX repo: backend/
        │
        ▼
backend/public/manifest.json
        │
        ▼
ADBLX App
```

`backend/` owns distribution. The app (the rest of the ADBLX repository)
owns compilation. Neither owns upstream filters. Despite living in the same
repository, `backend/` and the iOS app remain logically separate concerns —
this directory boundary is the enforcement mechanism in place of a
repository boundary.

## Versioning

Manifest version and app version evolve independently. Example: ADBLX App
`2.0.0` can download Manifest `2026-08-01`. There is no coupling between the
two version schemes, and no coupling to the ADBLX repository's own commit
history or tags either — the manifest is versioned on its own terms.

## Distribution Contract

The app downloads from a publicly accessible HTTPS endpoint. The hosting
technology is an implementation detail, not part of this architecture — it
may change without affecting the client, as long as the endpoint remains a
public HTTPS URL serving the contents of `backend/public/`.

Non-normative note: GitHub Raw URLs against this same repository are the
planned initial implementation target for Sprint 6, to be specified in a
later commit. This is an operational choice, not an architectural
commitment.

## Release Philosophy

The backend is data, not software. Changing `easylist.txt` does not require
an App Store release. That is the entire purpose of this directory
structure, monorepo or not.

## Non-goals

`backend/` will never contain:

- User accounts
- Databases
- APIs
- Analytics
- Receipts
- Subscription logic

Those belong elsewhere, if they ever exist at all.

## Explicitly Deferred (out of scope for Commit 1)

- `backend/README.md` content/outline.
- Manifest schema.
- Update workflow.
- GitHub Actions / automation (including any path-scoped triggers on
  `backend/public/**`).
- Filter sources.
- Compilation.
- Signing.
- Whether/when to extract `backend/` into a separate `adblx-backend`
  repository (see "Why a monorepo, not a separate repository").

## Acceptance Criteria

- Backend lives under `backend/` in the existing ADBLX repository — no new
  repository created.
- No new branch strategy introduced; `backend/` follows the app's existing
  branching model.
- `backend/` directory structure frozen as specified above.
- Directory ownership documented for every directory under `backend/`.
- Backend/app ownership boundaries documented (directory-level, not
  repository-level).
- Distribution contract (public HTTPS endpoint, hosting-agnostic) documented.
- Conditions for a future repository split documented.
- No implementation or automation introduced.
