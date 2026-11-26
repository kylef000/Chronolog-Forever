# Releasing

Pushing a tag like `v1.2.0` runs `.github/workflows/release.yml`, which:

1. takes the release notes from the tag's section in `CHANGELOG.md`, and
   **fails if there isn't one**,
2. builds `Chronolog-Forever-v1.2.0.zip` (with `## Version` stamped from the tag),
3. creates or updates the GitHub release with that zip and those notes,
4. uploads the same zip and notes to CurseForge, once that's configured (below).

CurseForge is currently fed by its own **automatic packager** instead: a
GitHub webhook (`https://www.curseforge.com/api/projects/{projectID}/package?token={token}`)
makes CurseForge build its own package on every tag push, using `.pkgmeta`
(folder name `Chronolog-Forever`, `CHANGELOG.md` as the changelog, `tests/`
left out; dot-files are skipped automatically). Add any new non-addon path to
its `ignore` list. Don't also set the `CF_*` secrets below, or each tag would
be uploaded to CurseForge twice.

## Writing the changelog entry

Add a section at the top of `CHANGELOG.md` **before** tagging:

```markdown
## v1.5.0 - 2026-12-01

### New
- **Feature name**: one line on what it does for the player.

### Changed
- ...

### Fixed
- **What was wrong**: what the player saw, and that it's fixed.
```

Between releases, collect entries under `## Unreleased`; when tagging, rename
that heading to `## vX.Y.Z - YYYY-MM-DD` and bump `## Version` in the `.toc`.

Keep it short and written for players: what's new or different in game, not
how it was built. Use `### New`, `### Changed`, `### Fixed` and, if needed,
`### Notes`. Leave out sections that would be empty.

Tags containing `alpha` or `beta` (e.g. `v1.3.0-beta1`) upload to CurseForge
as alpha/beta files.

```bash
git tag v1.2.0
git push forever v1.2.0
```

## One-time CurseForge setup

1. **Create the project** on CurseForge (World of Warcraft → Create project) and
   note its **Project ID** (shown on the project's About section).
2. **API token**: CurseForge → *My account* → *API tokens* → generate one.
3. **Game version ID** for WoW Forever. List them with your token:

   ```bash
   curl -s -H "X-Api-Token: YOUR_TOKEN" https://wow.curseforge.com/api/game/versions
   ```

   Find the entry for the current WoW Forever client and copy its `id`. (If it
   isn't listed there, ask CurseForge support which ID Forever files should use.)
4. In the GitHub repo → *Settings* → *Secrets and variables* → *Actions*:
   - secret `CF_API_KEY` = the token
   - variable `CF_PROJECT_ID` = the project ID
   - variable `CF_GAME_VERSIONS` = the game version ID (comma-separate several)

Until all three are set, the CurseForge step is skipped and only the GitHub
release is made.

## Before tagging

1. Add the `CHANGELOG.md` section for the new version (see above) and commit it.
2. Run the tests:

   ```bash
   python tests/harness.py
   python tests/harness.py eui
   ```

   Both should print `ALL PASSED`.
