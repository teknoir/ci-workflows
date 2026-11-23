#!/usr/bin/env bash
# land.sh - the merge gate for private Teknoir repos (CI/CD v4).
#
# .github/workflows/land.yml runs one subcommand per job:
#
#   land.sh select   test job, read-only token: pick the PR, check that it is
#                    open, carries the label, targets the base, and that the
#                    label is newer than the head, fetch the base and the PR
#                    head, check the Dependabot commit metadata.
#   land.sh prepare  test job: check the PR head out, merge the base into it
#                    and record the tested base. No PR code runs here.
#   land.sh test     test job, no token: run COMMAND on the prepared tree. PR
#                    code runs here, so this job never has a write token and
#                    never touches the PR; the step writes no outputs.
#   land.sh merge    merge job, write token, no PR checkout: re-check through
#                    the API and squash-merge exactly the tested commit.
#   land.sh cleanup  cleanup job: remove the label and comment for the
#                    invalidations select reported, and for a failed or
#                    cancelled run.
#
# Environment (set by land.yml):
#   GH_TOKEN         token for gh and git fetch (select, merge, cleanup only)
#   GH_REPO          owner/repo, e.g. teknoir/backstage
#   LABEL            label that asks for a landing (default ready-to-land)
#   BASE             branch to merge into (default main)
#   COMMAND          test command (default ./scripts/test)
#   TIMEOUT_MINUTES  job timeout; the command gets five minutes less
#   IMAGE_WORKFLOW   workflow to dispatch on BASE after the merge ('' = none)
#   TEST_WORKFLOW    test workflow to dispatch on BASE when the merge landed
#                    on a base that was not tested ('' = none)
#   EVENT_NAME       github.event_name
#   EVENT_ACTION     github.event.action
#   EVENT_PR         github.event.pull_request.number
#   EVENT_LABEL      github.event.label.name
#   EVENT_HEAD_SHA   github.event.pull_request.head.sha
#   RUN_URL          link to this run, for PR comments
#   CALLER_WORKFLOW  file name of the caller's land workflow (e.g. land.yml)
#   GITHUB_RUN_ID    this run, compared with the label time on a synchronize
#   PR, HEAD_SHA, BASE_TESTED   outputs of the select and prepare steps
#   INVALIDATIONS    newline-separated "<pr>\t<comment>" pairs from select
#   COMMENT          the prepare step's comment for a merge conflict
#   TEST_RESULT, MERGE_RESULT   needs.<job>.result of the two jobs
#
# scripts/test-land.sh sources this file, so nothing runs at source time.

# ---------------------------------------------------------------------------
# Pure helpers: no network, no git. Tested by scripts/test-land.sh.
# ---------------------------------------------------------------------------

# strip_version_prefix <version> - drop a leading "v" and any constraint
# operator Dependabot prints in "requirement" titles (^, ~, =).
strip_version_prefix() {
  local v=$1
  while [[ $v == [v^~=]* ]]; do
    v=${v:1}
  done
  printf '%s' "$v"
}

# is_minor_or_patch <from> <to> - success when the bump keeps the major
# version. A 0.x minor change counts as a major change. Unparsable versions
# count as major (the caller then refuses to land).
is_minor_or_patch() {
  local from to fmaj fmin tmaj tmin
  from=$(strip_version_prefix "$1")
  to=$(strip_version_prefix "$2")
  [[ $from =~ ^([0-9]+)(\.([0-9]+))?([^0-9A-Za-z]|$) ]] || return 1
  fmaj=${BASH_REMATCH[1]}
  fmin=${BASH_REMATCH[3]:-0}
  [[ $to =~ ^([0-9]+)(\.([0-9]+))?([^0-9A-Za-z]|$) ]] || return 1
  tmaj=${BASH_REMATCH[1]}
  tmin=${BASH_REMATCH[3]:-0}
  (( fmaj == tmaj )) || return 1
  if (( fmaj == 0 )) && (( fmin != tmin )); then
    return 1
  fi
  return 0
}

# iso_utc <timestamp> - print a GitHub timestamp without fractional seconds.
# GitHub writes RFC 3339 UTC ("2026-11-23T08:54:12Z"). Anything else fails:
# the caller then refuses to land rather than comparing blind.
iso_utc() {
  local ts=$1
  [[ $ts =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?[Zz]$ ]] ||
    return 1
  printf '%sZ' "${BASH_REMATCH[1]}"
}

