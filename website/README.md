# Dblore website

Static site (HTML + CSS + a little vanilla JS, no build step) for https://dblore.dinhanhthi.com.

## Preview

```sh
python3 -m http.server -d website 8080
```

Open http://localhost:8080.

## Structure

- `index.html`: landing page. `docs.html`: documentation. `privacy.html`: privacy statement. `features.html`: searchable feature catalog.
- `features-data.js`: fixed feature IDs, descriptions, first available versions and internal source/release evidence. `features.js`: table sorting, fuzzy search and issue links. `features.test.js`: Node built-in tests (`node --test website/features.test.js`).
- `tokens.css`: design tokens (OKLCH colors, Geist fonts, spacing). `styles.css`: layout and components.
- `site.js`: theme toggle (the saved theme is applied by an inline script in each `<head>`).
- The app version in each page header (`.version-badge`) is read at runtime from the same-origin `appcast.xml` (highest build number) by `site.js`; the static `v0.4.0` in each page is only a fallback for no-JS, local preview or fetch failure, so no hand edit is needed on release.
- `logo.png`, `poster.jpg`, `screenshots/`: images (screenshots are copied from `assets/screenshots/`). `CNAME`: custom domain. `.nojekyll`: disables Jekyll.

## Feature catalog maintenance

`features-data.js` lists concrete user-visible capabilities, including gestures, keyboard shortcuts and menu actions, beyond the README highlights. English descriptions should state engine or safety constraints where relevant. Provenance fields are internal and are not shown in the table.

- Keep each existing numeric ID unchanged. Add a new capability with the next highest ID; sorting never changes IDs.
- Check app source and git history for the completed behavior. Use the first actual release tag containing it (`git tag --contains <commit> --sort=version:refname`) and inspect the implementation at that tag (`git show <tag>:<path>`). Historical releases before the app rename use `SQLNotebook/` paths.
- Set `version` to `Unreleased` while no release tag contains the completed behavior. During release preparation, promote shipped `Unreleased` entries to the target `MARKETING_VERSION` while preserving their IDs; CI creates the matching tag after the release commit. Retain the completed behavior commit as evidence and confirm the tag once it is published. Use `Unknown` only when evidence is insufficient, explaining why in `evidence`.
- Keep `sources` pointing to existing app files and retain the introducing commit plus tagged-source evidence. Check gestures and constraints against source rather than inferring them from release notes. For example, double-clicking replayable history inserts SQL; use View Detail to inspect it.
- Run `node --test website/features.test.js` and `node --check website/features-data.js` after editing the catalog. Review the new row on the page with sorting and search.

## Deploy

`.github/workflows/pages.yml` uploads this folder to GitHub Pages. It also publishes `appcast.xml` from the repo root, which Sparkle auto-update needs: do not remove it.

One-time setup:

1. Settings > Pages > Source = "GitHub Actions".
2. DNS: add a `CNAME` record `dblore` pointing to `dinhanhthi.github.io`.
3. Settings > Pages: set the custom domain to `dblore.dinhanhthi.com` and enable "Enforce HTTPS".
