#!/bin/bash
# Stateful GitHub CLI double. Unknown operations fail; this never invokes the real gh.
# jq expressions passed through helpers intentionally contain literal dollar signs.
# shellcheck disable=SC2016
set -euo pipefail
: "${FAKE_GH_ROOT:?}" "${GH_REPO:?}" "${GH_TOKEN:?}"
[[ "$GH_REPO" == test/repo && "$GH_TOKEN" == test-token ]] || exit 90
state="$FAKE_GH_ROOT/state.json"
args=("$@")
write_state() {
    jq "$@" "$state" >"$state.tmp"
    mv "$state.tmp" "$state"
}
write_state --argjson args "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '.calls += [$args]'
fail_once() {
    if [[ "$(jq -r '.fail // empty' "$state")" == "$1" ]]; then
        write_state 'del(.fail)'
        echo "Injected failure: $1" >&2
        exit 1
    fi
}
option() {
    local i
    for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "${args[$i]}" == "$1" ]]; then
            printf '%s\n' "${args[$((i + 1))]}"
            return
        fi
    done
}
field() {
    local arg
    for arg in "${args[@]}"; do
        if [[ "$arg" == "$1="* ]]; then
            printf '%s\n' "${arg#*=}"
            return
        fi
    done
}
has() {
    local arg
    for arg in "${args[@]}"; do [[ "$arg" != "$1" ]] || return 0; done
    return 1
}

if [[ "$1" == api ]]; then
    endpoint=""
    for arg in "$@"; do
        [[ "$arg" != repos/* ]] || endpoint="$arg"
    done
    endpoint="${endpoint#repos/test/repo/}"
    case "$endpoint" in
        releases)
            fail_once create
            [[ "$(option --method)" == POST ]]
            payload="$(cat "$(option --input)")"
            jq -e '.draft == true and .make_latest == "false"
                and (.prerelease | type == "boolean")' <<<"$payload" >/dev/null
            tag="$(jq -r '.tag_name' <<<"$payload")"
            jq -e --arg tag "$tag" '[.releases[] | select(.tag_name == $tag)] | length == 0' "$state" >/dev/null
            write_state --argjson payload "$payload" \
                '.releases += [$payload + {id:.next_id,assets:[]}] | .next_id += 1'
            jq '.releases[-1]' "$state"
            ;;
        'releases?per_page=100')
            fail_once list
            has --paginate && has --slurp
            # Small pages force tests through the same --paginate --slurp shape as GitHub.
            jq '(.omit_drafts_from_list // false) as $omit
                | [.releases[] | select($omit == false or .draft == false)]
                | [.[0:2], .[2:]]' "$state"
            ;;
        git/matching-refs/tags/*)
            prefix="refs/tags/${endpoint#git/matching-refs/tags/}"
            jq --arg prefix "$prefix" '[.refs | to_entries[] | select(.key | startswith($prefix)) | {ref:.key, object:.value}]' "$state"
            ;;
        git/ref/tags/*)
            jq -e --arg tag "refs/tags/${endpoint#git/ref/tags/}" '.refs[$tag] | select(. != null) | {object:.}' "$state"
            ;;
        git/tags/*)
            jq -e --arg sha "${endpoint#git/tags/}" '.objects[$sha] | select(. != null) | {object:.}' "$state"
            ;;
        git/refs)
            [[ "$(option --method)" == POST ]]
            ref="$(field ref)"
            sha="$(field sha)"
            jq -e --arg ref "$ref" '.refs[$ref] == null' "$state" >/dev/null
            write_state --arg ref "$ref" --arg sha "$sha" '.refs[$ref] = {type:"commit",sha:$sha}'
            jq --arg ref "$ref" '{ref:$ref,object:.refs[$ref]}' "$state"
            ;;
        releases/generate-notes)
            [[ "$(option --method)" == POST ]]
            previous="$(field previous_tag_name)"
            write_state --arg previous "$previous" '.notes_requests += [$previous]'
            jq -n --arg previous "$previous" '{body:("Generated changes since " + $previous)}'
            ;;
        commits\?*)
            has --paginate && has --slurp
            printf '[[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","commit":{"message":"Initial app"},"html_url":"https://github.com/test/repo/commit/aaaaaaaa"}]]\n'
            ;;
        releases/assets/*)
            [[ "$(option -H)" == 'Accept: application/octet-stream' ]]
            cat "$FAKE_GH_ROOT/assets/${endpoint#releases/assets/}"
            ;;
        releases/*)
            release_id="${endpoint#releases/}"
            if [[ "$(option --method)" == DELETE ]]; then
                fail_once cleanup
                write_state --argjson id "$release_id" '.deleted += [.releases[] | select(.id == $id) | .tag_name] | .releases |= map(select(.id != $id))'
                if [[ "$(jq -r '.cleanup_race // false' "$state")" == true ]]; then
                    write_state 'del(.cleanup_race)'
                    echo 'gh: Not Found (HTTP 404)' >&2
                    exit 1
                fi
            else
                jq -e --argjson id "$release_id" '.releases[] | select(.id == $id)' "$state"
            fi
            ;;
        *)
            echo "Unexpected gh API operation: $*" >&2
            exit 91
            ;;
    esac
elif [[ "$1" == release ]]; then
    tag="$3"
    case "$2" in
        upload)
            jq -e --arg tag "$tag" '.releases[] | select(.tag_name == $tag) | .draft == true' "$state" >/dev/null
            has --clobber
            for path in "$4" "$5"; do
                if [[ "$path" == *.sig ]]; then fail_once upload_signature; fi
                name="$(basename "$path")"
                id="$(jq '.next_id' "$state")"
                digest="sha256:$(shasum -a 256 "$path" | cut -d ' ' -f 1)"
                [[ "$(jq -r '.corrupt // false' "$state")" != true ]] || digest="sha256:bad"
                cp "$path" "$FAKE_GH_ROOT/assets/$id"
                write_state --arg tag "$tag" --arg name "$name" --arg digest "$digest" \
                    --argjson size "$(wc -c <"$path")" --argjson id "$id" \
                    '(.releases[] | select(.tag_name == $tag) | .assets) |= (map(select(.name != $name)) + [{id:$id,name:$name,size:$size,state:"uploaded",digest:$digest}]) | .next_id += 1'
            done
            ;;
        edit)
            if has --draft=false; then fail_once publish; fi
            if has --latest; then
                fail_once latest
                write_state --arg tag "$tag" '.latest = $tag'
            fi
            notes="$(option --notes-file)"
            if [[ -n "$notes" ]]; then
                write_state --arg tag "$tag" --arg body "$(cat "$notes")" '(.releases[] | select(.tag_name == $tag) | .body) = $body'
            fi
            for property in draft prerelease; do
                for value in true false; do
                    if has "--$property=$value"; then
                        write_state --arg tag "$tag" --arg property "$property" --argjson value "$value" \
                            '(.releases[] | select(.tag_name == $tag))[$property] = $value'
                    fi
                done
            done
            ;;
        *)
            echo "Unexpected gh release operation: $*" >&2
            exit 92
            ;;
    esac
else
    echo "Unexpected gh operation: $*" >&2
    exit 93
fi
