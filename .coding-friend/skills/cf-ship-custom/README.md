# `/cf-ship` for Dblore: usage

How to release Dblore. This file is for **you**; `SKILL.md` next to it is
the contract the model follows (coding-friend applies its `## Before`,
`## Rules` and `## After` sections on top of the standard `/cf-ship`).

> `.gitignore` ignores `.coding-friend/*` but re-includes
> `!.coding-friend/skills/`, so this guide, `SKILL.md` and the scripts are
> version-controlled. Only `.coding-friend/config.json` stays local.

## What one release does

`/cf-ship` reads the app commits since the last published tag, picks a version,
writes `CHANGELOG.md`, updates the website Feature list from app-source changes, updates
the user docs (`website/docs.html`, and README / landing page for headline features) when
the release adds something worth documenting, bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
`Dblore.xcodeproj/project.pbxproj` (only when the file version changes),
runs build + tests + a lint of the changed Swift files, commits
`chore(release): bump to <tag version>` on `main` and pushes. Then it runs
`scripts/release-local.sh` on this Mac, which builds, signs and notarizes,
creates the tag, publishes the DMG and pushes the Sparkle appcast. Only the
cheap `pages.yml` deploy runs on GitHub (triggered by the appcast push).
Finally the skill verifies the published artifacts.

On a new Mac, do the one-time setup in `docs/release-setup.md` first.

Dblore ships stable releases only: the tag is always `v` +
`MARKETING_VERSION` (`X.Y.Z`), and the DMG is `Dblore-<version>.dmg`.

## Feature list updates

Every app release audits the net source changes for user-visible capabilities, including gestures, shortcuts, settings and menu actions, then updates `website/features-data.js`. New capabilities receive new IDs; existing IDs and historical first versions stay fixed. Shipping `Unreleased` rows are promoted to the exact release version, while backfilled older features use their verified first release. Fixes and reverted additions do not create rows.

Catalog tests and JavaScript syntax checks run before the release commit; the catalog is staged with the changelog and version file. The published tag is checked afterward, and the release report includes added/promoted counts. Retries preserve IDs and avoid duplicate rows. `--dry-run` reports proposed updates without changing files or publishing anything; website-only changes still stop with "nothing to release".

## Say it in one line

| You want                          | You say                   | Latest tag -> file / tag                           |
| --------------------------------- | ------------------------- | -------------------------------------------------- |
| A normal release, level auto      | `/cf-ship`                | `v0.1.0` -> `0.1.1` / `v0.1.1` (or minor)          |
| Force the level                   | `/cf-ship minor`          | `v0.1.0` -> `0.2.0` / `v0.2.0`                     |

Auto level: PATCH almost always, including ordinary new features (a setting, a
menu item, an export format). MINOR only for a milestone (a new database
engine, a new kind of document or tab), never twice in a row unless you ask
with `/cf-ship minor`. MAJOR only for breaking `.dblore` / config compatibility
(reserved while pre-1.0, so MINOR instead). Only commits touching `Dblore/`, `DbloreTests/`, the Xcode
project, `scripts/` or `assets/` count; docs, CI and `.coding-friend/` changes
never trigger a release.

`bump-info.sh` computes the version and prints `Next file version` and
`Next tag` under "Next version".

## What the local release does

`scripts/release-local.sh --expect-version <tag version>` (`--dry-run` runs
the preflight only):

1. Preflight, machine checks first: Xcode matches `.xcode-version`, the
   Developer ID certificate is in the keychain, the `DbloreNotary` notary
   profile (or `NOTARY_KEY_PATH` / `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` env)
   works, the Sparkle key (account `sqlnotebook`) exists, `gh` is authenticated.
2. Then repo checks: on `main`, clean tree, `HEAD` == `origin/main`, the tag is
   absent locally and on origin, `MARKETING_VERSION` equals the version, and
   `CHANGELOG.md` has a non-empty `## v<tag version>` section (the release notes).
3. Runs `scripts/build-release.sh --expect-version <tag version>`: archive,
   sign, DMG, notarize, staple (about 20 minutes).
4. Re-checks that `HEAD` and the tree did not change during the build.
5. Runs `generate_appcast` (only from `DerivedData/Dblore-*`) on a temp copy of
   `appcast.xml` plus the DMG, signing with the keychain key, and checks the new
   item and its EdDSA signature. Approve the Keychain prompt with "Always Allow".
6. Only then creates the annotated tag `v<tag version>` on the release SHA and
   pushes it.
7. `gh release create` with `Dblore-<tag version>.dmg`, its `.dmg.sha256` and
   the changelog section as notes.
8. Commits `chore(release): appcast v<tag version>` and pushes `main`; that
   push triggers `pages.yml` (nothing is dispatched).

A failure before step 6 publishes nothing. The feed keeps the latest 3 versions
(the `generate_appcast` default) at <https://dinhanhthi.github.io/Dblore/appcast.xml>.

## Prerequisites

On this Mac (how to set each one up, or recover it on a new Mac:
`docs/release-setup.md`):

- The Developer ID Application certificate in your login keychain.
- The `DbloreNotary` notary profile, created once (placeholders; see
  `docs/release-setup.md`):

  ```bash
  xcrun notarytool store-credentials DbloreNotary --key docs/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER_ID>
  ```

- The Sparkle EdDSA key in your login keychain under the account `sqlnotebook`.
- The selected Xcode matching `.xcode-version`.
- `gh` authenticated.

On GitHub and in the repo:

- A **public** repo: Sparkle and users cannot download release assets from a
  private one. The skill stops unless
  `gh api repos/dinhanhthi/Dblore --jq .visibility` prints `public`.
- GitHub Pages with Source = **GitHub Actions**
  (`gh api repos/dinhanhthi/Dblore/pages --jq .build_type` prints
  `workflow`). The skill stops otherwise.