# jq_string <text> - text as a jq string literal, for a filter built at run
# time (gh api has no --arg).
jq_string() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# iso_after <a> <b> - success when timestamp a is strictly after b. Both are
# normalised to "YYYY-MM-DDTHH:MM:SSZ", which sorts lexicographically.
iso_after() {
  local a b
  a=$(iso_utc "$1") || return 1
  b=$(iso_utc "$2") || return 1
  [[ $a > $b ]]
}

# command_timeout <job minutes> - the command's timeout, five minutes under
# the job's (so the failure comment still gets posted), never under a minute.
command_timeout() {
  local minutes=${1:-45}
  [[ $minutes =~ ^[0-9]+$ ]] || minutes=45
  (( minutes > 6 )) || minutes=6
  printf '%sm' "$(( minutes - 5 ))"
}

# updated_dependencies_block <commit message> - the lines of Dependabot's
# "updated-dependencies:" YAML block (after the marker, up to "..." or the
# end of the message).
updated_dependencies_block() {
  printf '%s\n' "$1" | awk '
    /^updated-dependencies:[[:space:]]*$/ { inside = 1; next }
    inside && /^\.\.\.[[:space:]]*$/ { exit }
    inside { print }
  '
}

# dependabot_update_types <commit message> - every update-type value in the
# block, one per line, unquoted.
dependabot_update_types() {
  updated_dependencies_block "$1" |
    sed -n 's/^[[:space:]-]*update-type:[[:space:]]*//p' |
    tr -d '"' |
    sed 's/[[:space:]]*$//'
}

# dependabot_entry_count <commit message> - number of dependencies listed.
dependabot_entry_count() {
  local n
  n=$(updated_dependencies_block "$1" |
    grep -cE '^[[:space:]]*-[[:space:]]*dependency-name:' || true)
  printf '%s' "${n:-0}"
}

