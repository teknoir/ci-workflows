#!/usr/bin/env bash
# Tests for the pure helpers in scripts/land.sh. No network, no git.
#   bash scripts/test-land.sh
set -uo pipefail

# shellcheck source=land.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/land.sh"

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

# --- is_minor_or_patch -----------------------------------------------------

expect_ok "minor bump 1.2.3 -> 1.3.0" is_minor_or_patch 1.2.3 1.3.0
expect_ok "patch bump 1.2.3 -> 1.2.4" is_minor_or_patch 1.2.3 1.2.4
expect_ok "same version 2.0.0 -> 2.0.0" is_minor_or_patch 2.0.0 2.0.0
expect_ok "leading v on both sides" is_minor_or_patch v1.2.3 v1.3.0
expect_ok "leading v on one side" is_minor_or_patch v1.2.3 1.3.0
expect_ok "0.x patch bump 0.1.2 -> 0.1.3" is_minor_or_patch 0.1.2 0.1.3
expect_ok "requirement constraint ^1.2.3 -> ^1.3.0" is_minor_or_patch '^1.2.3' '^1.3.0'
expect_no "major bump 1.2.3 -> 2.0.0" is_minor_or_patch 1.2.3 2.0.0
expect_no "0.x minor counts as major 0.1.2 -> 0.2.0" is_minor_or_patch 0.1.2 0.2.0
expect_no "0.x to 1.0 0.1.2 -> 1.0.0" is_minor_or_patch 0.1.2 1.0.0
expect_no "major-only tags 4 -> 5" is_minor_or_patch 4 5
expect_no "requirement constraint ^0.1.0 -> ^0.2.0" is_minor_or_patch '^0.1.0' '^0.2.0'
expect_no "unparsable from" is_minor_or_patch main main

# --- iso_utc / iso_after ---------------------------------------------------

expect_eq "iso_utc keeps a whole-second Z timestamp" \
  '2026-11-23T08:54:12Z' iso_utc '2026-11-23T08:54:12Z'
expect_eq "iso_utc drops fractional seconds" \
  '2026-11-23T08:54:12Z' iso_utc '2026-11-23T08:54:12.843Z'
expect_eq "iso_utc drops fractional seconds and lower-case z" \
  '2026-11-23T08:54:12Z' iso_utc '2026-11-23T08:54:12.1z'
expect_eq "iso_utc rejects a date only" '' iso_utc '2026-11-23'
expect_eq "iso_utc rejects an offset" '' iso_utc '2026-11-23T08:54:12+01:00'
expect_eq "iso_utc rejects an empty timestamp" '' iso_utc ''

expect_ok "iso_after: later timestamp" iso_after '2026-11-23T08:54:12Z' '2026-11-23T08:54:11Z'
expect_ok "iso_after: fractional later timestamp" \
  iso_after '2026-11-23T08:54:13.9Z' '2026-11-23T08:54:12.1Z'
expect_no "iso_after: equal timestamps" iso_after '2026-11-23T08:54:12Z' '2026-11-23T08:54:12Z'
expect_no "iso_after: earlier timestamp" iso_after '2026-11-23T08:54:11Z' '2026-11-23T08:54:12Z'
expect_no "iso_after: label older than head (load bearing)" \
  iso_after '2026-11-23T08:00:00Z' '2026-11-23T09:00:00Z'
expect_no "iso_after: unparsable label time" iso_after '' '2026-11-23T09:00:00Z'
expect_no "iso_after: unparsable head time" iso_after '2026-11-23T09:00:00Z' 'null'

# --- command_timeout -------------------------------------------------------

expect_eq "timeout 45 minutes" '40m' command_timeout 45
expect_eq "timeout 90 minutes" '85m' command_timeout 90
expect_eq "timeout floor at 6 minutes" '1m' command_timeout 6
expect_eq "timeout below the floor" '1m' command_timeout 3
expect_eq "timeout default" '40m' command_timeout ''
expect_eq "timeout unparsable" '40m' command_timeout 'soon'

# --- jq_string -------------------------------------------------------------