- A `CHANGELOG.md` at the repo root with a title and format note; the skill
  inserts each new version below it.
- Optional: the test DB container `dblore-postgres-test` up if you want the
  integration suite to run before the release.

## Troubleshooting

**"Tag already exists".** The skill stops. A published tag is never moved or
deleted. Check whether its release finished; if it did, bump again. If a prior
run failed after creating the tag, use the post-tag recovery in
`docs/release-setup.md`.

**`State: BROKEN-tag-ahead-of-file`.** A tag is newer than `MARKETING_VERSION`,
meaning something was tagged without bumping. The skill stops; decide by hand
whether the tag or the project version is wrong.

**`HAS APP CHANGES: no`.** Only docs/CI/tooling changed since the last tag.
Nothing to release.

**"MARKETING_VERSION ... is not X.Y.Z".** The project file holds something
other than a plain version. Set it to `X.Y.Z`.

**Lint findings.** The release lints (`swift-format lint --strict`, no
rewrite) only the Swift files changed since the last tag and stops on any
finding. Fix them in a normal commit, then release again.

**"notary profile DbloreNotary not found".** The local preflight stops before
building. Create the profile once with the `xcrun notarytool store-credentials`
command under Prerequisites (or `docs/release-setup.md`), then release again.

**Local release fails before the tag push** (preflight, build, notarization,
appcast). Nothing was published. Fix the cause, commit and push if source
changes, then rerun `/cf-ship` (or `scripts/release-local.sh`).

**Local release failed after the tag push** (`gh release create` or the
appcast push). Never move or delete the tag, and do not rerun the script (its
preflight stops on the existing tag). Publish only what is missing: the
command the script printed, or the recovery steps in `docs/release-setup.md`.

**Notarization fails.** Read the script output and the notary log it prints
(`xcrun notarytool log <submission-id>`). Common causes: a nested binary
without hardened runtime or secure timestamp, or wrong notary profile
credentials. If it failed before tag creation, fix the cause and
rerun the release; see `docs/release-setup.md` for post-tag recovery.

**Appcast not updated** (the feed lacks the new version). Check the
`pages.yml` run (`gh run list --workflow=pages.yml --limit 3`,
then `gh run view <id> --log-failed`) and that the Pages source is GitHub
Actions. If `release-local.sh` failed after `gh release create`, the release exists but
the feed does not: use the recovery steps in `docs/release-setup.md`; do not
retag.

**Update not offered in the app.** Sparkle compares `sparkle:version`
(`CURRENT_PROJECT_VERSION`), not the marketing version. If the build number did
not increase over the last published one, installed apps see no update. Bump
again with a higher build number; never edit a published appcast item by hand.

**Gatekeeper warns on the downloaded DMG.** Check it yourself:

```bash
spctl -a -vv -t install "/Volumes/Dblore/Dblore.app"   # want: Notarized Developer ID
xcrun stapler validate "/Volumes/Dblore/Dblore.app"
```

## Testing the scripts without releasing anything

Env hooks exercise every branch without touching the real project file or
creating a tag. Never set them during a real release; bump-info labels its
output `TEST MODE` when they are on.

```bash
B=.coding-friend/skills/cf-ship-custom/scripts/bump-info.sh

BUMP_INFO_TAG=v0.1.0 BUMP_INFO_VERSION=0.1.0 bash $B                # bump: patch 0.1.1
BUMP_INFO_TAG=v0.1.0 BUMP_INFO_VERSION=0.1.1 bash $B                # already-bumped
BUMP_INFO_TAG=v0.2.0 BUMP_INFO_VERSION=0.1.0 bash $B                # BROKEN-tag-ahead-of-file
BUMP_INFO_TAG= bash $B                                              # first release
BUMP_INFO_TAG=v0.1.1-rc.1 BUMP_INFO_VERSION=0.1.1 bash $B           # suffix tag ignored: first release
BUMP_INFO_TAG= BUMP_INFO_VERSION=0.1.1-rc.1 bash $B                 # error: file must be X.Y.Z
BUMP_INFO_TAG=v0.1.0 BUMP_INFO_VERSION=0.1.0 bash $B --rc           # error: unknown argument

# bump.sh on a copy of the project file
cp Dblore.xcodeproj/project.pbxproj /tmp/copy.pbxproj
BUMP_PBXPROJ=/tmp/copy.pbxproj bash .coding-friend/skills/cf-ship-custom/scripts/bump.sh 0.2.0
```

## Files

| Path                            | Role                                                                                 |
| ------------------------------- | ------------------------------------------------------------------------------------ |
| `SKILL.md`                      | The contract the model follows (loaded by coding-friend's `load-custom-guide.sh`).   |
| `scripts/bump-info.sh`          | Reads tags and commits, names the state, computes next file version + tag. Writes nothing. |
| `scripts/bump.sh`               | Writes the version and build number into the Xcode project and verifies them.        |
| `scripts/build-release.sh`      | (repo root) Archive, sign, DMG, notarize, staple. Called by `release-local.sh`.      |
| `scripts/release-local.sh`      | (repo root) The release on this Mac: preflight, build, signed appcast, then tag, GitHub release, appcast push. |
| `.github/workflows/ci.yml`      | Unit tests on pull requests (and by hand). Not part of the release.                  |
| `.github/workflows/pages.yml`   | Publishes `website/` and `appcast.xml` to GitHub Pages (triggered by the appcast push). The site header reads the version from the published `appcast.xml`. |
| `appcast.xml`                   | (repo root) Sparkle feed. Owned by `release-local.sh`; never edit by hand.           |
| `docs/release-setup.md`         | (local only) New-Mac setup, credential recovery, post-tag recovery.                  |
