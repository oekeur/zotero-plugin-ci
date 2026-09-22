# zotero-plugin-ci

Shared GitHub Actions for the Zotero plugins in this account.

## Zotero release watch

`.github/workflows/zotero-release-watch.yml` opens one issue per new Zotero
version in the repo that calls it, and flags the versions that exceed the
plugin's `strict_max_version`. That ceiling fails silently in Zotero: the plugin
does not appear under Tools -> Plugins, with no console error and no install
failure, so nothing else tells you a new Zotero broke it.

### Using it

Add `.github/workflows/zotero-watch.yml` to the plugin repo:

```yaml
name: Zotero release watch

on:
  schedule:
    - cron: "0 6 * * *"
  workflow_dispatch:
    inputs:
      dry-run:
        description: Report to the job summary instead of filing issues
        type: boolean
        default: true

permissions:
  contents: read
  issues: write

jobs:
  watch:
    uses: oekeur/zotero-plugin-ci/.github/workflows/zotero-release-watch.yml@main
    with:
      dry-run: ${{ inputs.dry-run == true }}
```

`permissions` belongs in the caller: a reusable workflow can narrow the caller's
token but never widen it. No PAT and no secrets, since the job runs as the
calling repo's `GITHUB_TOKEN`.

Pin the `uses:` line to `@main`. The job checks its own script out at `main`, so
pinning the caller to a tag would mix a pinned workflow with a moving script.

### Inputs

| input | default | purpose |
|---|---|---|
| `min-version` | `10.0.3` | Ignore Zotero versions at or below this. Stops the first run from filing an issue for all 49 tags since Zotero 7. Static: dedupe covers repetition, so it never needs bumping. |
| `manifest-path` | `addon/manifest.json` | Where `applications.zotero.strict_max_version` lives. |
| `dry-run` | `false` | Write what would be filed to the job summary and file nothing. |

### Labels

Created on first live run with `gh label create --force`, so no manual setup:
`zotero-release` on every issue, `zotero-beta` on beta builds,
`zotero-breaking` when the version is above the ceiling.

### Where the versions come from

Stable versions come from `git ls-remote --tags` on `zotero/zotero`. Those tags
carry no `v` prefix, are plain `X.Y.Z` (occasionally four components, as in
`5.0.34.1`), and include no beta or rc tags after Zotero 3.0.

Betas therefore cannot come from tags. The job follows
`https://www.zotero.org/download/client/dl?channel=beta&platform=linux-x86_64`
with `curl -sIL`, which resolves to a path naming the current beta, for example
`10.0.3-beta.2+80bc5565e`. That reports the current beta only, never a history.
An issue is filed for a beta solely when it is above the ceiling, which is the
advance warning worth having and holds until the ceiling is raised. Routine
`10.0.4-beta.N` builds are ignored.

### Ceiling check

`strict_max_version` is turned into the highest version it admits by replacing
`*` with a large number: `10.0.*` becomes `10.0.999999`, a pinned `10.0.3` stays
itself. A version above that is flagged breaking. Two consequences: `10.1.0`
breaks a `10.0.*` ceiling exactly as `11.0.0` does, and a ceiling with no `*`
flags every later patch. This approximates Mozilla's toolkit version comparator
closely enough to raise an alert and not closely enough to gate anything on.

### Testing a change to the script

`scripts/zotero-release-watch.sh` reads its configuration from the environment
and takes no arguments, so it runs outside Actions with `gh` stubbed on `PATH`
and `DRY_RUN=true`. Cover at least: a baseline equal to the current release
(expect nothing), a baseline below it (expect the intervening versions, none
breaking), a lowered ceiling (expect the same versions all breaking, plus the
beta), a pinned ceiling, and a pre-seeded issue title for dedupe.

### Adding a third plugin

Copy the stub above into the new repo. Nothing here needs to change.
