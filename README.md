# zotero-plugin-ci

Shared GitHub Actions for the Zotero plugins in this account.

## Zotero release watch

`.github/workflows/zotero-release-watch.yml` records each new Zotero version on
one tracker issue per Zotero minor version series (`10.0`, `11.0`) in the repo
that calls it, and flags
the versions that exceed the plugin's `strict_max_version`. That ceiling fails silently in Zotero: the plugin
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
| `min-version` | `10.0.3` | Ignore Zotero versions at or below this. Stops the first run from recording all 49 tags since Zotero 7. Static: dedupe covers repetition, so it never needs bumping. |
| `manifest-path` | `addon/manifest.json` | Where `applications.zotero.strict_max_version` lives. |
| `dry-run` | `false` | Write what would be filed to the job summary and file nothing. |
| `smoke-test` | `true` | Build the plugin against each new Zotero and report the result on the issue. |

### Tracker issues

Each Zotero minor version series gets one issue, such as
`Zotero 11.0 releases (latest: ...)`, covering its stable and beta builds alike:
`11.0-beta.5` and a later `11.0.0` share a tracker, `11.1-beta.1` opens a new
one. A new build adds a comment describing
it, an entry in the issue body's build list, and a new title naming it. Closing
the tracker means "checked against the latest build"; the next build reopens it.

The tracker is found by a hidden `<!-- zotero-release-tracker series=X.Y -->`
marker in its body, since the title changes with every build. Each recorded
build carries a `<!-- zotero-release-version: X -->` marker in both its comment
and its body entry; those markers are the dedupe record. The body list is the
one that counts, because `gh issue list` returns a limited number of comments
per issue. Issues titled `Zotero X released`, from before trackers existed, also
count as recorded, so switching over re-files nothing.

### Labels

Created on first live run with `gh label create --force`, so no manual setup.
`zotero-release` marks every tracker. The other three describe the latest build
only, and are set or cleared each time one is recorded: `zotero-beta` for a beta
build, `zotero-breaking` when it is above the ceiling, `zotero-smoke-failed`
when the suite fails against it.

### Smoke test

The `smoke` job downloads each new Zotero, pins the plugin's test suite to it
through `ZOTERO_PLUGIN_ZOTERO_BIN_PATH`, runs `npm run test`, and comments the
result on the tracker the `watch` job just recorded the build on. That covers what the version
ceiling cannot: a patch release can break the plugin without crossing
`strict_max_version`.

It runs in the same workflow run that files the issue, and not as an
`on: issues` workflow in the plugin repo, because an issue opened with
`GITHUB_TOKEN` does not trigger further workflow runs.

The apt packages and the download/extract step mirror the pinned matrix in each
plugin's own `ci.yml`, including the explicit `DPkg::Lock::Timeout`: the
scaffold's own apt call has no timeout and hangs silently on a held dpkg lock.

Resolving a version's tarball is a probe rather than a format string, because of
two quirks. A `.0` patch release drops the trailing `.0` from the path, so tag
`10.0.0` lives at `/client/release/10.0/Zotero-10.0_linux-x86_64.tar.xz`. And
Zotero 7 ships `.tar.bz2` where 8 and up ship `.tar.xz`. Some tags have no
published build at all: `9.0.5` is tagged and returns 403 on every platform. The
build is still recorded on its tracker; only the smoke test is skipped.

### Where the versions come from

Stable versions come from `git ls-remote --tags` on `zotero/zotero`. Those tags
carry no `v` prefix, are plain `X.Y.Z` (occasionally four components, as in
`5.0.34.1`), and include no beta or rc tags after Zotero 3.0.

Betas therefore cannot come from tags. The job follows
`https://www.zotero.org/download/client/dl?channel=beta&platform=linux-x86_64`
with `curl -sIL`, which resolves to a path naming the current beta, for example
`10.0.3-beta.2+80bc5565e`. That reports the current beta only, never a history.
A beta is recorded solely when it is above the ceiling, which is the
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
beta), a pinned ceiling, a legacy `Zotero X released` title, a tracker whose build list
already holds a version, and a closed tracker (expect a reopen).

### Adding a third plugin

Copy the stub above into the new repo. Nothing here needs to change.
