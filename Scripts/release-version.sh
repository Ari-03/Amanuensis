#!/bin/bash
# Resolves the next stable target, a nightly version, or a matching release tag.
# `guard` checks published stable releases in CI; other commands work offline.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
project_version="$(grep -o 'MARKETING_VERSION = [^;]*' "$app_root/Amanuensis.xcodeproj/project.pbxproj" \
    | sed 's/MARKETING_VERSION = //' | sort -u)"
if [[ ! "$project_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Expected one stable MARKETING_VERSION in the Xcode project (found: ${project_version//$'\n'/, })" >&2
    exit 1
fi

case "${1:-}" in
    base)
        [[ $# == 1 ]] || exit 1
        printf '%s\n' "$project_version"
        ;;
    nightly)
        if [[ $# != 2 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
            echo "Usage: $0 nightly <positive workflow run number>" >&2
            exit 1
        fi
        printf '%s-nightly.%s\n' "$project_version" "$2"
        ;;
    guard)
        [[ $# == 1 ]] || exit 1
        : "${GH_REPO:?Set GH_REPO to the GitHub owner/repository}"
        # A failed API call must fail the check, not masquerade as an empty repository.
        releases="$(gh api --paginate --slurp "repos/$GH_REPO/releases?per_page=100")"
        latest="$(jq -er '
            if type != "array" or (all(.[]; type == "array") | not) then
                error("Expected paginated release arrays")
            else . end
            | flatten(1)
            | if all(.[]; type == "object" and (.draft | type == "boolean")
                and (.prerelease | type == "boolean") and (.tag_name | type == "string")) then .
              else error("Invalid release response") end
            | map(select(.draft == false and .prerelease == false)
                | .tag_name | select(test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")))
            | max_by(ltrimstr("v") | split(".") | map([length, .])) // "none"
        ' <<<"$releases")"
        if [[ "$latest" != none ]] && ! jq -en --arg base "$project_version" --arg stable "${latest#v}" '
            def parts: split(".") | map([length, .]);
            ($base | parts) > ($stable | parts)
        ' >/dev/null; then
            echo "MARKETING_VERSION $project_version must be newer than published stable $latest." >&2
            echo "Bump the next stable target in Amanuensis.xcodeproj/project.pbxproj before merging." >&2
            exit 1
        fi
        printf 'Development version %s is newer than published stable %s.\n' "$project_version" "$latest"
        ;;
    v*)
        tag="$1"
        # Keep the tag syntax compatible with the app's AppVersion parser.
        if [[ $# != 1 || ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
            echo "Tag '$tag' must look like v1.2.3 or v1.2.3-preview.1" >&2
            exit 1
        fi
        version="${tag#v}"
        if [[ "${version%%-*}" != "$project_version" ]]; then
            echo "Tag $tag needs MARKETING_VERSION = ${version%%-*} in the Xcode project (found: $project_version)" >&2
            exit 1
        fi
        printf '%s\n' "$version"
        ;;
    *)
        echo "Usage: $0 base | nightly <run-number> | guard | <release-tag>" >&2
        exit 1
        ;;
esac
