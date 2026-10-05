#!/bin/bash
# Exercises release failure/retry paths using an isolated fake GitHub API. No network access.
# jq expressions passed through helpers intentionally contain literal dollar signs.
# shellcheck disable=SC2016
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-publication-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
ln -s "$repo_root/Tests/Release/mock-gh.sh" "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_REPO=test/repo GH_TOKEN=test-token
export FAKE_GH_ROOT="$work/fake"
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
passed=0

reset_case() {
    rm -rf "$FAKE_GH_ROOT"
    mkdir -p "$FAKE_GH_ROOT/assets"
    printf '{"releases":[],"refs":{},"objects":{},"next_id":1,"calls":[],"notes_requests":[],"deleted":[],"latest":null}\n' >"$FAKE_GH_ROOT/state.json"
}
set_state() {
    jq "$@" "$FAKE_GH_ROOT/state.json" >"$work/state.tmp"
    mv "$work/state.tmp" "$FAKE_GH_ROOT/state.json"
}
assert_state() {
    if ! jq -e "$1" "$FAKE_GH_ROOT/state.json" >/dev/null; then
        echo "FAIL: $2" >&2
        cat "$FAKE_GH_ROOT/state.json" >&2
        exit 1
    fi
    ((passed += 1))
}
build_assets() {
    tag="$1"
    dmg="$work/Amanuensis-${tag#v}-arm64.dmg"
    printf 'DMG for %s\n' "$tag" >"$dmg"
    printf 'Signature for %s\n' "$tag" >"$dmg.sig"
}
add_tag() {
    set_state --arg tag "$1" --arg commit "$commit" '.refs["refs/tags/" + $tag] = {type:"commit",sha:$commit}'
}
publish() {
    if ! "$repo_root/Scripts/publish-release.sh" "$tag" "$commit" "$dmg" >"$work/output" 2>&1; then
        cat "$work/output" >&2
        exit 1
    fi
}
reject() {
    if "$repo_root/Scripts/publish-release.sh" "$tag" "$commit" "$dmg" >"$work/output" 2>&1; then
        echo "FAIL: expected publication to fail ($*)" >&2
        exit 1
    fi
}

reset_case
build_assets v0.2.0-nightly.10
publish
assert_state '.releases | length == 1 and .[0].draft == false and .[0].prerelease == true and (.[0].assets | length == 2)' 'complete nightly is published'
assert_state '.refs["refs/tags/v0.2.0-nightly.10"].sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .latest == null' 'nightly uses exact SHA and does not become Latest'
# Retried builds can differ, but the already published download must never be replaced.
printf 'A later rebuild\n' >>"$dmg"
set_state '.calls = [] | (.releases[0].assets[].digest) = null'
publish
assert_state '[.calls[] | select(.[0] == "release" and (.[1] == "upload" or .[1] == "edit"))] | length == 0' 'published retry downloads and verifies original assets without replacing them'
set_state '.releases[0].assets[0].digest = "sha256:bad" | .calls = []'
reject 'corrupt existing asset'
assert_state '[.calls[] | select(.[0] == "release")] | length == 0' 'published corruption fails without mutation'

reset_case
build_assets v0.2.0-nightly.11
set_state '.fail = "upload_signature"'
reject 'partial upload'
assert_state '.releases | length == 1 and .[0].draft == true and (.[0].assets | length == 1)' 'partial upload leaves an unpublished draft'
printf 'New rebuild\n' >>"$dmg"
publish
assert_state '.releases | length == 1 and .[0].draft == false and (.[0].assets | length == 2)' 'retry replaces the draft pair and publishes once'

reset_case
build_assets v0.2.0-nightly.12
set_state '.corrupt = true'
reject 'wrong upload digest'
assert_state '.releases[0].draft == true' 'incorrect uploaded bytes stay a draft'
set_state 'del(.corrupt) | .fail = "publish"'
reject 'publication API failure'
assert_state '.releases[0].draft == true' 'failed final publication stays a draft'
publish
assert_state '.releases[0].draft == false' 'complete draft can resume publication'

reset_case
build_assets v0.2.0-nightly.15
set_state '.fail = "upload_signature"'
reject 'draft preparation'
set_state '.releases[0].body |= sub("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; "g") | .calls = []'
reject 'draft owned by another build'
assert_state '[.calls[] | select(.[0] == "release")] | length == 0' 'mismatched draft commit is never edited'