expect_eq "jq string: plain label" '"ready-to-land"' jq_string 'ready-to-land'
expect_eq "jq string: a quote is escaped" '"a\"b"' jq_string 'a"b'
expect_eq "jq string: a backslash is escaped" '"a\\b"' jq_string 'a\b'
expect_eq "jq string: both and the order" '"x\\y\"z"' jq_string 'x\y"z'

# --- updated_dependencies_block --------------------------------------------

# shellcheck disable=SC2016
dep_commit_single='Bump github.com/foo/bar from 1.2.3 to 1.3.0

Bumps [github.com/foo/bar](https://github.com/foo/bar) from 1.2.3 to 1.3.0.

---
updated-dependencies:
- dependency-name: github.com/foo/bar
  dependency-version: 1.3.0
  dependency-type: direct:production
  update-type: version-update:semver-minor
...'

test_block_single() {
  local got
  got=$(updated_dependencies_block "$dep_commit_single")
  [[ $got == *'dependency-name: github.com/foo/bar'* ]] &&
    [[ $got == *'update-type: version-update:semver-minor'* ]] &&
    [[ $got != *'---'* ]] &&
    [[ $got != *'...'* ]]
}
expect_ok "block: single update, marker line excluded" test_block_single

test_block_quoted() {
  local got
  got=$(updated_dependencies_block 'msg

updated-dependencies:
- dependency-name: "@aws-sdk/client-s3"
  dependency-version: "3.200.0"
  update-type: "version-update:semver-minor"
')
  [[ $got == *'dependency-version: "3.200.0"'* ]]
}
expect_ok "block: quoted values and end of message" test_block_quoted

expect_eq "dependabot_update_types: single" \
  'version-update:semver-minor' dependabot_update_types "$dep_commit_single"

# shellcheck disable=SC2016
dep_commit_grouped='Bump the aws-sdk group with 2 updates

Bumps the aws-sdk group with 2 updates: `@aws-sdk/client-s3`, `@aws-sdk/client-sqs`.

Updates `@aws-sdk/client-s3` from 3.100.0 to 3.200.0
Updates `@aws-sdk/client-sqs` from 3.101.0 to 3.101.1

---
updated-dependencies:
- dependency-name: "@aws-sdk/client-s3"
  dependency-version: "3.200.0"
  dependency-type: "direct:production"
  update-type: "version-update:semver-minor"
- dependency-name: "@aws-sdk/client-sqs"
  dependency-version: "3.101.1"
  dependency-type: "direct:production"
  update-type: "version-update:semver-patch"
...
'

expect_eq "dependabot_update_types: grouped" \
  $'version-update:semver-minor\nversion-update:semver-patch' \
  dependabot_update_types "$dep_commit_grouped"
expect_eq "dependabot_entry_count: grouped" '2' \
  dependabot_entry_count "$dep_commit_grouped"
expect_eq "dependabot_entry_count: single" '1' \
  dependabot_entry_count "$dep_commit_single"
expect_eq "dependabot_entry_count: no block" '0' \
  dependabot_entry_count 'Nothing here.'
expect_eq "dependabot_title_count: grouped title" '2' \
  dependabot_title_count 'Bump the aws-sdk group with 2 updates'
expect_eq "dependabot_title_count: no count" '' \
  dependabot_title_count 'Bump github.com/foo/bar from 1.2.3 to 1.3.0'

expect_eq "zero-version entries: none" '' \
  dependabot_zero_version_entries "$dep_commit_grouped"

# shellcheck disable=SC2016
dep_commit_zero='msg

---
updated-dependencies:
- dependency-name: github.com/x/y
  dependency-version: 0.4.0
  update-type: version-update:semver-minor
...
'
expect_eq "zero-version entries: found" 'github.com/x/y 0.4.0' \
  dependabot_zero_version_entries "$dep_commit_zero"

# --- dependabot_pair_for ---------------------------------------------------

expect_eq "pair for a named dependency" 'from 3.100.0 to 3.200.0' \
  dependabot_pair_for "$dep_commit_grouped" '@aws-sdk/client-s3'
expect_eq "pair for the second dependency" 'from 3.101.0 to 3.101.1' \
  dependabot_pair_for "$dep_commit_grouped" '@aws-sdk/client-sqs'
expect_eq "pair for an unknown dependency" '' \
  dependabot_pair_for "$dep_commit_grouped" 'left-pad'
# Backticks are literal Markdown.
# shellcheck disable=SC2016
expect_eq "pair ignores another dependency's line" '' \
  dependabot_pair_for 'Updates `left-pad` from 1.0.0 to 2.0.0' '@aws-sdk/client-s3'
# Dependabot ends the sentence with a period; is_minor_or_patch tolerates it.
expect_eq "pair: a plain \"Bumps <name> from\" line" 'from 1.0.0 to 1.1.0.' \
  dependabot_pair_for 'Bumps left-pad from 1.0.0 to 1.1.0.' 'left-pad'
expect_eq "pair: a plain \"Bump <name> from\" line" 'from 1.0.0 to 1.1.0' \
  dependabot_pair_for 'Bump left-pad from 1.0.0 to 1.1.0' 'left-pad'
# A name is matched whole: "@types/foo" never takes the pair written for
# "foo", and "foo" never takes the pair written for "@types/foo".
# shellcheck disable=SC2016
dep_pair_body='Bump @types/foo from 0.1.0 to 0.1.1

Updates `foo` from 2.0.0 to 2.0.1
Updates `@types/foo` from 0.1.0 to 0.1.1
'
expect_eq "pair: the exact dependency's line wins" 'from 0.1.0 to 0.1.1' \
  dependabot_pair_for "$dep_pair_body" '@types/foo'
expect_eq "pair: foo does not take @types/foo's line" 'from 2.0.0 to 2.0.1' \
  dependabot_pair_for "$dep_pair_body" foo
expect_eq "pair: a name inside another name does not match" '' \
  dependabot_pair_for 'Bump @types/foo from 0.1.0 to 0.1.1' foo

# --- dependabot_commits_allowed --------------------------------------------

expect_ok "dependabot: single minor update" \
  dependabot_commits_allowed 'Bump github.com/foo/bar from 1.2.3 to 1.3.0' "$dep_commit_single"
expect_ok "dependabot: grouped minor and patch" \
  dependabot_commits_allowed 'Bump the aws-sdk group with 2 updates' "$dep_commit_grouped"

# shellcheck disable=SC2016
dep_commit_major='msg

---
updated-dependencies:
- dependency-name: github.com/foo/bar
  dependency-version: 2.0.0
  update-type: version-update:semver-major
...
'
expect_no "dependabot: major update-type" \
  dependabot_commits_allowed 'Bump github.com/foo/bar from 1.2.3 to 2.0.0' "$dep_commit_major"

# shellcheck disable=SC2016
dep_commit_no_type='msg

---
updated-dependencies:
- dependency-name: github.com/foo/bar
  dependency-version: 1.3.0
...
'
expect_no "dependabot: no update-type line" \
  dependabot_commits_allowed 'Bump github.com/foo/bar from 1.2.3 to 1.3.0' "$dep_commit_no_type"

# Every entry needs its own update-type line: one shared line is not enough.
# shellcheck disable=SC2016
dep_commit_missing_type='msg

---
updated-dependencies:
- dependency-name: github.com/foo/bar
  dependency-version: 1.3.0
  update-type: version-update:semver-minor
- dependency-name: github.com/foo/baz
  dependency-version: 2.0.1
...
'
expect_no "dependabot: one entry without its own update-type" \
  dependabot_commits_allowed 'Bump the foo group with 2 updates' "$dep_commit_missing_type"

# The pair must name the entry's exact dependency, and only the commit
# message is read: the title's "Bump @types/foo from ..." does not count.
# shellcheck disable=SC2016
dep_commit_types_foo='msg

Updates `foo` from 0.1.0 to 0.1.1

---
updated-dependencies:
- dependency-name: "@types/foo"
  dependency-version: 0.1.1
  update-type: version-update:semver-patch
...
'
expect_no "dependabot: @types/foo does not take foo's pair" \
  dependabot_commits_allowed 'Bump @types/foo from 0.1.0 to 0.1.1' "$dep_commit_types_foo"

# shellcheck disable=SC2016
dep_commit_types_foo_ok='msg

Updates `@types/foo` from 0.1.0 to 0.1.1

---
updated-dependencies:
- dependency-name: "@types/foo"
  dependency-version: 0.1.1
  update-type: version-update:semver-patch
...
'
expect_ok "dependabot: @types/foo with its own pair" \
  dependabot_commits_allowed 'Bump @types/foo from 0.1.0 to 0.1.1' "$dep_commit_types_foo_ok"

expect_no "dependabot: no block" \
  dependabot_commits_allowed 'Bump github.com/foo/bar from 1.2.3 to 1.3.0' 'Just a message.'

# shellcheck disable=SC2016
dep_commit_truncated='msg

---
updated-dependencies:
- dependency-name: github.com/foo/bar
  dependency-version: 1.3.0
  update-type: version-update:semver-minor
... (truncated)
'
expect_no "dependabot: truncated body" \
  dependabot_commits_allowed 'Bump github.com/foo/bar from 1.2.3 to 1.3.0' "$dep_commit_truncated"

# A 0.x minor with a from/to pair that keeps the minor: allowed.
# shellcheck disable=SC2016
dep_commit_zero_ok='Bump github.com/x/y from 0.4.0 to 0.4.3

Updates `github.com/x/y` from 0.4.0 to 0.4.3

---
updated-dependencies:
- dependency-name: github.com/x/y
  dependency-version: 0.4.3
  update-type: version-update:semver-patch
...
'
expect_ok "dependabot: 0.x patch with a passing pair" \
  dependabot_commits_allowed 'Bump github.com/x/y from 0.4.0 to 0.4.3' "$dep_commit_zero_ok"

# A 0.x entry with no from/to pair anywhere: refused.
expect_no "dependabot: 0.x entry with no pair" \
  dependabot_commits_allowed 'Bump github.com/x/y' "$dep_commit_zero"

# A 0.x entry whose pair is a 0.x minor: refused.
# shellcheck disable=SC2016
dep_commit_zero_minor='Bump github.com/x/y from 0.4.0 to 0.5.0

---
updated-dependencies:
- dependency-name: github.com/x/y
  dependency-version: 0.5.0
  update-type: version-update:semver-minor
...
'
expect_no "dependabot: 0.x minor with a failing pair" \
  dependabot_commits_allowed 'Bump github.com/x/y from 0.4.0 to 0.5.0' "$dep_commit_zero_minor"

# The title says three updates, the metadata lists two: refused.
expect_no "dependabot: title count does not match the entries" \
  dependabot_commits_allowed 'Bump the aws-sdk group with 3 updates' "$dep_commit_grouped"

# A grouped title without a count still checks every entry.
expect_ok "dependabot: grouped title without a count" \
  dependabot_commits_allowed 'Bump the aws-sdk group' "$dep_commit_grouped"

# --- caller_workflow_file --------------------------------------------------

test_caller_workflow_file() {
  local got
  got=$(caller_workflow_file 'teknoir/backstage/.github/workflows/land.yml@refs/heads/main')
  [[ $got == 'land.yml' ]]
}
expect_ok "caller workflow file from a branch ref" test_caller_workflow_file

test_caller_workflow_file_tag() {
  local got
  got=$(caller_workflow_file 'teknoir/ci-workflows/.github/workflows/land.yml@refs/tags/v1.0.0')
  [[ $got == 'land.yml' ]]
}
expect_ok "caller workflow file from a tag ref" test_caller_workflow_file_tag

test_caller_workflow_file_other_name() {
  local got
  got=$(caller_workflow_file 'teknoir/profile-controller/.github/workflows/merge-gate.yml@refs/heads/main')
  [[ $got == 'merge-gate.yml' ]]
}
expect_ok "caller workflow file with another name" test_caller_workflow_file_other_name

# --- result ----------------------------------------------------------------

printf '\n%s tests, %s failed\n' "$tests" "$failures"
if (( failures > 0 )); then
  exit 1
fi
