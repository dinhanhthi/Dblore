# `/cf-ship` for SQLNotebook: usage

How to release SQLNotebook. This file is for **you**; `SKILL.md` next to it is
the contract the model follows (coding-friend applies its `## Before`,
`## Rules` and `## After` sections on top of the standard `/cf-ship`).

> `.gitignore` ignores `.coding-friend/*` but re-includes
> `!.coding-friend/skills/`, so this guide, `SKILL.md` and the scripts are
> version-controlled. Only `.coding-friend/config.json` stays local.

## What one release does

`/cf-ship` reads the app commits since the last published tag, picks a version,
writes `CHANGELOG.md`, bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
`SQLNoteBook.xcodeproj/project.pbxproj`, runs build + tests + format check,
commits `chore(release): bump to <version>` on the current branch, pushes, tags
`v<version>`, pushes the tag, then waits for CI and verifies the published DMG.

## Say it in one line

**Releases are stable by default.** A prerelease only happens if you ask.

| You want                          | You say               | Version goes                      |
| --------------------------------- | --------------------- | --------------------------------- |
| A normal release, level auto      | `/cf-ship`            | `0.1.0` -> `0.1.1` (or minor)     |
| Force the level                   | `/cf-ship minor`      | `0.1.0` -> `0.2.0`                |
| A release candidate               | `/cf-ship --rc`       | `0.1.0` -> `0.1.1-rc.1`           |
| Another candidate after a fix     | `/cf-ship --rc`       | `0.1.1-rc.1` -> `0.1.1-rc.2`      |
| **Promote the candidate**         | `/cf-ship`            | `0.1.1-rc.2` -> **`0.1.1`**       |
| A beta                            | `/cf-ship --beta`     | `0.1.0` -> `0.1.1-beta.1`         |
| A candidate for a bigger release  | `/cf-ship minor --rc` | `0.1.0` -> `0.2.0-rc.1`           |

Auto level: PATCH by default, MINOR when new capability dominates, MAJOR only
for breaking `.sqlnb` / config compatibility (reserved while pre-1.0, so MINOR
instead). Only commits touching `SQLNotebook/`, `SQLNotebookTests/`, the Xcode
project, `scripts/` or `assets/` count; docs, CI and `.coding-friend/` changes
never trigger a release.

**Promotion:** when the current version ends in `-rc.N` or `-beta.N`, `/cf-ship`
with no flag drops the suffix (`0.1.1-rc.2` -> `0.1.1`, not `0.1.2`).
`bump-info.sh` computes this and prints it under "Next version".

## What CI does

Pushing a `v*` tag starts `.github/workflows/release.yml` on a `macos-26` runner:

1. Selects the newest Xcode in `/Applications` with a macOS SDK >= 26.
2. Extracts the `## v<version>` section of `CHANGELOG.md` as release notes
   (fails if the file or the section is missing or empty).
3. Imports the Developer ID certificate into a temporary keychain.
4. Runs `scripts/build-release.sh --expect-version <version>`: archive, export,
   sign, DMG, notarize, staple, Gatekeeper check.
5. Publishes `SQLNotebook-<version>.dmg` and `SQLNotebook-<version>.dmg.sha256`
   on GitHub Releases. A tag containing `-rc` or `-beta` becomes a
   **prerelease**; anything else is a normal (latest) release.
6. Deletes the keychain and key files.

## Prerequisites

- The six repository secrets listed in `docs/release-setup.md`
  (`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`,
  `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`). Check with
  `gh secret list`.
- For the local fallback only: the Developer ID certificate in your login
  keychain and the `SQLNotebookNotary` notary profile
  (`xcrun notarytool store-credentials ...`, see `docs/release-setup.md`).
- A `CHANGELOG.md` at the repo root with a title and format note; the skill
  inserts each new version below it.
- `gh` authenticated, and the test DB container `sqlnotebook-postgres-test` up
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

**CI fails at "Select Xcode with the macOS 26 SDK"** ("No Xcode with macOS SDK
>= 26 found"). The runner lacks Xcode 27. Release locally, as described in
"docs/release-setup.md > Fallback: release from a local machine":
`scripts/build-release.sh --expect-version <version>`, extract the changelog
section with the same awk, then `gh release create v<version>` with the DMG and
`.sha256` (add `--prerelease` for `-rc` / `-beta`). The existing tag is reused.

**Notarization fails.** Read the step log (`gh run view <id> --log-failed`) and
the notary log it prints (`xcrun notarytool log <submission-id>`). Common causes:
a nested binary without hardened runtime or secure timestamp, or wrong
`NOTARY_*` secrets. Fix, then rebuild with the fallback; do not retag.

**Prerelease version rejected.** Apple expects `CFBundleShortVersionString` to
be three integers, so `0.2.0-rc.1` may fail at archive, notarization or
Gatekeeper. Try the first `--rc` release early, before depending on prereleases.

**Gatekeeper warns on the downloaded DMG.** Check it yourself:

```bash
spctl -a -vv -t install "/Volumes/SQLNotebook/SQLNotebook.app"   # want: Notarized Developer ID
xcrun stapler validate "/Volumes/SQLNotebook/SQLNotebook.app"
```

## Testing the scripts without releasing anything

Env hooks exercise every branch without touching the real project file or
creating a tag. Never set them during a real release; bump-info labels its
output `TEST MODE` when they are on.

```bash
B=.coding-friend/skills/cf-ship-custom/scripts/bump-info.sh

BUMP_INFO_TAG=v0.1.1-rc.2 BUMP_INFO_VERSION=0.1.1-rc.2 bash $B        # promote
BUMP_INFO_TAG=v0.1.1-rc.2 BUMP_INFO_VERSION=0.1.1-rc.2 bash $B --rc   # next rc
BUMP_INFO_TAG=v0.1.1-rc.2 BUMP_INFO_VERSION=0.1.1-rc.2 bash $B --beta # refused
BUMP_INFO_TAG= bash $B                                                # first release

# bump.sh on a copy of the project file
cp SQLNoteBook.xcodeproj/project.pbxproj /tmp/copy.pbxproj
BUMP_PBXPROJ=/tmp/copy.pbxproj bash .coding-friend/skills/cf-ship-custom/scripts/bump.sh 0.2.0
```

## Files

| Path                            | Role                                                                                 |
| ------------------------------- | ------------------------------------------------------------------------------------ |
| `SKILL.md`                      | The contract the model follows (loaded by coding-friend's `load-custom-guide.sh`).   |
| `scripts/bump-info.sh`          | Reads tags and commits, names the state, computes the next version. Writes nothing.  |
| `scripts/bump.sh`               | Writes the version and build number into the Xcode project and verifies them.        |
| `scripts/build-release.sh`      | (repo root) Archive, sign, DMG, notarize, staple. Used by CI and locally.            |
| `.github/workflows/release.yml` | Tag-triggered release: build, notarize, publish on GitHub Releases.                  |
| `docs/release-setup.md`      | Secrets, local notary profile, local fallback.                                       |
