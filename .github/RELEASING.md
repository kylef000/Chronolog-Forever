# Releasing

Pushing a tag like `v1.2.0` runs `.github/workflows/release.yml`, which:

1. builds `Chronolog-Forever-v1.2.0.zip` (with `## Version` stamped from the tag),
2. creates or updates the GitHub release with it,
3. uploads the same zip to CurseForge, once that's configured (below).

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

```bash
python tests/harness.py
python tests/harness.py eui
```

Both should print `ALL PASSED`.
