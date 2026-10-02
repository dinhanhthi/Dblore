# `/cf-ship` for Dblore: usage

How to release Dblore. This file is for **you**; `SKILL.md` next to it is
the contract the model follows (coding-friend applies its `## Before`,
`## Rules` and `## After` sections on top of the standard `/cf-ship`).

> `.gitignore` ignores `.coding-friend/*` but re-includes
> `!.coding-friend/skills/`, so this guide, `SKILL.md` and the scripts are
> version-controlled. Only `.coding-friend/config.json` stays local.

## What one release does

`/cf-ship` reads the app commits since the last published tag, picks a version,
writes `CHANGELOG.md`, bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
`Dblore.xcodeproj/project.pbxproj` (only when the file version changes),
runs build + tests + a lint of the changed Swift files, commits
`chore(release): bump to <tag version>` on the current branch, pushes, tags
`v<tag version>`, pushes the tag, then waits for CI and verifies the published
DMG and the Sparkle appcast.

Dblore ships stable releases only: the tag is always `v` +
`MARKETING_VERSION` (`X.Y.Z`), and the DMG is `Dblore-<version>.dmg`.

## Say it in one line

| You want                          | You say               | Latest tag -> file / tag                           |
| --------------------------------- | --------------------- | -------------------------------------------------- |
| A normal release, level auto      | `/cf-ship`            | `v0.1.0` -> `0.1.1` / `v0.1.1` (or minor)          |
| Force the level                   | `/cf-ship minor`      | `v0.1.0` -> `0.2.0` / `v0.2.0`                     |

Auto level: PATCH almost always, including ordinary new features (a setting, a
menu item, an export format). MINOR only for a milestone (a new database
engine, a new kind of document or tab), never twice in a row unless you ask
with `/cf-ship minor`. MAJOR only for breaking `.dblore` / config compatibility
(reserved while pre-1.0, so MINOR instead). Only commits touching `Dblore/`, `DbloreTests/`, the Xcode
project, `scripts/` or `assets/` count; docs, CI and `.coding-friend/` changes
never trigger a release.

`bump-info.sh` computes the version and prints `Next file version` and
`Next tag` under "Next version".

## What CI does

Pushing a `vX.Y.Z` tag starts `.github/workflows/release.yml` on a `macos-26` runner:

1. Selects the newest Xcode in `/Applications` with a macOS SDK >= 26.
2. Extracts the `## v<tag version>` section of `CHANGELOG.md` as release notes
   (fails if the file or the section is missing or empty).
3. Imports the Developer ID certificate into a temporary keychain.
4. Runs `scripts/build-release.sh --expect-version <tag version>`: checks the
   tag equals `MARKETING_VERSION`, then archive, export, sign, DMG,
   notarize, staple, Gatekeeper check.
5. Publishes `Dblore-<tag version>.dmg` and `.dmg.sha256`
   on GitHub Releases as a normal (latest) release.
6. Locates `generate_appcast` in the Sparkle SPM artifact the build resolved
   (checksum-verified by SPM, same version as the app).
7. Runs `generate_appcast` on the DMG plus the current `appcast.xml` from
   `main`, signing with the `SPARKLE_PRIVATE_KEY` secret (passed on stdin).
   The feed keeps the latest 3 versions (the `generate_appcast` default).
8. Commits the new `appcast.xml` to `main` as `github-actions[bot]`
   (`chore(release): appcast v<tag version>`; never counts toward a bump).
9. Dispatches `pages.yml`, which publishes `website/` and `appcast.xml` together to
   GitHub Pages (the feed stays at <https://dinhanhthi.github.io/Dblore/appcast.xml>).
10. Deletes the keychain, key files and the appcast work folder.

## Prerequisites

- The seven repository secrets listed in `docs/release-setup.md`
  (`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`,
  `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`,
  `SPARKLE_PRIVATE_KEY`). Check the names with `gh secret list`.
- A **public** repo: Sparkle and users cannot download release assets from a
  private one. The skill stops unless
  `gh api repos/dinhanhthi/Dblore --jq .visibility` prints `public`.
- GitHub Pages with Source = **GitHub Actions**
  (`gh api repos/dinhanhthi/Dblore/pages --jq .build_type` prints
  `workflow`). The skill stops otherwise.
- For the local fallback appcast: the Sparkle EdDSA key in your login keychain
  under the account `sqlnotebook`.
- For the local fallback only: the Developer ID certificate in your login
  keychain and the `DbloreNotary` notary profile
  (`xcrun notarytool store-credentials ...`, see `docs/release-setup.md`).
- A `CHANGELOG.md` at the repo root with a title and format note; the skill
  inserts each new version below it.
- `gh` authenticated, and the test DB container `dblore-postgres-test` up
  if you want the integration suite to run before the release.

## Troubleshooting

**"Tag already exists".** The skill stops. A published tag is never moved or
deleted. If the version was really released, bump again; if a tag was pushed
but CI failed, use the fallback below instead of retagging.

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

**CI fails at "Select Xcode with the macOS 26 SDK"** ("No Xcode with macOS SDK
>= 26 found"). The runner lacks Xcode 27. Release locally, as described in
"docs/release-setup.md > Fallback: release from a local machine":
`scripts/build-release.sh --expect-version <tag version>`, extract the changelog
section with the same awk, then `gh release create v<tag version>` with the DMG and
`.sha256`. The existing tag is reused.

**Notarization fails.** Read the step log (`gh run view <id> --log-failed`) and
the notary log it prints (`xcrun notarytool log <submission-id>`). Common causes:
a nested binary without hardened runtime or secure timestamp, or wrong
`NOTARY_*` secrets. Fix, then rebuild with the fallback; do not retag.

**Appcast not updated** (the feed lacks the new version). Check the
`pages.yml` run (`gh run list --workflow=pages.yml --limit 3`,
then `gh run view <id> --log-failed`) and that the Pages source is GitHub
Actions. If `release.yml` failed before "Commit appcast to main" (for example
`SPARKLE_PRIVATE_KEY` not set), the release exists but the feed does not: use
the fallback appcast steps in `SKILL.md` Rules; do not retag.

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
| `scripts/build-release.sh`      | (repo root) Archive, sign, DMG, notarize, staple. Used by CI and locally.            |
| `.github/workflows/release.yml` | Tag-triggered release: build, notarize, publish on GitHub Releases, update appcast.  |
| `.github/workflows/pages.yml`   | Publishes `website/` and `appcast.xml` to GitHub Pages. The site header reads the version from the published `appcast.xml`. |
| `appcast.xml`                   | (repo root) Sparkle feed. Owned by CI; never edit by hand.                           |
| `docs/release-setup.md`      | Secrets, local notary profile, local fallback.                                       |
