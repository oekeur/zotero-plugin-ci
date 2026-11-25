#!/usr/bin/env bash
# Finds Zotero versions this repo has not recorded yet and records each on one
# tracker issue per Zotero minor version series (10.0, 11.0), flagging those the
# manifest's strict_max_version will not load.
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

# The Linux tarball for a version, or non-zero when none is published. Two quirks
# make this a probe rather than a format string: a ".0" patch release drops the
# trailing ".0" from the path (tag 10.0.0 lives at /release/10.0/Zotero-10.0_...)
# and Zotero 7 ships .tar.bz2 where 8 and up ship .tar.xz. Probing the candidates
# also means a future change in either quirk degrades to "no build found" rather
# than to a broken download.
build_url() {
  local version="$1" channel="$2" name ext url
  if [ "$channel" = "beta" ]; then
    printf '%s' "$BETA_EFFECTIVE"
    return 0
  fi
  for name in "$version" "${version%.0}"; do
    for ext in xz bz2; do
      url="https://download.zotero.org/client/release/${name}/Zotero-${name}_linux-x86_64.tar.${ext}"
      if curl -fsI -m 20 -o /dev/null "$url"; then printf '%s' "$url"; return 0; fi
    done
  done
  return 1
}

# Matrix rows for the smoke-test job, one JSON object per version actually filed.
matrix_rows=()
add_matrix_row() {
  local version="$1" channel="$2" issue="$3" url
  if ! url="$(build_url "$version" "$channel")"; then
    echo "no Linux build published for $version, skipping the smoke test" >&2
    return 0
  fi
  matrix_rows+=("$(jq -nc --arg v "$version" --arg c "$channel" --arg i "$issue" --arg u "$url" \
    '{version:$v, channel:$c, issue:$i, url:$u}')")
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
BETA_EFFECTIVE="$(curl -fsSIL -m 20 -o /dev/null -w '%{url_effective}' "$BETA_URL" || true)"
beta_effective="$BETA_EFFECTIVE"
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

# --- trackers ---------------------------------------------------------------
# One issue per Zotero minor version series (10.0, 11.0) collects every build of
# that series, stable and beta alike. The tracker is found by a marker in its
# body, not its title, because the title names the latest build and changes with
# each one. Each build is a comment plus a body entry, both carrying a version
# marker; those markers are the dedupe record.
#
# gh issue list is the REST list endpoint, so unlike search it has no index lag.
# --state all is load-bearing: a closed tracker still records what it has seen.

TRACKER_MARK="zotero-release-tracker series="
VERSION_MARK="zotero-release-version: "

issues_json="$(gh issue list --state all --label zotero-release --limit 500 \
  --json number,state,title,body,comments,labels)"

# Versions already recorded: markers in tracker comments, plus the titles of the
# one-issue-per-version issues filed before trackers existed, so the switch does
# not re-file those.
seen="$(jq -r --arg vm "$VERSION_MARK" '
  .[] | (.comments[].body, .body) | (. // "")
      | scan("<!-- " + $vm + "([^ ]+) -->") | .[0]' <<< "$issues_json")
$(jq -r '.[].title | capture("^Zotero (?<v>[^ ]+) released$") | .v' <<< "$issues_json")"

# Tracker number, state and labels per series, kept current as this run files.
declare -A tracker tracker_state tracker_labels tracker_body
while IFS=$'\t' read -r series number state labels; do
  [ -n "$series" ] || continue
  tracker[$series]="$number"; tracker_state[$series]="$state"; tracker_labels[$series]="$labels"
  tracker_body[$series]="$(jq -r --argjson n "$number" '.[] | select(.number == $n) | .body' <<< "$issues_json")"
done < <(jq -r --arg tm "$TRACKER_MARK" '
  sort_by(.number) | .[]
  | ([(.body // "") | capture("<!-- " + $tm + "(?<m>[0-9]+\\.[0-9]+) -->")?] | .[0].m) as $m
  | select($m != null)
  | [$m, .number, .state, ([.labels[].name] | join(","))] | @tsv' <<< "$issues_json")

has_label() { [[ ",$1," == *",$2,"* ]]; }

# Sets or clears one label on a tracker so it describes the latest build only.
set_label() {
  local series="$1" label="$2" want="$3" number="${tracker[$1]}"
  local current="${tracker_labels[$series]:-}"
  if [ "$want" = "true" ] && ! has_label "$current" "$label"; then
    gh issue edit "$number" --add-label "$label" > /dev/null
    tracker_labels[$series]="$current,$label"
  elif [ "$want" != "true" ] && has_label "$current" "$label"; then
    gh issue edit "$number" --remove-label "$label" > /dev/null
    tracker_labels[$series]="$(tr ',' '\n' <<< "$current" | grep -Fxv "$label" | paste -sd, -)"
  fi
}

# --- file -------------------------------------------------------------------

filed=0
for i in "${!versions[@]}"; do
  version="${versions[$i]}"
  channel="${channels[$i]}"
  prev_tag="${previous[$i]}"

  if printf '%s\n' "$seen" | grep -Fxq "$version"; then continue; fi

  base="${version%%-*}"
  major="${base%%.*}"
  series="$(cut -d. -f1-2 <<< "$base")"
  breaking=false; breaks_ceiling "$base" && breaking=true
  beta=false; [ "$channel" = "beta" ] && beta=true
  title="Zotero ${series} releases (latest: ${version})"

  note="$(mktemp)"
  printf '<!-- %s%s -->\n' "$VERSION_MARK" "$version" >> "$note"
  if [ "$breaking" = "false" ]; then
    printf '**Zotero %s** is out on the %s channel, within this plugin'\''s ceiling.\n\n' \
      "$version" "$channel" >> "$note"
  else
    printf '**Zotero %s** is out on the %s channel and **this plugin will not load on it**.\n\n' \
      "$version" "$channel" >> "$note"
    printf 'Zotero refuses it silently: no console error, no install failure, the plugin just does not appear. Raise `applications.zotero.strict_max_version` in `%s` once the version has been checked against it.\n\n' \
      "$MANIFEST_PATH" >> "$note"
  fi
  printf -- '- Current ceiling: `%s` (`%s`)\n' "$CEILING" "$MANIFEST_PATH" >> "$note"
  if [ "$channel" = "release" ]; then
    printf -- '- [Source tree at %s](https://github.com/zotero/zotero/tree/%s)\n' "$version" "$version" >> "$note"
    if [ -n "$prev_tag" ]; then
      printf -- '- [Changes since %s](https://github.com/zotero/zotero/compare/%s%s%s)\n' \
        "$prev_tag" "$prev_tag" "$COMPARE_SEP" "$version" >> "$note"
    fi
  fi

  issue=""
  if [ "$DRY_RUN" = "true" ]; then
    if [ -n "${tracker[$series]:-}" ]; then
      action="Would comment on #${tracker[$series]} (${tracker_state[$series]}) and retitle it"
    else
      action="Would open a tracker for Zotero ${series} and comment on it"
    fi
    { printf '### %s: %s\n\n' "$action" "$title"
      printf 'Breaking: `%s`, beta: `%s`\n\n' "$breaking" "$beta"
      cat "$note"
      printf '\n---\n\n'; } >> "$SUMMARY"
    if [ -z "${tracker[$series]:-}" ]; then tracker[$series]="new"; tracker_state[$series]="not yet filed"; fi
  else
    if [ -z "${tracker[$series]:-}" ]; then
      header="$(mktemp)"
      printf '<!-- %s%s -->\n' "$TRACKER_MARK" "$series" >> "$header"
      printf 'Tracks every Zotero %s build, stable and beta. Each new build is listed below and described in a comment, followed by its smoke-test result. The title names the latest build, and the labels describe that build only.\n\n' \
        "$series" >> "$header"
      printf 'Close this once the plugin is checked against the latest build. The next build reopens it.\n\n' >> "$header"
      printf '## Links\n\n' >> "$header"
      if dev_url="$(dev_page "$major")"; then
        printf -- '- [Zotero %s for Developers](%s)\n' "$major" "$dev_url" >> "$header"
      fi
      printf -- '- [Zotero changelog](https://www.zotero.org/support/changelog)\n\n' >> "$header"
      printf '## Builds\n\n' >> "$header"
      issue_url="$(gh issue create --title "$title" --body-file "$header" --label zotero-release)"
      echo "$issue_url"
      tracker[$series]="${issue_url##*/}"; tracker_state[$series]="OPEN"; tracker_labels[$series]="zotero-release"
      tracker_body[$series]="$(cat "$header")"
      rm -f "$header"
    elif [ "${tracker_state[$series]}" != "OPEN" ]; then
      gh issue reopen "${tracker[$series]}" > /dev/null
      tracker_state[$series]="OPEN"
    fi
    comment_url="$(gh issue comment "${tracker[$series]}" --body-file "$note")"
    echo "$comment_url"

    # The build list in the body is the dedupe record that does not depend on
    # how many comments gh issue list returns per issue.
    entry="- <!-- ${VERSION_MARK}${version} -->[${version}](${comment_url}) (${channel}"
    [ "$breaking" = "true" ] && entry="$entry, above the ceiling"
    tracker_body[$series]="${tracker_body[$series]}
${entry})"
    body="$(mktemp)"
    printf '%s\n' "${tracker_body[$series]}" > "$body"
    gh issue edit "${tracker[$series]}" --title "$title" --body-file "$body" > /dev/null
    rm -f "$body"
    set_label "$series" zotero-beta "$beta"
    set_label "$series" zotero-breaking "$breaking"
    # The smoke job re-adds this if the new build fails too.
    set_label "$series" zotero-smoke-failed false
    issue="${tracker[$series]}"
  fi
  rm -f "$note"
  add_matrix_row "$version" "$channel" "$issue"
  seen="$seen
$version"
  filed=$((filed + 1))
done

if [ "$filed" -eq 0 ]; then
  printf 'No new Zotero versions. Ceiling `%s`, baseline `%s`.\n' "$CEILING" "$MIN_VERSION" >> "$SUMMARY"
fi

# The smoke-test job fans out over this. Empty array when there is nothing new,
# which is what its `if:` guard tests.
matrix="$(printf '%s\n' "${matrix_rows[@]+"${matrix_rows[@]}"}" | jq -sc '.')"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'matrix=%s\n' "$matrix" >> "$GITHUB_OUTPUT"
fi
echo "candidates: $filed"
echo "smoke matrix: $matrix"
