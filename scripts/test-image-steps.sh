#!/usr/bin/env bash
# Tests the bash steps of .github/workflows/image.yml by extracting their run
# bodies from the YAML (by step name) and running them against a stub docker
# and an emulation of the runner's GITHUB_OUTPUT parser. The real file is
# tested, not a copy: a change to image.yml that breaks output plumbing or the
# version tag fails here.
#
#   bash scripts/test-image-steps.sh [path/to/image.yml]
#
# No network, no registry, no checkout of a caller repo. Needs python3 (the
# runner parser emulation only) and jq (the steps read digests with it).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
wf=${1:-"$repo/.github/workflows/image.yml"}

if [[ ! -f "$wf" ]]; then
  printf 'FAIL no workflow at %s\n' "$wf"
  exit 1
fi
for tool in python3 jq; do
  command -v "$tool" >/dev/null || { printf 'FAIL %s is required\n' "$tool"; exit 1; }
done

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

# expect_out FILE KEY WANT -> the parsed output KEY equals WANT, newlines
# written as \n (the emulated runner value, which never ends in a newline).
expect_out() {
  local desc=$1 file=$2 key=$3 want=$4
  local got
  if ! got=$(python3 -I "$tmp/gha_parse.py" "$file" | awk -F'\t' -v k="$key" '$1 == k { print $2 }'); then
    fail "$desc (could not parse $file)"
    return
  fi
  if [[ $got == "$want" ]]; then
    pass "$desc"
  else
    fail "$desc (got '$got', want '$want')"
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/steps" "$tmp/bin"

# The runner's GITHUB_OUTPUT parser: `name<<delim` runs to a line that is
# exactly `delim`; the value is the joined lines (no trailing newline). A
# missing delimiter is an error, which is how a step that forgets the final
# newline breaks a job. Values are printed as key<TAB>value with \n escaped.
#   python3 gha_parse.py FILE            -> key<TAB>value, newlines as \n
#   python3 gha_parse.py FILE KEY raw    -> the raw value of KEY
cat > "$tmp/gha_parse.py" <<'PY'
import sys

text = open(sys.argv[1]).read()
lines = text.split("\n")
i = 0
out = {}
while i < len(lines):
    line = lines[i]
    i += 1
    if not line:
        continue
    if "<<" in line and ("=" not in line or line.index("<<") < line.index("=")):
        key, delim = line.split("<<", 1)
        values = []
        while True:
            if i >= len(lines):
                sys.stderr.write("Matching delimiter not found '%s' for %s\n" % (delim, key))
                sys.exit(1)
            value = lines[i]
            i += 1
            if value == delim:
                break
            values.append(value)
        out[key] = "\n".join(values)
    else:
        key, value = line.split("=", 1)
        out[key] = value
if len(sys.argv) == 4 and sys.argv[3] == "raw":
    if sys.argv[2] not in out:
        sys.exit(1)
    sys.stdout.write(out[sys.argv[2]])
    sys.exit(0)
for key, value in out.items():
    sys.stdout.write("%s\t%s\n" % (key, value.replace("\n", "\\n")))
PY

# extract_step NAME -> the `run: |` body of that step, de-indented by the ten
# spaces YAML gives it. Steps sit at six spaces under a job; a blank line
# inside the block is part of it, and the block ends at the next less-indented
# line.
extract_step() {
  awk -v want="$1" '
    /^      - name: / {
      name = substr($0, index($0, "name: ") + 6)
      instep = (name == want)
      inrun = 0
      next
    }
    instep && /^        run: \|/ { inrun = 1; next }
    instep && inrun && /^[[:space:]]*$/ { print ""; next }
    instep && inrun && /^          / { print substr($0, 11); next }
    instep && inrun { inrun = 0; instep = 0 }
  ' "$wf"
}

for step in "Compute tags and source date" "Read version-file and expand build-args" \
  "Skip if the image already exists" "Add the version tag"; do
  file="$tmp/steps/${step// /_}.sh"
  extract_step "$step" > "$file"
  if [[ -s $file ]]; then
    pass "extracted step '$step' from $(basename "$wf")"
  else
    fail "extracted step '$step' from $(basename "$wf") (empty; was the step renamed?)"
  fi
done
step_file() { printf '%s/steps/%s.sh\n' "$tmp" "${1// /_}"; }

# The harness itself must catch the bug it guards against: a heredoc whose
# value ran into the delimiter (the old image.yml output plumbing).
printf 'tags<<EOF\na:sha\nb:shaEOF\n' > "$tmp/broken_output"
if python3 -I "$tmp/gha_parse.py" "$tmp/broken_output" >/dev/null 2>&1; then
  fail "the parser rejects a heredoc whose delimiter is not on its own line (expected an error)"
else
  pass "the parser rejects a heredoc whose delimiter is not on its own line"
fi

# A fake docker. EXISTING="ref=digest ..." is present with that digest;
# UNVERIFIABLE="ref ..." answers with a registry error (503); anything else is
# a positive not found. Every call is logged to $DOCKER_LOG.
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
if [[ "$1 $2 $3" == "buildx imagetools inspect" ]]; then
  ref=$4
  for r in ${UNVERIFIABLE:-}; do
    if [[ "$r" == "$ref" ]]; then
      printf 'ERROR: received unexpected status 503 Service Unavailable\n' >&2
      exit 1
    fi
  done
  for kv in ${EXISTING:-}; do
    if [[ "${kv%%=*}" == "$ref" ]]; then
      if [[ "${5:-}" == --format ]]; then printf '{"digest":"%s"}\n' "${kv#*=}"; fi
      exit 0
    fi
  done
  printf 'ERROR: %s: not found\n' "$ref" >&2
  exit 1
fi
if [[ "$1 $2 $3" == "buildx imagetools create" ]]; then
  exit 0
fi
printf 'stub docker: unexpected call: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$tmp/bin/docker"

sha=0123456789abcdef0123456789abcdef01234567
sha8=01234567
create_calls() { grep -c 'imagetools create' "$1" 2>/dev/null || true; }

# run_step STEP VAR=VAL... -> runs the extracted step in the repo checkout (the
# meta step reads the commit date with git) and returns its exit code.
run_step() {
  local name=$1
  shift
  ( cd "$repo" && env PATH="$tmp/bin:$PATH" "$@" bash "$(step_file "$name")" ) >> "$tmp/step.log" 2>&1
}

# ---------------------------------------------------------------- meta step
# No version-file: sha tags only, and the heredocs parse.
out="$tmp/meta-main.out"
: > "$out"
if run_step "Compute tags and source date" \
  GITHUB_OUTPUT="$out" GITHUB_ENV="$tmp/meta-main.env" \
  GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main \
  VISIBILITY=private IMAGE=x; then
  pass "meta step (main, private) succeeds"
else
  fail "meta step (main, private) succeeds"
  cat "$tmp/step.log" >&2
fi
expect_out "meta: private sha tags, one line each" "$out" tags \
  "harbor.teknoir.cloud/teknoir/x:sha-${sha8}\\nghcr.io/teknoir/x:sha-${sha8}"
expect_out "meta: private destinations" "$out" destinations \
  'harbor.teknoir.cloud/teknoir/x\nghcr.io/teknoir/x'
expect_out "meta: sha tag output" "$out" tag "sha-${sha8}"

out="$tmp/meta-tag.out"
: > "$out"
if run_step "Compute tags and source date" \
  GITHUB_OUTPUT="$out" GITHUB_ENV="$tmp/meta-tag.env" \
  GITHUB_SHA="$sha" GITHUB_REF=refs/tags/v1.2.3 GITHUB_REF_NAME=v1.2.3 \
  VISIBILITY=public IMAGE=x; then
  pass "meta step (tag, public) succeeds"
else
  fail "meta step (tag, public) succeeds"
  cat "$tmp/step.log" >&2
fi
expect_out "meta: public tag build pushes sha and the tag" "$out" tags \
  "ghcr.io/teknoir/x:sha-${sha8}\\nghcr.io/teknoir/x:v1.2.3"
expect_out "meta: no version tag in the build's tag list" "$out" version ''

out="$tmp/meta-badimage.out"
: > "$out"
: > "$tmp/step.log"
if run_step "Compute tags and source date" \
  GITHUB_OUTPUT="$out" GITHUB_ENV="$tmp/meta-badimage.env" \
  GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main \
  VISIBILITY=private IMAGE=$'x\nEVIL=1'; then
  fail "meta: an image name with a newline is refused (expected non-zero)"
else
  pass "meta: an image name with a newline is refused"
fi
expect_eq "meta: a refused image name writes no output" 0 \
  wc -l < "$out"

out="$tmp/meta-version.out"
: > "$out"
run_step "Compute tags and source date" \
  GITHUB_OUTPUT="$out" GITHUB_ENV="$tmp/meta-version.env" \
  GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main \
  VISIBILITY=private IMAGE=x VERSION_FILE=VERSION >/dev/null 2>&1
expect_out "meta: a version-file does not add a build tag" "$out" tags \
  "harbor.teknoir.cloud/teknoir/x:sha-${sha8}\\nghcr.io/teknoir/x:sha-${sha8}"

# ---------------------------------------------------------------- args step
printf '1.2.3\n' > "$tmp/VERSION"
out="$tmp/args-plain.out"
: > "$out"
if run_step "Read version-file and expand build-args" \
  GITHUB_OUTPUT="$out" GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main BUILD_ARGS=$'VERSION={ref}-{sha7}' TAG_BUILD_ARGS='' \
  VERSION_FILE=''; then
  pass "args step without version-file succeeds"
else
  fail "args step without version-file succeeds"
  cat "$tmp/step.log" >&2
fi
expect_out "args: templated build-args, no version" "$out" build_args "VERSION=main-0123456"
expect_out "args: empty version without version-file" "$out" version ''

out="$tmp/args-version.out"
: > "$out"
if run_step "Read version-file and expand build-args" \
  GITHUB_OUTPUT="$out" GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main BUILD_ARGS=$'VERSION={version}\nCOMMIT={sha8}' \
  TAG_BUILD_ARGS='' VERSION_FILE="$tmp/VERSION"; then
  pass "args step with version-file succeeds"
else
  fail "args step with version-file succeeds"
  cat "$tmp/step.log" >&2
fi
expect_out "args: {version} and a second line survive the output heredoc" "$out" build_args \
  "VERSION=1.2.3\\nCOMMIT=${sha8}"
expect_out "args: version" "$out" version '1.2.3'
expect_out "args: version tag" "$out" version_tag '1.2.3'

# `+build` metadata: the build-arg keeps '+', the image tag is safe_tag-mapped.
printf '1.2.3+build.1\n' > "$tmp/VERSION_PLUS"
out="$tmp/args-plus.out"
: > "$out"
run_step "Read version-file and expand build-args" \
  GITHUB_OUTPUT="$out" GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main BUILD_ARGS='VERSION={version}' TAG_BUILD_ARGS='' \
  VERSION_FILE="$tmp/VERSION_PLUS" >/dev/null 2>&1
expect_out "args: +build keeps '+' in the build-arg" "$out" build_args 'VERSION=1.2.3+build.1'
expect_out "args: +build maps to '-' in the image tag" "$out" version_tag '1.2.3-build.1'

# tag-build-args: merged over build-args on a tag, ignored on a branch.
out="$tmp/args-tag.out"
: > "$out"
if run_step "Read version-file and expand build-args" \
  GITHUB_OUTPUT="$out" GITHUB_SHA="$sha" GITHUB_REF=refs/tags/v1.2.3 \
  GITHUB_REF_NAME=v1.2.3 BUILD_ARGS=$'VERSION={ref}-{sha7}\nOTHER=kept' \
  TAG_BUILD_ARGS='VERSION={ref}' VERSION_FILE=''; then
  pass "args step on a tag with tag-build-args succeeds"
else
  fail "args step on a tag with tag-build-args succeeds"
  cat "$tmp/step.log" >&2
fi
expect_out "args: tag-build-args wins for its key, keeps the other line" "$out" build_args \
  'VERSION=v1.2.3\nOTHER=kept'

out="$tmp/args-branch.out"
: > "$out"
run_step "Read version-file and expand build-args" \
  GITHUB_OUTPUT="$out" GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main BUILD_ARGS='VERSION={ref}-{sha7}' \
  TAG_BUILD_ARGS='VERSION={ref}' VERSION_FILE='' >/dev/null 2>&1
expect_out "args: tag-build-args ignored on a branch" "$out" build_args 'VERSION=main-0123456'

out="$tmp/args-unknown.out"
: > "$out"
if run_step "Read version-file and expand build-args" \
  GITHUB_OUTPUT="$out" GITHUB_SHA="$sha" GITHUB_REF=refs/tags/v1.2.3 \
  GITHUB_REF_NAME=v1.2.3 BUILD_ARGS='A=1' TAG_BUILD_ARGS='VERSION={tag}' \
  VERSION_FILE=''; then
  fail "args: an unknown placeholder in tag-build-args fails the step"
else
  if grep -q '::error::unknown build-args placeholders: {tag} (tag-build-args)' "$tmp/step.log"; then
    pass "args: an unknown placeholder in tag-build-args fails the step"
  else
    fail "args: an unknown placeholder in tag-build-args fails the step (no ::error:: naming it)"
  fi
fi

out="$tmp/args-longversion.out"
printf '%s\n' "1.2.3-$(printf 'a%.0s' $(seq 1 200))" > "$tmp/VERSION_LONG"
: > "$out"
run_step "Read version-file and expand build-args" \
  GITHUB_OUTPUT="$out" GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main BUILD_ARGS='' TAG_BUILD_ARGS='' \
  VERSION_FILE="$tmp/VERSION_LONG" >/dev/null 2>&1
expect_eq "args: an over-long version is capped at 128 characters" 128 \
  python3 -I -c 'import sys
for line in sys.stdin.buffer.read().split(b"\n"):
    if line.startswith(b"version_tag="):
        print(len(line.split(b"=", 1)[1]))
        break' < "$out"

# ---------------------------------------------------------- version-tag step
# Pass 1 reads every destination before writing, so one registry error stops
# the step with nothing created; pass 2 creates only what a registry
# positively reported missing.
vtag_common=(VERSION=1.2.3 VERSION_TAG=1.2.3 TAG="sha-${sha8}")

out="$tmp/vtag-ok.log"
: > "$out"
if run_step "Add the version tag" \
  DOCKER_LOG="$out" \
  EXISTING="harbor.teknoir.cloud/teknoir/x:sha-${sha8}=sha256:aaa ghcr.io/teknoir/x:sha-${sha8}=sha256:bbb" \
  UNVERIFIABLE='' \
  DESTINATIONS=$'harbor.teknoir.cloud/teknoir/x\nghcr.io/teknoir/x' \
  "${vtag_common[@]}"; then
  pass "version-tag: every destination missing the version tag succeeds"
else
  fail "version-tag: every destination missing the version tag succeeds"
  tail -20 "$tmp/step.log" >&2
fi
expect_eq "version-tag: creates the version tag in both destinations" 2 create_calls "$out"
expect_eq "version-tag: harbor version tag from harbor's sha tag" 1 \
  grep -c 'create -t harbor.teknoir.cloud/teknoir/x:1.2.3 harbor.teknoir.cloud/teknoir/x:sha-01234567' "$out"
expect_eq "version-tag: ghcr version tag from ghcr's sha tag" 1 \
  grep -c 'create -t ghcr.io/teknoir/x:1.2.3 ghcr.io/teknoir/x:sha-01234567' "$out"

# Finding 11: harbor has the version tag, ghcr does not; the sha tag exists
# in both. ghcr's version tag is still created from ghcr's own sha tag.
out="$tmp/vtag-partial.log"
: > "$out"
if run_step "Add the version tag" \
  DOCKER_LOG="$out" \
  EXISTING="harbor.teknoir.cloud/teknoir/x:1.2.3=sha256:aaa harbor.teknoir.cloud/teknoir/x:sha-${sha8}=sha256:aaa ghcr.io/teknoir/x:sha-${sha8}=sha256:aaa" \
  UNVERIFIABLE='' \
  DESTINATIONS=$'harbor.teknoir.cloud/teknoir/x\nghcr.io/teknoir/x' \
  "${vtag_common[@]}"; then
  pass "version-tag: one destination already tagged, the other still created"
else
  fail "version-tag: one destination already tagged, the other still created"
  tail -20 "$tmp/step.log" >&2
fi
expect_eq "version-tag: only the missing destination gets a create" 1 create_calls "$out"
expect_eq "version-tag: the created tag is ghcr's" 1 \
  grep -c 'create -t ghcr.io/teknoir/x:1.2.3' "$out"
expect_eq "version-tag: the existing tag is not touched" 0 \
  grep -c 'create -t harbor.teknoir.cloud/teknoir/x:1.2.3' "$out"

# Same digest everywhere: nothing to do.
out="$tmp/vtag-same.log"
: > "$out"
if run_step "Add the version tag" \
  DOCKER_LOG="$out" \
  EXISTING="harbor.teknoir.cloud/teknoir/x:1.2.3=sha256:aaa harbor.teknoir.cloud/teknoir/x:sha-${sha8}=sha256:aaa" \
  UNVERIFIABLE='' DESTINATIONS='harbor.teknoir.cloud/teknoir/x' "${vtag_common[@]}"; then
  pass "version-tag: an existing tag with this commit's digest is a no-op"
else
  fail "version-tag: an existing tag with this commit's digest is a no-op"
fi
expect_eq "version-tag: no create when the digest matches" 0 create_calls "$out"

# Different digest: warn, leave it.
out="$tmp/vtag-diff.log"
: > "$out"
run_step "Add the version tag" \
  DOCKER_LOG="$out" \
  EXISTING="harbor.teknoir.cloud/teknoir/x:1.2.3=sha256:old harbor.teknoir.cloud/teknoir/x:sha-${sha8}=sha256:new" \
  UNVERIFIABLE='' DESTINATIONS='harbor.teknoir.cloud/teknoir/x' "${vtag_common[@]}" >/dev/null 2>&1
expect_eq "version-tag: a different digest is never overwritten" 0 create_calls "$out"
expect_eq "version-tag: a different digest warns" 1 \
  grep -c '::warning::harbor.teknoir.cloud/teknoir/x:1.2.3 already exists with digest sha256:old' "$tmp/step.log"

# Finding 10: a registry error is not 'absent'. The first destination's read
# fails, so nothing (not even the second destination) is created.
out="$tmp/vtag-flaky.log"
: > "$out"
if run_step "Add the version tag" \
  DOCKER_LOG="$out" \
  EXISTING="harbor.teknoir.cloud/teknoir/x:sha-${sha8}=sha256:aaa ghcr.io/teknoir/x:sha-${sha8}=sha256:aaa" \
  UNVERIFIABLE='harbor.teknoir.cloud/teknoir/x:1.2.3' \
  DESTINATIONS=$'harbor.teknoir.cloud/teknoir/x\nghcr.io/teknoir/x' \
  "${vtag_common[@]}"; then
  fail "version-tag: a registry error fails the step (expected non-zero)"
else
  pass "version-tag: a registry error fails the step"
fi
expect_eq "version-tag: a registry error creates nothing" 0 create_calls "$out"
expect_eq "version-tag: a registry error is an ::error::, not 'absent'" 1 \
  grep -c '::error::cannot verify harbor.teknoir.cloud/teknoir/x:1.2.3' "$tmp/step.log"

# The sha tag this commit should have is missing: cannot tag from it.
out="$tmp/vtag-nosha.log"
: > "$out"
: > "$tmp/step.log"
if run_step "Add the version tag" \
  DOCKER_LOG="$out" UNVERIFIABLE='' EXISTING='' \
  DESTINATIONS='harbor.teknoir.cloud/teknoir/x' "${vtag_common[@]}"; then
  fail "version-tag: a missing sha tag fails the step (expected non-zero)"
else
  pass "version-tag: a missing sha tag fails the step"
fi
expect_eq "version-tag: nothing is created from a missing sha tag" 0 create_calls "$out"

# ------------------------------------------------------------ skip step
# The public v* tag is backfilled from the sha tag when the sha tag exists;
# a registry error on it fails closed instead of creating the tag.
out="$tmp/skip-ok.log"
gha="$tmp/skip-ok.out"
: > "$out"
: > "$gha"
if run_step "Skip if the image already exists" \
  DOCKER_LOG="$out" GITHUB_OUTPUT="$gha" \
  EXISTING="ghcr.io/teknoir/x:sha-${sha8}=sha256:aaa" UNVERIFIABLE='' \
  FIRST_DESTINATION=ghcr.io/teknoir/x TAG="sha-${sha8}" \
  TAGS=$'ghcr.io/teknoir/x:sha-'"${sha8}"$'\nghcr.io/teknoir/x:v1.2.3'; then
  pass "skip step: existing sha tag backfills the ref tag"
else
  fail "skip step: existing sha tag backfills the ref tag"
  cat "$tmp/step.log" >&2
fi
expect_out "skip step: exists=true and the digest" "$gha" exists 'true'
expect_out "skip step: digest read back" "$gha" digest 'sha256:aaa'
expect_eq "skip step: the missing ref tag is created from the sha tag" 1 \
  grep -c 'create -t ghcr.io/teknoir/x:v1.2.3 ghcr.io/teknoir/x:sha-01234567' "$out"

out="$tmp/skip-new.log"
gha="$tmp/skip-new.out"
: > "$out"
: > "$gha"
run_step "Skip if the image already exists" \
  DOCKER_LOG="$out" GITHUB_OUTPUT="$gha" EXISTING='' UNVERIFIABLE='' \
  FIRST_DESTINATION=ghcr.io/teknoir/x TAG="sha-${sha8}" \
  TAGS="ghcr.io/teknoir/x:sha-${sha8}" >/dev/null 2>&1
expect_out "skip step: no sha tag means the build runs" "$gha" exists 'false'

out="$tmp/skip-flaky.log"
gha="$tmp/skip-flaky.out"
: > "$out"
: > "$gha"
: > "$tmp/step.log"
if run_step "Skip if the image already exists" \
  DOCKER_LOG="$out" GITHUB_OUTPUT="$gha" EXISTING='' \
  UNVERIFIABLE="ghcr.io/teknoir/x:sha-${sha8}" \
  FIRST_DESTINATION=ghcr.io/teknoir/x TAG="sha-${sha8}" \
  TAGS="ghcr.io/teknoir/x:sha-${sha8}" >/dev/null 2>&1; then
  fail "skip step: a registry error fails closed (expected non-zero)"
else
  pass "skip step: a registry error fails closed"
fi
expect_eq "skip step: a registry error does not report a missing image" 0 \
  grep -c '^exists=' "$gha"

# ------------------------------------------------------------ end to end
# The image job's outputs feed the version-tag job, as the workflow wires them
# (jobs.image.outputs.* -> needs.image.outputs.*).
out_value() { python3 -I "$tmp/gha_parse.py" "$1" "$2" raw; }

meta="$tmp/e2e-meta.out"
args_out="$tmp/e2e-args.out"
log="$tmp/e2e.log"
: > "$meta"
: > "$args_out"
: > "$log"
: > "$tmp/step.log"
if run_step "Compute tags and source date" \
  GITHUB_OUTPUT="$meta" GITHUB_ENV="$tmp/e2e.env" \
  GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main \
  VISIBILITY=private IMAGE=x &&
  run_step "Read version-file and expand build-args" \
    GITHUB_OUTPUT="$args_out" GITHUB_SHA="$sha" GITHUB_REF=refs/heads/main \
    GITHUB_REF_NAME=main BUILD_ARGS='VERSION={version}' TAG_BUILD_ARGS='' \
    VERSION_FILE="$tmp/VERSION" &&
  run_step "Add the version tag" \
    DOCKER_LOG="$log" UNVERIFIABLE='' \
    EXISTING="harbor.teknoir.cloud/teknoir/x:sha-${sha8}=sha256:aaa ghcr.io/teknoir/x:sha-${sha8}=sha256:aaa" \
    VERSION="$(out_value "$args_out" version)" \
    VERSION_TAG="$(out_value "$args_out" version_tag)" \
    TAG="$(out_value "$meta" tag)" \
    DESTINATIONS="$(out_value "$meta" destinations)"; then
  pass "end to end: meta -> args -> version-tag (private, version-file)"
else
  fail "end to end: meta -> args -> version-tag (private, version-file)"
  tail -20 "$tmp/step.log" >&2
fi
expect_eq "end to end: both destinations get the version tag" 2 create_calls "$log"
expect_eq "end to end: the tag comes from VERSION (1.2.3) in each destination" 2 \
  grep -cE 'create -t (harbor\.teknoir\.cloud/teknoir|ghcr\.io/teknoir)/x:1\.2\.3 ' "$log"

# ----------------------------------------------------------------- report
printf '\n%d tests, %d failures\n' "$tests" "$failures"
[[ $failures -eq 0 ]]
