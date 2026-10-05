#!/bin/bash
# Publishes a previously verified DMG/signature pair. Only drafts may replace assets.
# Usage: GH_REPO=owner/repo GH_TOKEN=... Scripts/publish-release.sh TAG COMMIT_SHA DMG
set -euo pipefail

fail() {
    echo "Release publication: $*" >&2
    exit 1
}
[[ $# == 3 ]] || fail "expected TAG COMMIT_SHA DMG"
: "${GH_REPO:?GH_REPO is required}" "${GH_TOKEN:?GH_TOKEN is required}"
tag="$1"
commit="$2"
dmg="$3"
version_pattern='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
[[ "$tag" =~ ^v$version_pattern(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || fail "invalid release tag: $tag"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "expected a full commit SHA"
[[ -s "$dmg" && -s "$dmg.sig" ]] || fail "DMG and adjacent .sig must both be nonempty"
asset_name="$(basename "$dmg")"
[[ "$asset_name" == "Amanuensis-${tag#v}-arm64.dmg" ]] || fail "DMG filename must match $tag"
prerelease=false
nightly=false
[[ "$tag" != *-* ]] || prerelease=true
[[ ! "$tag" =~ ^v$version_pattern-nightly\.(0|[1-9][0-9]*)$ ]] || nightly=true
work="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-publish.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Compare numeric identifiers as length/string pairs, without floating-point limits.
stable_filter='def stable_key: ltrimstr("v") | split(".") | map([length, .]);
  map(select(.draft == false and .prerelease == false
    and (.tag_name | test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))))
  | sort_by(.tag_name | stable_key)'
manifest_filter='(.body // "") | capture("<!-- amanuensis-release (?<json>[^\\n]+) -->").json | fromjson'

list_releases() {
    gh api --paginate --slurp "repos/$GH_REPO/releases?per_page=100" | jq 'add // []' >"$work/releases.json"
}

# A release target can be a branch name; only the actual remote tag proves its commit.
verify_tag() {
    local object depth=0
    object="$(gh api "repos/$GH_REPO/git/ref/tags/$tag" | jq -c '.object')"
    while [[ "$(jq -r '.type' <<<"$object")" == tag ]]; do
        ((depth += 1))
        [[ $depth -le 10 ]] || fail "annotated tag chain is too deep"
        object="$(gh api "repos/$GH_REPO/git/tags/$(jq -r '.sha' <<<"$object")" | jq -c '.object')"
    done
    [[ "$(jq -r '.type' <<<"$object")" == commit && "$(jq -r '.sha' <<<"$object")" == "$commit" ]] \
        || fail "$tag does not point to the built commit $commit; refusing to move it"
}

tag_ref="$(gh api "repos/$GH_REPO/git/matching-refs/tags/$tag" | jq -c --arg ref "refs/tags/$tag" '[.[] | select(.ref == $ref)]')"
if [[ "$(jq 'length' <<<"$tag_ref")" == 0 ]]; then
    [[ "$nightly" == true ]] || fail "push the manual release tag before publishing"
    gh api --method POST "repos/$GH_REPO/git/refs" -f "ref=refs/tags/$tag" -f "sha=$commit" >/dev/null
fi
verify_tag
list_releases
release="$(jq -c --arg tag "$tag" '[.[] | select(.tag_name == $tag)] | if length > 1 then error("duplicate releases") else .[0] end' "$work/releases.json")"

read_release() {
    release="$(gh api "repos/$GH_REPO/releases/$release_id")"
}

# GitHub computes each uploaded digest. Older assets without one are downloaded and hashed.
verify_assets() {
    local manifest asset expected digest asset_id
    manifest="$(jq -ce "$manifest_filter" <<<"$release")" || fail "release has no publication manifest"
    jq -e --arg commit "$commit" --arg name "$asset_name" --argjson nightly "$nightly" \
        '.schema == 1 and .commit == $commit and .dmg == $name and .automatic_nightly == $nightly' \
        <<<"$manifest" >/dev/null || fail "release manifest does not match this build"
    [[ "$(jq -r '.prerelease' <<<"$release")" == "$prerelease" ]] || fail "release channel does not match its tag"
    [[ "$(jq '.assets | length' <<<"$release")" == 2 ]] || fail "release must contain exactly the DMG and its signature"
    for asset in "$asset_name" "$asset_name.sig"; do
        expected="$(jq -er --arg name "$asset" '.sha256[$name] | select(test("^[0-9a-f]{64}$"))' <<<"$manifest")"
        digest="$(jq -er --arg name "$asset" '[.assets[] | select(.name == $name and .state == "uploaded" and .size > 0)]
            | if length == 1 then (.[0].digest // "download") else error("missing or incomplete asset") end' <<<"$release")"
        if [[ "$digest" == download ]]; then
            asset_id="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .id' <<<"$release")"
            gh api -H 'Accept: application/octet-stream' "repos/$GH_REPO/releases/assets/$asset_id" >"$work/asset"
            digest="sha256:$(shasum -a 256 "$work/asset" | cut -d ' ' -f 1)"
        fi
        [[ "$digest" == "sha256:$expected" ]] || fail "uploaded asset digest mismatch: $asset"
    done
}

if [[ "$release" != null ]]; then
    release_id="$(jq -r '.id' <<<"$release")"
    # Existing drafts must also belong to this publisher and exact source commit.
    jq -e --arg commit "$commit" "($manifest_filter) | .schema == 1 and .commit == \$commit" \
        <<<"$release" >/dev/null || fail "existing release belongs to a different build or publisher"
fi

if [[ "$release" == null || "$(jq -r '.draft' <<<"$release")" == true ]]; then
    manifest="$(jq -cn --arg commit "$commit" --arg name "$asset_name" --argjson nightly "$nightly" \
        --arg dmg_sha "$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)" \
        --arg sig_sha "$(shasum -a 256 "$dmg.sig" | cut -d ' ' -f 1)" \
        '{schema:1, commit:$commit, dmg:$name, automatic_nightly:$nightly,
          sha256:{($name):$dmg_sha, ($name + ".sig"):$sig_sha}}')"
    notes_args=(--method POST "repos/$GH_REPO/releases/generate-notes" -f "tag_name=$tag" -f "target_commitish=$commit")
    previous="$(jq -r --arg tag "${tag%%-*}" "$stable_filter | map(select((.tag_name | stable_key) < (\$tag | stable_key))) | last | .tag_name // empty" "$work/releases.json")"
    [[ -z "$previous" ]] || notes_args+=(-f "previous_tag_name=$previous")
    if [[ -n "$previous" ]]; then
        gh api "${notes_args[@]}" | jq -r '.body' >"$work/generated-notes"
    else
        # Omitting previous_tag_name lets GitHub choose a nightly even for the first stable.
        gh api --paginate --slurp "repos/$GH_REPO/commits?sha=$commit&per_page=100" \
            | jq -r '"Changes in this release:\n", (.[][] | "- \(.commit.message | split("\n")[0]) ([\(.sha[0:7])](\(.html_url)))")' \
                >"$work/generated-notes"
    fi
    {
        printf 'Requires Apple Silicon and macOS 26 or later.\n\n'
        printf 'Download the DMG to install. The .sig file lets Amanuensis verify automatic updates.\n\n'
        printf 'This build is ad-hoc signed and is not Apple-notarized. macOS may require approval in System Settings > Privacy & Security.\n\n'
        [[ "$nightly" != true ]] || printf 'Automatic nightly from main. Select Preview in Settings > Updates to receive nightlies.\n\n'
        printf 'Source commit: [%s](https://github.com/%s/commit/%s).\n\n' "$commit" "$GH_REPO" "$commit"
        cat "$work/generated-notes"
        printf '\n<!-- amanuensis-release %s -->\n' "$manifest"
    } >"$work/notes"
    title="Amanuensis ${tag#v}"
    [[ "$nightly" != true ]] || title="$title ($(date -u +%F))"
    if [[ "$release" == null ]]; then
        gh release create "$tag" --verify-tag --target "$commit" --draft --latest=false \
            "--prerelease=$prerelease" --title "$title" --notes-file "$work/notes"
        list_releases
        release_id="$(jq -er --arg tag "$tag" '.[] | select(.tag_name == $tag and .draft == true) | .id' "$work/releases.json")"
    else
        gh release edit "$tag" --draft=true "--prerelease=$prerelease" --title "$title" --notes-file "$work/notes"
    fi
    # A retry can rebuild different bytes. Replacing both draft assets keeps the pair together.
    gh release upload "$tag" "$dmg" "$dmg.sig" --clobber
    read_release
    [[ "$(jq -r '.draft' <<<"$release")" == true ]] || fail "release was published concurrently"
    verify_assets
    verify_tag
    gh release edit "$tag" --draft=false "--prerelease=$prerelease" --latest=false
    read_release
fi
[[ "$(jq -r '.draft' <<<"$release")" == false ]] || fail "release is still a draft"
verify_tag
verify_assets

# Every stable publisher reconciles Latest, including retries and late older releases.
if [[ "$prerelease" == false ]]; then
    latest_set=false
    for ((attempt = 0; attempt < 5; attempt++)); do
        list_releases
        newest="$(jq -r "$stable_filter | last | .tag_name" "$work/releases.json")"
        gh release edit "$newest" --latest
        list_releases
        if [[ "$newest" == "$(jq -r "$stable_filter | last | .tag_name" "$work/releases.json")" ]]; then
            latest_set=true
            break
        fi
    done
    [[ "$latest_set" == true ]] || fail "published successfully, but Latest changed repeatedly; rerun to reconcile"
fi

release_url="https://github.com/$GH_REPO/releases/tag/$tag"
printf 'Published %s\n' "$release_url"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Release\n\n[%s](%s)\n' "$tag" "$release_url" >>"$GITHUB_STEP_SUMMARY"
fi

# Preserve manual previews, unmarked releases and drafts. Keep tags for reproducible history.
# Removing release records alone also makes retries safe after partial cleanup failures.
if [[ "$nightly" == true ]]; then
    list_releases
    jq -r "map(select(.draft == false and .prerelease == true
        and (.tag_name | test(\"^v(0|[1-9][0-9]*)\\\\.(0|[1-9][0-9]*)\\\\.(0|[1-9][0-9]*)-nightly\\\\.(0|[1-9][0-9]*)$\"))
        and (try (($manifest_filter) | .schema == 1 and .automatic_nightly == true) catch false)))
      | sort_by(.tag_name | ltrimstr(\"v\") | split(\"-nightly.\") | (.[0] | split(\".\")) + [.[1]] | map([length, .]))
      | reverse | .[30:][] | .id" "$work/releases.json" >"$work/expired"
    while IFS= read -r expired_id; do
        if ! gh api --method DELETE "repos/$GH_REPO/releases/$expired_id" 2>"$work/cleanup-error"; then
            # Another main build may have removed the same expired release concurrently.
            if [[ "$(cat "$work/cleanup-error")" != *"(HTTP 404)"* ]]; then
                cat "$work/cleanup-error" >&2
                fail "published successfully, but nightly cleanup failed; rerun this job to retry cleanup"
            fi
        fi
    done <"$work/expired"
fi
