#!/bin/bash
# Prints the app version for a release tag after checking it against the Xcode project.
# Tags look like v0.2.0 (stable) or v0.2.0-preview.1 (preview). The part before any dash must
# equal MARKETING_VERSION, so every release commit states its own version.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${1:-}"
# Prerelease identifiers are dot-separated and never empty, matching the app's AppVersion parser.
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
    echo "Tag '$tag' must look like v1.2.3 or v1.2.3-preview.1" >&2
    exit 1
fi
version="${tag#v}"
base="${version%%-*}"
project_versions="$(grep -o 'MARKETING_VERSION = [^;]*' "$app_root/Amanuensis.xcodeproj/project.pbxproj" \
    | sed 's/MARKETING_VERSION = //' | sort -u)"
if [[ "$project_versions" != "$base" ]]; then
    echo "Tag $tag needs MARKETING_VERSION = $base in the Xcode project (found: ${project_versions//$'\n'/, })" >&2
    exit 1
fi
printf '%s\n' "$version"
