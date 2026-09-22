#!/usr/bin/env bash
# Finds Zotero versions this repo has not filed an issue for yet and files one
# per version, flagging those the manifest's strict_max_version will not load.
#
# Environment:
#   MIN_VERSION    ignore stable tags at or below this
#   MANIFEST_PATH  manifest to read strict_max_version from
#   DRY_RUN        "true" writes to $GITHUB_STEP_SUMMARY instead of filing
#   GH_TOKEN       used by gh; the calling repo's token
set -euo pipefail

MIN_VERSION="${MIN_VERSION:?MIN_VERSION is required}"
MANIFEST_PATH="${MANIFEST_PATH:?MANIFEST_PATH is required}"
DRY_RUN="${DRY_RUN:-true}"
ZOTERO_REPO="${ZOTERO_REPO:-https://github.com/zotero/zotero}"
BETA_URL="https://www.zotero.org/download/client/dl?channel=beta&platform=linux-x86_64"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
COMPARE_SEP="..."

CEILING="$(jq -r '.applications.zotero.strict_max_version // empty' "$MANIFEST_PATH")"
[ -n "$CEILING" ] || { echo "no applications.zotero.strict_max_version in $MANIFEST_PATH" >&2; exit 1; }

# The highest version the ceiling still admits. "10.0.*" becomes 10.0.999999, a
# pinned "10.0.3" stays itself. Approximates Mozilla's toolkit comparator: enough
# to raise an alert, not enough to gate anything on.
CEILING_MAX="${CEILING//\*/999999}"

version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
breaks_ceiling() { version_gt "$1" "$CEILING_MAX"; }

dev_page() {
  local url="https://www.zotero.org/support/dev/zotero_${1}_for_developers"
  curl -fsSL -m 15 "$url" 2>/dev/null | grep -q '<title>Page not found' && return 1
  printf '%s' "$url"
}

# --- candidates -------------------------------------------------------------

stable_tags="$(git ls-remote --tags --refs "$ZOTERO_REPO" \
  | sed 's#.*refs/tags/##' \
  | grep -E '^[0-9]+(\.[0-9]+){1,3}$' \
  | sort -V)"

versions=(); channels=(); previous=()
prev=""
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  if version_gt "$tag" "$MIN_VERSION"; then
    versions+=("$tag"); channels+=("release"); previous+=("$prev")
  fi
  prev="$tag"
done <<< "$stable_tags"

# Betas are not tagged in git; the download redirect is the only machine-readable
# source. It reports the current beta only, which is fine here: a beta issue is
# filed solely when the beta breaks the ceiling, and that state persists across
# builds until the ceiling is raised.
beta_effective="$(curl -fsSIL -m 20 -o /dev/null -w '%{url_effective}' "$BETA_URL" || true)"
if [ -n "$beta_effective" ]; then
  beta_raw="${beta_effective##*/client/beta/}"; beta_raw="${beta_raw%%/*}"
  beta_version="${beta_raw//%2B/+}"; beta_version="${beta_version//%2b/+}"
  beta_base="${beta_version%%-*}"
  if [ -n "$beta_version" ] && breaks_ceiling "$beta_base"; then
    versions+=("$beta_version"); channels+=("beta"); previous+=("")
  else
    echo "beta $beta_version is within the $CEILING ceiling, skipping" >&2
  fi
else
  echo "warning: could not resolve the beta channel redirect" >&2
fi

# --- dedupe -----------------------------------------------------------------
# gh issue list is the REST list endpoint, so unlike search it has no index lag.
# --state all is load-bearing: a closed issue must not be re-filed.

existing="$(gh issue list --state all --limit 500 --json title -q '.[].title')"

# --- file -------------------------------------------------------------------

filed=0
for i in "${!versions[@]}"; do
  version="${versions[$i]}"
  channel="${channels[$i]}"
  prev_tag="${previous[$i]}"
  title="Zotero ${version} released"

  if printf '%s\n' "$existing" | grep -Fxq "$title"; then continue; fi

  base="${version%%-*}"
  major="${base%%.*}"
  labels="zotero-release"
  [ "$channel" = "beta" ] && labels="$labels,zotero-beta"

  body="$(mktemp)"
  if ! breaks_ceiling "$base"; then
    printf 'Zotero %s is out on the %s channel, within this plugin'\''s ceiling.\n\n' \
      "$version" "$channel" >> "$body"
  else
    labels="$labels,zotero-breaking"
    printf 'Zotero %s is out on the %s channel and **this plugin will not load on it**.\n\n' \
      "$version" "$channel" >> "$body"
    printf 'Zotero refuses it silently: no console error, no install failure, the plugin just does not appear. Raise `applications.zotero.strict_max_version` in `%s` once the version has been checked against it.\n\n' \
      "$MANIFEST_PATH" >> "$body"
  fi
  printf -- '- Current ceiling: `%s` (`%s`)\n' "$CEILING" "$MANIFEST_PATH" >> "$body"
  printf -- '- Channel: %s\n\n' "$channel" >> "$body"

  printf '## Links\n\n' >> "$body"
  if [ "$channel" = "release" ]; then
    printf -- '- [Source tree at %s](https://github.com/zotero/zotero/tree/%s)\n' "$version" "$version" >> "$body"
    if [ -n "$prev_tag" ]; then
      printf -- '- [Changes since %s](https://github.com/zotero/zotero/compare/%s%s%s)\n' \
        "$prev_tag" "$prev_tag" "$COMPARE_SEP" "$version" >> "$body"
    fi
  fi
  if dev_url="$(dev_page "$major")"; then
    printf -- '- [Zotero %s for Developers](%s)\n' "$major" "$dev_url" >> "$body"
  fi
  printf -- '- [Zotero changelog](https://www.zotero.org/support/changelog)\n' >> "$body"

  if [ "$DRY_RUN" = "true" ]; then
    { printf '### Would file: %s\n\n' "$title"
      printf 'Labels: `%s`\n\n' "$labels"
      cat "$body"
      printf '\n---\n\n'; } >> "$SUMMARY"
  else
    gh issue create --title "$title" --body-file "$body" --label "$labels"
  fi
  rm -f "$body"
  existing="$existing
$title"
  filed=$((filed + 1))
done

if [ "$filed" -eq 0 ]; then
  printf 'No new Zotero versions. Ceiling `%s`, baseline `%s`.\n' "$CEILING" "$MIN_VERSION" >> "$SUMMARY"
fi
echo "candidates: $filed"