reset_case
build_assets v0.2.0-nightly.13
add_tag "$tag"
set_state '.refs["refs/tags/v0.2.0-nightly.13"].sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
reject 'wrong remote commit'
assert_state '.releases | length == 0' 'wrong existing tag never creates a release'
set_state '.refs["refs/tags/v0.2.0-nightly.13"] = {type:"tag",sha:"cccccccccccccccccccccccccccccccccccccccc"} | .objects["cccccccccccccccccccccccccccccccccccccccc"] = {type:"commit",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
publish
assert_state '.releases[0].draft == false' 'annotated tag resolves to the exact built commit'

reset_case
build_assets v0.2.0
reject 'manual tag absent'
assert_state '.releases == [] and .refs == {}' 'manual stable tags are never invented'
build_assets v0.2.0-nightly.20
publish
build_assets v0.2.0
add_tag "$tag"
publish
assert_state '.latest == "v0.2.0" and .releases[-1].prerelease == false and (.releases[-1].body | contains("Initial app")) and .notes_requests == []' 'first stable includes full history despite a preceding nightly'
build_assets v0.10.0
add_tag "$tag"
publish
assert_state '.latest == "v0.10.0" and .notes_requests[-1] == "v0.2.0"' 'stable version comparison uses numeric ordering and explicit previous stable'
build_assets v0.3.0
add_tag "$tag"
publish
assert_state '.latest == "v0.10.0" and .notes_requests[-1] == "v0.2.0"' 'late older stable preserves newest Latest and has the correct notes baseline'
build_assets v0.11.0-preview.1
add_tag "$tag"
publish
assert_state '.latest == "v0.10.0" and .releases[-1].prerelease == true' 'manual previews remain prereleases'
build_assets v0.11.0
add_tag "$tag"
set_state '.fail = "latest"'
reject 'Latest update failed after publishing'
assert_state '.releases[-1].draft == false and .latest == "v0.10.0"' 'Latest failure leaves complete published assets'
set_state '.calls = []'
publish
assert_state '.latest == "v0.11.0" and ([.calls[] | select(.[0] == "release" and .[1] == "upload")] | length == 0)' 'published retry repairs Latest without replacing assets'

reset_case
build_assets v0.3.0-nightly.1
# Out-of-order list with > 30 releases, cross-version sorting, and unrelated records.
set_state --arg commit "$commit" '
  .releases = ([range(1;34) | {id:(100 + .),tag_name:("v0.2.0-nightly." + tostring),draft:false,prerelease:true,
    body:("<!-- amanuensis-release " + ({schema:1,automatic_nightly:true,commit:$commit} | tojson) + " -->"),assets:[]}]
    | reverse)
  | .releases += [
    {id:201,tag_name:"v0.1.0",draft:false,prerelease:false,body:"stable",assets:[]},
    {id:202,tag_name:"v0.2.0-preview.1",draft:false,prerelease:true,body:"preview",assets:[]},
    {id:203,tag_name:"v0.1.0-nightly.999",draft:true,prerelease:true,body:.releases[0].body,assets:[]},
    {id:204,tag_name:"v0.1.0-nightly.1",draft:false,prerelease:true,body:"unmarked",assets:[]},
    {id:205,tag_name:"v0.1.0-nightly.1.extra",draft:false,prerelease:true,body:.releases[0].body,assets:[]}]
  | .refs = {"refs/tags/unrelated":{type:"commit",sha:$commit}}
  | .fail = "cleanup"'
reject 'cleanup failure after publication'
assert_state '.releases[-1].draft == false and .deleted == []' 'cleanup only starts after a successful publication'
set_state '.cleanup_race = true'
publish
assert_state '(.deleted | sort) == ["v0.2.0-nightly.1","v0.2.0-nightly.2","v0.2.0-nightly.3","v0.2.0-nightly.4"]' 'retention keeps the newest 30 by version rather than API order'
assert_state 'has("cleanup_race") == false' 'cleanup tolerates another publisher removing the same release'
assert_state '[.releases[] | select(.id >= 201 and .id <= 205)] | length == 5' 'cleanup preserves stable, manual previews, drafts and unmarked or unrelated releases'
assert_state '.refs["refs/tags/unrelated"].type == "commit"' 'cleanup preserves Git references'

reset_case
build_assets v0.2.0-nightly.14
set_state '.fail = "list"'
reject 'API list error'
assert_state '.releases == [] and ([.calls[] | select(.[0] == "release")] | length == 0)' 'API failures never masquerade as a missing release'

printf 'Release publication checks passed (%s assertions).\n' "$passed"
