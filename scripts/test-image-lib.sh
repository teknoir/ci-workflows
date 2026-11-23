#!/usr/bin/env bash
# Tests for the helpers in scripts/image-lib.sh. No network, no git; the one
# stub on PATH is a fake `docker` for the tag-state helper.
#   bash scripts/test-image-lib.sh
set -uo pipefail

# shellcheck source=image-lib.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/image-lib.sh"

tests=0
failures=0

pass() {
  tests=$((tests + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  tests=$((tests + 1))
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1"
}

expect_ok() {
  local desc=$1
  shift
  if "$@"; then pass "$desc"; else fail "$desc (expected success)"; fi
}

expect_no() {
  local desc=$1
  shift
  if "$@"; then fail "$desc (expected failure)"; else pass "$desc"; fi
}

expect_eq() {
  local desc=$1 want=$2
  shift 2
  local got
  got=$("$@")
  if [[ $got == "$want" ]]; then
    pass "$desc"
  else
    fail "$desc (got '$got', want '$want')"
  fi
}

sha=0123456789abcdef0123456789abcdef01234567

# --- image_version_valid ---------------------------------------------------

expect_ok "version 1.2.3" image_version_valid 1.2.3
expect_ok "version 0.0.0" image_version_valid 0.0.0
expect_ok "version 10.20.30" image_version_valid 10.20.30
expect_ok "prerelease 1.2.3-beta.1" image_version_valid 1.2.3-beta.1
expect_ok "build metadata 1.2.3+build.5" image_version_valid 1.2.3+build.5
expect_no "prerelease then metadata 1.2.3-rc.1+b (spec regex allows one suffix)" image_version_valid 1.2.3-rc.1+b
expect_no "empty" image_version_valid ''
expect_no "two parts 1.2" image_version_valid 1.2
expect_no "four parts 1.2.3.4" image_version_valid 1.2.3.4
expect_no "leading v" image_version_valid v1.2.3
expect_no "whitespace" image_version_valid ' 1.2.3'
expect_no "latest" image_version_valid latest
expect_no "empty prerelease 1.2.3-" image_version_valid 1.2.3-
expect_no "slash 1.2.3/4" image_version_valid 1.2.3/4
expect_no "newline 1.2.3 and 2.0.0" image_version_valid $'1.2.3\n2.0.0'

# --- image_expand ----------------------------------------------------------

expect_eq "sha8" 'COMMIT=01234567' \
  image_expand 'COMMIT={sha8}' "$sha" main ''
expect_eq "sha7" 'sha7=0123456' \
  image_expand 'sha7={sha7}' "$sha" main ''
expect_eq "sha" "revision=${sha}" \
  image_expand 'revision={sha}' "$sha" main ''
expect_eq "ref" 'VERSION=main-01234567' \
  image_expand 'VERSION={ref}-{sha8}' "$sha" main ''
expect_eq "version" 'VERSION=1.2.3' \
  image_expand 'VERSION={version}' "$sha" main 1.2.3
expect_eq "several placeholders" "A=main-01234567-0123456-${sha}-1.2.3" \
  image_expand 'A={ref}-{sha8}-{sha7}-{sha}-{version}' "$sha" main 1.2.3
expect_eq "no placeholders" 'PLAIN=value' \
  image_expand 'PLAIN=value' "$sha" main ''
expect_eq "dashed ref" 'X=feature-x-01234567' \
  image_expand 'X={ref}-{sha8}' "$sha" feature-x ''
expect_eq "unknown left alone" 'X={bogus}' \
  image_expand 'X={bogus}' "$sha" main ''
expect_eq "sha8 does not eat other text" 'url=https://example.com/{path}' \
  image_expand 'url=https://example.com/{path}' "$sha" main ''

# --- image_unknown_placeholders --------------------------------------------

expect_eq "no unknown" '' image_unknown_placeholders 'PLAIN=value'
expect_eq "one unknown" 'bogus' image_unknown_placeholders 'X={bogus}'
expect_eq "sorted and deduplicated" $'alpha\nzeta' \
  image_unknown_placeholders 'X={zeta}-{alpha}-{zeta}'
expect_eq "empty braces ignored" '' image_unknown_placeholders 'X={}'
expect_eq "a near-miss is unknown" 'sha8x' image_unknown_placeholders 'X={sha8x}'

# --- image_safe_tag --------------------------------------------------------

expect_eq "safe tag plain" '1.2.3' image_safe_tag 1.2.3
expect_eq "safe tag prerelease" '1.2.3-rc.1' image_safe_tag 1.2.3-rc.1
expect_eq "safe tag maps + (vpro safe_tag)" '1.2.3-build.1' image_safe_tag '1.2.3+build.1'
expect_eq "safe tag maps / and space" 'a-b-c' image_safe_tag 'a/b c'
expect_eq "safe tag caps at 128" "$(printf 'a%.0s' $(seq 1 128))" image_safe_tag "$(printf 'a%.0s' $(seq 1 200))"
expect_eq "safe tag keeps _ and ." 'a_1.2' image_safe_tag 'a_1.2'

# --- image_tag_state (stub docker) -----------------------------------------

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
mkdir -p "$stub_dir/bin"
cat > "$stub_dir/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Stub: EXISTING="ref ref" is present, UNVERIFIABLE="ref ref" answers 503,
# anything else is a positive not-found.
ref=${4:-}
if [[ "$1 $2 $3" == "buildx imagetools inspect" ]]; then
  if [[ " ${UNVERIFIABLE:-} " == *" ${ref} "* ]]; then
    echo 'received unexpected status 503 Service Unavailable' >&2
    exit 1
  fi
  if [[ " ${EXISTING:-} " == *" ${ref} "* ]]; then
    if [[ "${5:-}" == --format ]]; then echo '{"digest":"sha256:111"}'; fi
    exit 0
  fi
  echo "${MISSING_MESSAGE:-ERROR: ${ref}: not found}" >&2
  exit 1
fi
echo "unexpected docker call: $*" >&2
exit 1
STUB
chmod +x "$stub_dir/bin/docker"
PATH="$stub_dir/bin:$PATH"

EXISTING='ghcr.io/teknoir/x:1.2.3' \
  expect_eq "tag state present" present image_tag_state ghcr.io/teknoir/x:1.2.3
EXISTING='' \
  expect_eq "tag state absent on not found" absent image_tag_state ghcr.io/teknoir/x:1.2.3
EXISTING='' MISSING_MESSAGE='ghcr.io/teknoir/x:1.2.3: manifest unknown' \
  expect_eq "tag state absent on manifest unknown" absent image_tag_state ghcr.io/teknoir/x:1.2.3
EXISTING='' MISSING_MESSAGE='ghcr.io/teknoir/x:1.2.3: MANIFEST_UNKNOWN' \
  expect_eq "tag state absent on MANIFEST_UNKNOWN" absent image_tag_state ghcr.io/teknoir/x:1.2.3
if state=$(UNVERIFIABLE='ghcr.io/teknoir/x:1.2.3' image_tag_state ghcr.io/teknoir/x:1.2.3); then
  fail "tag state 503 is unverifiable (expected a non-zero exit)"
else
  rc=$?
  if [[ $rc -eq 2 && "$state" == unverifiable:* ]]; then
    pass "tag state 503 is unverifiable (exit 2)"
  else
    fail "tag state 503 is unverifiable (got exit ${rc}, '${state}')"
  fi
fi

# --- image_output_list -----------------------------------------------------

out_file="$stub_dir/github_output"
: > "$out_file"
GITHUB_OUTPUT="$out_file" image_output_list tags \
  'ghcr.io/teknoir/x:sha-01234567' 'ghcr.io/teknoir/x:1.2.3'
mapfile -t lines < "$out_file"
delim=${lines[0]#tags<<}
expect_eq "output list opens a heredoc for the name" 'tags' printf '%s' "${lines[0]%%<<*}"
expect_eq "output list writes one item per line" \
  'ghcr.io/teknoir/x:sha-01234567|ghcr.io/teknoir/x:1.2.3' printf '%s' "${lines[1]}|${lines[2]}"
expect_eq "output list closes its own random delimiter" "${delim}|4" printf '%s' "${lines[3]}|${#lines[@]}"
expect_no "output list delimiter is not a fixed string" test "$delim" = "EOF"
: > "$out_file"
GITHUB_OUTPUT="$out_file" image_output_list tags
mapfile -t lines < "$out_file"
expect_eq "empty output list still opens and closes the heredoc" \
  "2|tags|${lines[1]}" printf '%s' "${#lines[@]}|${lines[0]%%<<*}|${lines[1]}"
: > "$out_file"
GITHUB_OUTPUT="$out_file" image_output_list tags 'value with {x} = y'
mapfile -t lines < "$out_file"
expect_eq "output list keeps the value verbatim" 'value with {x} = y' printf '%s' "${lines[1]}"

# --- report ----------------------------------------------------------------

printf '\n%d tests, %d failures\n' "$tests" "$failures"
[[ $failures -eq 0 ]]
