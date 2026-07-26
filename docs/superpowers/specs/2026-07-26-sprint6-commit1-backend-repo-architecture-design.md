# Sprint 6 — Commit 1: Backend Repository Architecture

## Goal

Define the architecture of the ADBLX Filter Distribution Backend.

This backend is not an API server. Its sole responsibility is to distribute
trusted filter updates to ADBLX clients.

At the end of this commit there is no code — only a frozen repository
structure and ownership model.

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

`adblx-backend` — a separate repository from the ADBLX iOS app.

Reasons:

- Independent release cycle.
- Independent version history.
- Can be maintained without touching iOS.
- Future automation doesn't affect the app repository.

## Branch Strategy

Single `main` branch for v1. No `develop` branch, no release branches. Every
change to `main` represents the currently published backend.

If automation is introduced later, `main` + `release/*` can be added.

## Repository Layout (frozen)

```text
adblx-backend/
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

## Directory Ownership

### `public/`

The sole publish boundary. Only the contents of `public/` are ever exposed to
clients. Everything outside `public/` is internal to the repository and never
served.

If hosting later moves from GitHub to Cloudflare R2, GitHub Pages, or another
static host, the deployment step becomes: publish the contents of `public/`.

### `public/manifest.json`

The one public contract. The app downloads this first; everything else
starts here.

### `public/filters/`

The actual downloadable filter files, organized by **ADBLX FilterGroup**
(`ads/`, `privacy/`, `annoyances/`, `regional/`), not by upstream provider.

This mirrors the client's compilation model — the app compiles by
`FilterGroup`, so the backend reflects that same grouping.

### `docs/`

Human documentation only (backend architecture, publishing guide,
onboarding). Never consumed by the app.

### `metadata/`

Not downloaded directly by clients. Contains information used to generate
the manifest (versions, checksums, statistics). Kept flat and organized by
**upstream filter identity** (e.g. `versions.json`, `checksums.json`,
`statistics.json` describing sources like EasyList, EasyPrivacy), not by
ADBLX FilterGroup — a single upstream source can feed multiple groups, so
grouping metadata by ADBLX group would create false coupling.

### `licenses/`

License text for every upstream filter list (e.g. `EasyList.txt`,
`EasyPrivacy.txt`), kept flat and organized by upstream identity for the same
reason as `metadata/`. Keeps attribution separate from filter content.

### `tools/`

Utility scripts (future: checksum generation, manifest generation,
validation). No automation exists in Commit 1.

### `README.md`

Required to exist. Content is deferred — final manifest schema, publishing
workflow, and release process aren't decided yet, so writing an outline now
would likely be rewritten after Sprint 6 completes.

## Ownership Model

```
Upstream Filter Lists
        │
        ▼
adblx-backend
        │
        ▼
manifest.json
        │
        ▼
ADBLX App
```

The backend owns distribution. The app owns compilation. Neither owns
upstream filters.

## Versioning

Repository/manifest version and app version evolve independently. Example:
ADBLX App `2.0.0` can download Manifest `2026-08-01`. There is no coupling
between the two version schemes.

## Distribution Contract

The app downloads from a publicly accessible HTTPS endpoint. The hosting
technology is an implementation detail, not part of the repository
architecture — it may change without affecting the client, as long as the
endpoint remains a public HTTPS URL serving the contents of `public/`.

Non-normative note: GitHub Raw URLs are the planned initial implementation
target for Sprint 6, to be specified in a later commit. This is an
operational choice, not an architectural commitment.

## Release Philosophy

The backend is data, not software. Changing `easylist.txt` does not require
an App Store release. That is the entire purpose of this repository.

## Non-goals

This repository will never contain:

- iOS source code
- Swift packages
- Xcode project
- User accounts
- Databases
- APIs
- Analytics
- Receipts
- Subscription logic

Those belong elsewhere.

## Explicitly Deferred (out of scope for Commit 1)

- Repository's own LICENSE (distinct from `licenses/`, which holds upstream
  filter licenses). This is a product/legal decision — depends on whether the
  backend is public or private, whether contributions are desired, and how
  the app itself is licensed — not an architectural one. Noted as a TODO for
  a later commit.
- `README.md` content/outline.
- Manifest schema.
- Update workflow.
- GitHub Actions / automation.
- Filter sources.
- Compilation.
- Signing.

## Acceptance Criteria

- Repository name frozen as `adblx-backend`.
- Single `main` branch strategy adopted.
- Repository structure frozen as specified above.
- Directory ownership documented for every top-level directory.
- Backend/app ownership boundaries documented.
- Distribution contract (public HTTPS endpoint, hosting-agnostic) documented.
- No implementation or automation introduced.
