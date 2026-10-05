#!/bin/bash
# Offline release-version checks, including GitHub response failures and pagination.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-version-checks.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Scripts" "$work/Amanuensis.xcodeproj" "$work/bin"
cp "$app_root/Scripts/release-version.sh" "$work/Scripts/"
version_script="$work/Scripts/release-version.sh"
export GH_REPO=owner/test-repository
export GH_MOCK_RELEASES="$work/releases.json"
export GH_MOCK_ARGS="$work/gh-args"
export PATH="$work/bin:$PATH"
cat >"$work/bin/gh" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >"$GH_MOCK_ARGS"
if [[ "${GH_MOCK_FAIL:-false}" == true ]]; then
    echo "mock GitHub API unavailable" >&2
    exit 1
fi
cat "$GH_MOCK_RELEASES"
MOCK
chmod +x "$work/bin/gh"

set_version() {
    printf 'MARKETING_VERSION = %s;\nMARKETING_VERSION = %s;\n' "$1" "$1" \
        >"$work/Amanuensis.xcodeproj/project.pbxproj"
}

expect_failure() {
    if "$@" >"$work/output" 2>&1; then
        printf 'Expected failure: %s\n' "$*" >&2
        exit 1
    fi
}

set_version 0.2.0
test "$("$version_script" base)" = 0.2.0
test "$("$version_script" v0.2.0)" = 0.2.0
test "$("$version_script" v0.2.0-preview.1)" = 0.2.0-preview.1
test "$("$version_script" nightly 9)" = 0.2.0-nightly.9
test "$("$version_script" nightly 10)" = 0.2.0-nightly.10
for invalid in '' 0 01 -1 1.2 preview 1a; do
    expect_failure "$version_script" nightly "$invalid"
done
expect_failure "$version_script" nightly
expect_failure "$version_script" base unexpected
expect_failure "$version_script" guard unexpected
for invalid in v0.1.0 v0.3.0 0.2.0 v01.2.0 v0.2 v0.2.0- v0.2.0-preview..1 'v0.2.0+metadata' 'v0.2.0 preview'; do
    expect_failure "$version_script" "$invalid"
done

printf '[[]]\n' >"$GH_MOCK_RELEASES"
"$version_script" guard >/dev/null
printf 'api\n--paginate\n--slurp\nrepos/owner/test-repository/releases?per_page=100\n' >"$work/expected-args"
cmp "$work/expected-args" "$GH_MOCK_ARGS"
# The stable is on a later page; drafts and prereleases never block the next target.
cat >"$GH_MOCK_RELEASES" <<'JSON'
[[
  {"tag_name":"v9.0.0","draft":true,"prerelease":false},
  {"tag_name":"v8.0.0","draft":false,"prerelease":true},
  {"tag_name":"v7.0.0-preview.1","draft":false,"prerelease":false},
  {"tag_name":"v0.2.0-nightly.10","draft":false,"prerelease":true}
], [
  {"tag_name":"v0.1.0","draft":false,"prerelease":false},
  {"tag_name":"unrelated-tag","draft":false,"prerelease":false}
]]
JSON
"$version_script" guard >/dev/null
set_version 0.1.0
expect_failure "$version_script" guard
set_version 0.0.9
expect_failure "$version_script" guard

cat >"$GH_MOCK_RELEASES" <<'JSON'
[[{"tag_name":"v0.10.0","draft":false,"prerelease":false},
  {"tag_name":"v0.9.99","draft":false,"prerelease":false}]]
JSON
set_version 0.10.0
expect_failure "$version_script" guard
set_version 0.10.1
"$version_script" guard >/dev/null
set_version 1.0.0
"$version_script" guard >/dev/null
for invalid in '{"message":"Bad credentials"}' 'null' '[{}]' '[[{}]]' 'not json'; do
    printf '%s\n' "$invalid" >"$GH_MOCK_RELEASES"
    expect_failure "$version_script" guard
done
printf '[[]]\n' >"$GH_MOCK_RELEASES"
expect_failure env GH_MOCK_FAIL=true "$version_script" guard
for invalid in 0.2.0-nightly.1 01.2.0 invalid; do
    set_version "$invalid"
    expect_failure "$version_script" base
done
printf 'MARKETING_VERSION = 0.2.0;\nMARKETING_VERSION = 0.3.0;\n' \
    >"$work/Amanuensis.xcodeproj/project.pbxproj"
expect_failure "$version_script" base
printf 'Release version checks passed.\n'