# dependabot_zero_version_entries <commit message> - "<name> <version>" for
# every entry whose dependency-version starts with 0. (a 0.x minor can break).
# Distinct dependency names in the updated-dependencies block. A group that spans
# several directories lists the same dependency once per directory, while the
# title ("... across 3 directories with 7 updates") counts each name once.
dependabot_unique_name_count() {
  local n
  n=$(updated_dependencies_block "$1" |
    sed -nE 's/^[[:space:]]*-[[:space:]]*dependency-name:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' |
    sort -u | grep -c . || true)
  printf '%s' "${n:-0}"
}
dependabot_zero_version_entries() {
  updated_dependencies_block "$1" | awk '
    /^[[:space:]]*-[[:space:]]*dependency-name:[[:space:]]*/ {
      name = $0
      sub(/^[[:space:]]*-[[:space:]]*dependency-name:[[:space:]]*/, "", name)
      gsub(/"/, "", name)
      sub(/[[:space:]]+$/, "", name)
    }
    /^[[:space:]]+dependency-version:[[:space:]]*/ {
      version = $0
      sub(/^[[:space:]]+dependency-version:[[:space:]]*/, "", version)
      gsub(/"/, "", version)
      sub(/[[:space:]]+$/, "", version)
      if (version ~ /^0\./ && name != "") print name, version
    }
  '
}

# dependabot_title_count <title> - the N of "... with N updates", or nothing.
dependabot_title_count() {
  if [[ $1 =~ \ with\ ([0-9]+)\ update(s)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# dependabot_pair_for <commit message> <dependency> - the first "from <a> to
# <b>" on a line that names exactly that dependency, in one of the four forms
# Dependabot writes. Only the commit message: the title is editable free text
# and can carry another dependency's pair.
dependabot_pair_for() {
  local msg=$1 name=$2 line
  while IFS= read -r line; do
    # Backticks, brackets and ${...} are literal Markdown in Dependabot
    # bodies; only "${name}" expands. A line must name exactly this
    # dependency, so "@types/foo" never takes the pair of "foo".
    if [[ $line == *"Updates \`${name}\` from "* ]] ||
      [[ $line == *"Bumps [${name}]("* ]] ||
      [[ $line == *"Bumps ${name} from "* ]] ||
      [[ $line == *"Bump ${name} from "* ]]; then
      # shellcheck disable=SC2016
      grep -oE 'from `?[v^~=]*[0-9][^ `]*`? to `?[v^~=]*[0-9][^ `]*`?' \
        <<<"$line" | head -n1
      return 0
    fi
  done <<<"$msg"
  return 0
}

# dependabot_commits_allowed <title> <commit message> - success when a
# Dependabot commit may land without a person, decided from the commit
# metadata only:
#   - no truncated body and a "updated-dependencies:" block with entries;
#   - one update-type line per entry, every one of them minor, patch or a
#     non-version update (an entry without its own update-type is refused);
#   - every 0.x dependency has a from/to pair for that exact dependency in the
#     commit message that keeps its minor version;
#   - the entry count matches the N of "with N updates", when the title has
#     one.
# Anything unrecognised counts as major.
dependabot_commits_allowed() {
  local title=$1 msg=$2 types type_count entries declared name _version pair
  local from to
  [[ $msg != *'(truncated)'* ]] || return 1
  updated_dependencies_block "$msg" | grep -q . || return 1
  types=$(dependabot_update_types "$msg")
  [[ -n $types ]] || return 1
  if grep -qx 'version-update:semver-major' <<<"$types"; then
    return 1
  fi
  entries=$(dependabot_entry_count "$msg")
  (( entries > 0 )) || return 1
  type_count=$(grep -c . <<<"$types" || true)
  (( type_count == entries )) || return 1
  declared=$(dependabot_title_count "$title")
  if [[ -n $declared ]] && (( declared != $(dependabot_unique_name_count "$msg") )); then
    return 1
  fi
  while read -r name _version; do
    [[ -n $name ]] || continue
    pair=$(dependabot_pair_for "$msg" "$name")
    [[ -n $pair ]] || return 1
    from=${pair#from }
    from=${from%% to *}
    to=${pair##* to }
    from=${from//\`/}
    to=${to//\`/}
    is_minor_or_patch "$from" "$to" || return 1
  done < <(dependabot_zero_version_entries "$msg")
  return 0
}

# caller_workflow_file <workflow_ref> - the caller's workflow file name from
# "owner/repo/.github/workflows/land.yml@refs/heads/main".
caller_workflow_file() {
  local ref=${1%%@*}
  printf '%s' "${ref##*/}"
}

# ---------------------------------------------------------------------------
# Helpers with side effects.
# ---------------------------------------------------------------------------

log() { printf 'land: %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }

set_output() {
  local key=$1 value=$2 file=${GITHUB_OUTPUT:-}
  [[ -n $file ]] || return 0
  {
    printf '%s<<__LAND_OUTPUT_EOF__\n' "$key"
    printf '%s\n' "$value"
    printf '__LAND_OUTPUT_EOF__\n'
  } >>"$file"
}

write_summary() {
  local result=$1 file=${GITHUB_STEP_SUMMARY:-}
  [[ -n $file ]] || return 0
  {
    printf '### Land\n\n'
    printf '| PR | Head | Base tested | Result |\n'
    printf '| --- | --- | --- | --- |\n'
    # shellcheck disable=SC2016
    printf '| #%s | `%s` | `%s` | %s |\n' \
      "${PR:-?}" "${HEAD_SHA:0:8}" "${BASE_TESTED:0:8}" "$result"
  } >>"$file"
}

# git_fetch <refspec>... - git fetch authenticated with GH_TOKEN. Only ever
# called from select, which runs no PR code.
git_fetch() {
  local header
  header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
  git -c "http.extraheader=${header}" fetch --no-tags "$@"
}

pr_has_label() {
  local labels
  labels=$(gh pr view "$1" --json labels --jq '.labels[].name') || return 1
  grep -Fxq "$LABEL" <<<"$labels"
}

pr_is_open() {
  [[ $(gh pr view "$1" --json state --jq '.state') == OPEN ]]
}

pr_is_open_and_labeled() {
  pr_is_open "$1" && pr_has_label "$1"
}

pr_unlabel_and_comment() {
  local pr=$1 msg=$2
  gh pr edit "$pr" --remove-label "$LABEL" ||
    warn "Could not remove label '$LABEL' from PR #$pr."
  gh pr comment "$pr" --body "$msg" || warn "Could not comment on PR #$pr."
}

# add_invalidation <pr> <comment> - ask the cleanup job to remove the label
# and post the comment (the test job's token cannot write).
add_invalidation() {
  INVALIDATIONS+="${1}"$'\t'"${2}"$'\n'
}

# fail <comment> <summary> - a deliberate stop of the test job: report the
# comment through the cleanup job and exit non-zero.
fail() {
  local msg=$1 summary=$2
  log "$msg"
  set_output comment "$msg"
  write_summary "$summary"
  exit 1
}

# label_added_at <pr> - created_at of the newest labeled event for $LABEL, or
# nothing when there is none. Fails when the API call does.
label_added_at() {
  local want raw
  want=$(jq_string "$LABEL")
  raw=$(gh api "repos/${GH_REPO}/issues/${1}/timeline" --paginate \
    --jq "[.[]|select(.event==\"labeled\" and .label.name==${want})]|last|.created_at") ||
    return 1
  grep -vx 'null' <<<"$raw" | grep -v '^$' | tail -n1 || true
}

# pr_open_and_labeled_now <pr> - 0 when the PR is open and carries $LABEL, 1
# when it is not, 2 when the API call failed.
pr_open_and_labeled_now() {
  local out state
  out=$(gh pr view "$1" --json state,labels --jq '.state, (.labels[].name)') ||
    return 2
  state=${out%%$'\n'*}
  [[ $state == OPEN ]] || return 1
  grep -Fxq "$LABEL" <<<"${out#*$'\n'}"
}

# label_after_head <pr> <head sha> - 0 when the label was added after the PR's
# current head first appeared and after its last force-push, and the head has
# a pull_request run at all; 1 when it was not; 2 when the API answers cannot
# be read (the caller then leaves the label alone). GitHub-assigned times only.
label_after_head() {
  local pr=$1 head=$2 label_at force_at head_seen
  label_at=$(label_added_at "$pr") || return 2
  force_at=$(gh api "repos/${GH_REPO}/issues/${pr}/timeline" --paginate \
    --jq '[.[]|select(.event=="head_ref_force_pushed")]|last|.created_at') ||
    return 2
  force_at=$(grep -vx 'null' <<<"$force_at" | grep -v '^$' | tail -n1 || true)
  head_seen=$(gh api "repos/${GH_REPO}/actions/runs?head_sha=${head}&event=pull_request" \
    --jq '[.workflow_runs[].created_at]|min') || return 2
  [[ -n $head_seen ]] || return 2
  [[ $head_seen != null ]] || return 1 # the head has no pull_request run
  iso_after "$label_at" "$head_seen" || return 1
  [[ -z $force_at ]] || iso_after "$label_at" "$force_at"
}

# dependabot_check <pr> <head sha> - Dependabot PRs land only when every
# commit is a verified Dependabot commit and the commit metadata says minor or
# patch. Needs the head fetched. Success for everything that is not
# Dependabot; a failed API call refuses (fail closed).
dependabot_check() {
  local pr=$1 head=$2 author commits title msg
  author=$(gh pr view "$pr" --json author --jq '.author.login') || return 1
  [[ -n $author ]] || return 1
  if [[ $author != 'app/dependabot' && $author != 'dependabot[bot]' ]]; then
    return 0
  fi
  # GitHub-assigned identity and signature, not the client-set author name.
  commits=$(gh api "repos/${GH_REPO}/pulls/${pr}/commits" --paginate \
    --jq '.[]|[.commit.verification.verified, .author.login]|@tsv') || return 1
  [[ -n $commits ]] || return 1
  if grep -vxFq $'true\tdependabot[bot]' <<<"$commits"; then
    log "PR #${pr}: not every commit is a verified dependabot[bot] commit."
    return 1
  fi
  title=$(gh pr view "$pr" --json title --jq '.title')
  msg=$(git log -1 --format=%B "$head")
  if ! dependabot_commits_allowed "$title" "$msg"; then
    log "PR #${pr}: the Dependabot update is not a minor or patch bump of every dependency."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Subcommands.
# ---------------------------------------------------------------------------

# select - choose the PR to land and fetch exactly what the prepare step needs.
cmd_select() {
  local candidates=() labeled_event=0 cand head base_ref rc label_at run_at
  set_output skip true
  INVALIDATIONS=${INVALIDATIONS:-}
  PR=""
  HEAD_SHA=""

  case "${EVENT_NAME}" in
    pull_request)
      case "${EVENT_ACTION}" in
        labeled)
          if [[ ${EVENT_LABEL} != "${LABEL}" ]]; then
            log "Label '${EVENT_LABEL}' is not '${LABEL}'; nothing to land."
            return 0
          fi
          candidates=("${EVENT_PR}")
          labeled_event=1
          ;;
        synchronize | reopened)
          # This step runs after the checkouts and the setup steps, so a label
          # added for the new head while it waited is newer than the run: the
          # labelled run lands that head, and this one leaves the label alone.
          if pr_open_and_labeled_now "${EVENT_PR}"; then
            label_at=$(label_added_at "${EVENT_PR}") || label_at=''
            run_at=$(gh api "repos/${GH_REPO}/actions/runs/${GITHUB_RUN_ID}" \
              --jq '.created_at') || run_at=''
            if [[ -n $label_at && -n $run_at ]] && iso_after "$label_at" "$run_at"; then
              log "PR #${EVENT_PR}: the label is newer than this run; the labelled run lands it."
              set_output invalidations "${INVALIDATIONS%$'\n'}"
              return 0
            fi
            add_invalidation "${EVENT_PR}" \
              "New commits; the label was removed. Add it again to land."
          else
            rc=$?
            if (( rc == 1 )); then
              log "PR #${EVENT_PR} is not open or does not carry '${LABEL}'; nothing to do."
            else
              warn "PR #${EVENT_PR}: could not read its state; removing the label to fail closed."
              add_invalidation "${EVENT_PR}" \
                "New commits; the label was removed. Add it again to land."
            fi
          fi
          log "PR #${EVENT_PR} was updated; nothing to land."
          set_output invalidations "${INVALIDATIONS%$'\n'}"
          return 0
          ;;
        *)
          log "pull_request action '${EVENT_ACTION}' is not a landing trigger."
          return 0
          ;;
      esac
      ;;
    schedule | workflow_dispatch)
      # Oldest first; a candidate that fails a check is skipped.
      mapfile -t candidates < <(gh pr list --base "$BASE" --label "$LABEL" \
        --state open --json number,createdAt \
        --jq 'sort_by(.createdAt)[].number')
      ;;
    *)
      log "Event '${EVENT_NAME}' is not a landing trigger."
      return 0
      ;;
  esac

  for cand in "${candidates[@]}"; do
    [[ -n $cand ]] || continue
    if ! pr_is_open_and_labeled "$cand"; then
      log "PR #${cand} is not open or does not carry '${LABEL}'; not landing it."
      continue
    fi
    # `gh pr merge` would merge into whatever base the PR targets, while the
    # test and the base re-check use "${BASE}".
    base_ref=$(gh pr view "$cand" --json baseRefName --jq '.baseRefName')
    if [[ $base_ref != "${BASE}" ]]; then
      add_invalidation "$cand" \
        "This PR targets \`${base_ref}\`; land.yml lands only into \`${BASE}\`."
      log "PR #${cand} targets ${base_ref}, not ${BASE}; not landing it."
      if (( labeled_event )); then
        break
      fi
      continue
    fi
    head=$(gh pr view "$cand" --json headRefOid --jq '.headRefOid')
    # Drafts never land (a person marks the PR ready and labels it again).
    if [[ $(gh pr view "$cand" --json isDraft --jq '.isDraft') == true ]]; then
      add_invalidation "$cand" \
        "Draft PRs are not landed; the \`${LABEL}\` label was removed. Add it again when the PR is ready."
      log "PR #${cand} is a draft; not landing it."
      if (( labeled_event )); then
        break
      fi
      continue
    fi
    if (( labeled_event )); then
      if [[ -n ${EVENT_HEAD_SHA} && $head != "${EVENT_HEAD_SHA}" ]]; then
        # A label newer than the live head's first run (and last force-push)
        # belongs to the live head: that run lands it, this one leaves it.
        if label_after_head "$cand" "$head"; then
          log "PR #${cand}: head ${head:0:8} carries a newer label; leaving it for that run."
          write_summary "skipped: the label belongs to head ${head:0:8}"
          set_output invalidations "${INVALIDATIONS%$'\n'}"
          return 0
        else
          rc=$?
          if (( rc == 2 )); then
            warn "PR #${cand}: could not read the label and run times; leaving the label alone."
            set_output invalidations "${INVALIDATIONS%$'\n'}"
            return 0
          fi
        fi
        add_invalidation "$cand" \
          "New commits after \`${LABEL}\` was added; the label was removed. Add it again to land."
        log "PR #${cand} head is ${head:0:8}, not the labelled ${EVENT_HEAD_SHA:0:8}; not landing it."
        break
      fi
    else
      if label_after_head "$cand" "$head"; then
        :
      else
        rc=$?
        if (( rc == 2 )); then
          # The API answer could be read to neither pass nor fail the label:
          # never remove a label the token cannot vouch for.
          warn "PR #${cand}: could not read the label and run times from the API; leaving the label alone."
          continue
        fi
        add_invalidation "$cand" \
          "New commits after \`${LABEL}\` was added; the label was removed. Add it again to land."
        log "PR #${cand}: the label predates the current head, a force-push followed it, or the head has no test run; not landing it."
        continue
      fi
    fi
    git_fetch origin "$BASE" "+refs/pull/${cand}/head:refs/remotes/pull/${cand}/head"
    if ! dependabot_check "$cand" "$head"; then
      add_invalidation "$cand" \
        "This Dependabot update is not a verified minor or patch bump of every dependency, so it needs a person to land it. The \`${LABEL}\` label was removed."
      continue
    fi
    PR=$cand
    HEAD_SHA=$head
    set_output pr "$PR"
    set_output head_sha "$HEAD_SHA"
    set_output skip false
    log "Landing PR #${PR} at ${HEAD_SHA:0:8}, merged with ${BASE}."
    set_output invalidations "${INVALIDATIONS%$'\n'}"
    return 0
  done

  log "No open ${BASE} PR is labelled '${LABEL}' and ready to land."
  set_output invalidations "${INVALIDATIONS%$'\n'}"
  return 0
}

# prepare - check out the PR head and merge BASE into it. This step runs no
# PR code (a checkout, a reset, a clean and a local merge), so it may write
# the base_tested and conflict-comment outputs the cleanup job posts.
cmd_prepare() {
  if [[ -z ${PR:-} || -z ${HEAD_SHA:-} ]]; then
    log "No PR was selected; nothing to prepare."
    exit 1
  fi
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git checkout --detach "$HEAD_SHA"
  git reset --hard -q
  git clean -fdq
  if ! git merge --no-edit "origin/${BASE}"; then
    git merge --abort || true
    fail "Conflicts with \`${BASE}\`; rebase or merge \`${BASE}\` into the branch, then add the label again." \
      "failed: conflict with ${BASE}"
  fi
  BASE_TESTED=$(git rev-parse "origin/${BASE}")
  set_output base_tested "$BASE_TESTED"
  log "Prepared PR #${PR} merged with ${BASE} ${BASE_TESTED:0:8}."
}

# test - run the command on the prepared tree. PR code runs here: no token,
# no step outputs. The cleanup job builds the failure comment from the job
# results and RUN_URL, never from anything this step writes.
cmd_test() {
  local status=0 timeout_arg
  if [[ -z ${BASE_TESTED:-} ]]; then
    log "The prepare step reported no tested base; nothing to test."
    exit 1
  fi
  timeout_arg=$(command_timeout "${TIMEOUT_MINUTES:-45}")
  log "Running the tests on PR #${PR} merged with ${BASE} ${BASE_TESTED:0:8} under a ${timeout_arg} timeout."
  set +e
  env -u GH_TOKEN -u GITHUB_TOKEN CI=true \
    timeout --kill-after=1m "$timeout_arg" bash -euo pipefail -c "$COMMAND"
  status=$?
  set -e
  if (( status == 124 || status == 137 )); then
    log "Tests timed out after ${timeout_arg} on the PR merged with ${BASE} (${BASE_TESTED:0:8}): ${RUN_URL}"
    write_summary "failed: tests (timeout)"
    exit 1
  fi
  if (( status != 0 )); then
    log "Tests failed on the PR merged with ${BASE} (${BASE_TESTED:0:8}): ${RUN_URL}"
    write_summary "failed: tests"
    exit 1
  fi
  log "Tests passed on ${BASE_TESTED:0:8}."
  write_summary "tested"
}

# merge - re-check through the API, then squash-merge exactly the tested
# commit. Write token, no PR code anywhere in this job.
cmd_merge() {
  local state head base_ref base_sha merge_out status merge_oid parent attempt
  local pending rc label_keep=0 comment
  if [[ -z ${PR:-} || -z ${HEAD_SHA:-} || -z ${BASE_TESTED:-} ]]; then
    warn "The test job reported no PR, head or tested base; not merging."
    exit 1
  fi
  state=$(gh pr view "$PR" --json state --jq '.state')
  head=$(gh pr view "$PR" --json headRefOid --jq '.headRefOid')
  base_ref=$(gh pr view "$PR" --json baseRefName --jq '.baseRefName')
  base_sha=$(gh api "repos/${GH_REPO}/git/ref/heads/${BASE}" --jq '.object.sha')
  if [[ $state != OPEN ]] || ! pr_has_label "$PR" || [[ $head != "$HEAD_SHA" ]] ||
    [[ $base_sha != "$BASE_TESTED" ]] || [[ $base_ref != "$BASE" ]]; then
    # A label added for the live head after its first run and last force-push
    # is not this stale run's to remove: the labelled run lands that head.
    if [[ $head != "$HEAD_SHA" ]]; then
      if label_after_head "$PR" "$head"; then
        label_keep=1
      else
        rc=$?
        if (( rc == 2 )); then
          warn "PR #${PR}: could not read the label and run times; leaving the label alone."
          label_keep=1
        fi
      fi
    fi
    if (( label_keep )); then
      log "PR #${PR}: head ${head:0:8} carries a newer label; leaving it for that run."
      write_summary "stopped: a newer label waits for ${head:0:8}"
      return 0
    fi
    log "PR #${PR} changed during the land run (state ${state}, head ${head:0:8}, base ${base_ref}, ${BASE} ${base_sha:0:8}); not merging."
    pr_unlabel_and_comment "$PR" \
      "PR #${PR} changed during the land run; add the \`${LABEL}\` label again to land."
    write_summary "stopped: changed during the land run"
    return 0
  fi

  set +e
  merge_out=$(gh pr merge "$PR" --squash --match-head-commit "$HEAD_SHA" 2>&1)
  status=$?
  set -e
  if (( status != 0 )); then
    if [[ $(gh pr view "$PR" --json state --jq '.state') == MERGED ]]; then
      warn "gh pr merge exited ${status} but PR #${PR} is MERGED: ${merge_out}"
    else
      pr_unlabel_and_comment "$PR" \
        "Merge failed: ${merge_out} (${RUN_URL}). Add the label again after fixing."
      write_summary "failed: merge"
      exit 1
    fi
  fi
  log "Merged PR #${PR} into ${BASE}."

  merge_oid=$(gh pr view "$PR" --json mergeCommit --jq '.mergeCommit.oid // empty') ||
    merge_oid=''

  # A merge made with GITHUB_TOKEN starts no workflows: dispatch them. These
  # come before the advisory checks below, which must never abort the job.
  if [[ -n ${IMAGE_WORKFLOW:-} ]]; then
    for attempt in 1 2 3; do
      if gh workflow run "${IMAGE_WORKFLOW}" --ref "$BASE"; then
        log "Dispatched ${IMAGE_WORKFLOW} on ${BASE}."
        break
      fi
      if (( attempt == 3 )); then
        warn "Could not dispatch ${IMAGE_WORKFLOW} on ${BASE}; the daily catch-up builds the image."
      else
        sleep 10
      fi
    done
  fi

  if [[ -n ${CALLER_WORKFLOW:-} ]]; then
    pending=$(gh pr list --base "$BASE" --label "$LABEL" --state open \
      --json number --jq 'length') || pending=1
    if (( pending > 0 )); then
      if gh workflow run "${CALLER_WORKFLOW}" --ref "$BASE"; then
        log "Dispatched ${CALLER_WORKFLOW} for the next labelled PR."
      else
        warn "Could not dispatch ${CALLER_WORKFLOW}; the next scheduled run lands the remaining PRs."
      fi
    fi
  fi

  # Advisory: the squash commit's first parent is the base it was merged onto.
  if [[ -n $merge_oid ]]; then
    parent=$(gh api "repos/${GH_REPO}/commits/${merge_oid}" --jq '.parents[0].sha') ||
      parent=''
    if [[ -n $parent && $parent != "$BASE_TESTED" ]]; then
      warn "PR #${PR} merged onto ${parent:0:8}, not the tested ${BASE_TESTED:0:8}."
      if [[ -n ${TEST_WORKFLOW:-} ]]; then
        if gh workflow run "${TEST_WORKFLOW}" --ref "$BASE"; then
          log "Dispatched ${TEST_WORKFLOW} on ${BASE}."
          comment="Merged onto untested base \`${parent:0:8}\`; the \`${TEST_WORKFLOW}\` run on \`${BASE}\` is the check."
        else
          warn "Could not dispatch ${TEST_WORKFLOW} on ${BASE}."
          comment="Merged onto untested base \`${parent:0:8}\`; \`${TEST_WORKFLOW}\` could not be dispatched, so run the tests on \`${BASE}\` yourself."
        fi
      else
        comment="Merged onto untested base \`${parent:0:8}\`; no test workflow is configured, so run the tests on \`${BASE}\` yourself."
      fi
      gh pr comment "$PR" --body "$comment" ||
        warn "Could not comment on PR #$PR."
    fi
  fi

  write_summary "merged"
  log "Done."
}

# cleanup - remove the label and comment where needed. Runs after a failure,
# a cancellation, or an invalidation select reported.
cmd_cleanup() {
  local pr msg
  if [[ -n ${INVALIDATIONS:-} ]]; then
    while IFS=$'\t' read -r pr msg; do
      [[ -n $pr ]] || continue
      pr_unlabel_and_comment "$pr" "$msg"
    done <<<"${INVALIDATIONS}"
  fi
  if [[ -z ${PR:-} ]]; then
    return 0
  fi
  if [[ ${TEST_RESULT:-} != failure && ${TEST_RESULT:-} != cancelled &&
    ${MERGE_RESULT:-} != failure && ${MERGE_RESULT:-} != cancelled ]]; then
    return 0
  fi
  if ! pr_is_open "$PR"; then
    log "PR #${PR} is not open; nothing to clean up."
    return 0
  fi
  if ! pr_has_label "$PR"; then
    log "The '${LABEL}' label is already gone from PR #${PR}; nothing to clean up."
    return 0
  fi
  # Only the prepare step's conflict comment may reach GITHUB_OUTPUT; the
  # test step that runs PR code writes nothing, so a failure there is
  # described here from the job results and RUN_URL alone.
  msg=${COMMENT:-}
  if [[ -z $msg ]]; then
    if [[ ${TEST_RESULT:-} == failure && -n ${BASE_TESTED:-} ]]; then
      msg="Tests failed or timed out on the PR merged with \`${BASE}\` (\`${BASE_TESTED:0:8}\`): ${RUN_URL} Add the \`${LABEL}\` label again after fixing."
    else
      msg="Land run failed: ${RUN_URL} Add the \`${LABEL}\` label again after fixing."
    fi
  fi
  pr_unlabel_and_comment "$PR" "$msg"
}

# ---------------------------------------------------------------------------

set_defaults() {
  LABEL=${LABEL:-ready-to-land}
  BASE=${BASE:-main}
  COMMAND=${COMMAND:-./scripts/test}
  TIMEOUT_MINUTES=${TIMEOUT_MINUTES:-45}
  IMAGE_WORKFLOW=${IMAGE_WORKFLOW:-}
  TEST_WORKFLOW=${TEST_WORKFLOW:-}
  GITHUB_RUN_ID=${GITHUB_RUN_ID:-}
  EVENT_NAME=${EVENT_NAME:-}
  EVENT_ACTION=${EVENT_ACTION:-}
  EVENT_PR=${EVENT_PR:-}
  EVENT_LABEL=${EVENT_LABEL:-}
  EVENT_HEAD_SHA=${EVENT_HEAD_SHA:-}
  RUN_URL=${RUN_URL:-}
  CALLER_WORKFLOW=${CALLER_WORKFLOW:-}
  PR=${PR:-}
  HEAD_SHA=${HEAD_SHA:-}
  BASE_TESTED=${BASE_TESTED:-}
  INVALIDATIONS=${INVALIDATIONS:-}
  COMMENT=${COMMENT:-}
  TEST_RESULT=${TEST_RESULT:-}
  MERGE_RESULT=${MERGE_RESULT:-}
  if [[ -n $CALLER_WORKFLOW ]]; then
    CALLER_WORKFLOW=$(caller_workflow_file "$CALLER_WORKFLOW")
  fi
}

main() {
  local cmd=${1:-}
  case $cmd in
    select | prepare | test | merge | cleanup) ;;
    *)
      printf 'usage: land.sh {select|prepare|test|merge|cleanup}\n' >&2
      return 2
      ;;
  esac
  set_defaults
  "cmd_${cmd}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
