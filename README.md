# ci-workflows

Shared reusable GitHub Actions workflows for Teknoir repos, referenced as
`teknoir/ci-workflows/.github/workflows/<name>.yml@main`. Design:
`plans/cicd/proposal-v4.md` (CI/CD v4).

The repo is public, so every repo can call it and the reusable workflows can
check it out with the default token. `main` is protected by a ruleset, so `@main`
is the pin: one PR fixes CI for every repo. A reusable workflow reads scripts of
this repo by checking it out at `main` into `.ci-workflows/`.

## Runner sets

| Runs on | Where | Used by |
| --- | --- | --- |
| `teknoir-ci` | ARC on devhost-ci (self-hosted) | `test.yml` for private repos |
| `teknoir-land` | ARC on devhost-ci | `land.yml` |
| `teknoir-push` | ARC on devhost-ci | `image.yml` for private repos |
| `ubuntu-latest` | GitHub-hosted | public repos, `chart-release.yml` for public chart repos, this repo's own `lint.yml`/`watch.yml` |

`runs-on:` is the ARC scale-set name. Private-repo jobs must never run on a
hosted runner (and vice versa): the `teknoir-push` runner refuses every ref
except `refs/heads/main` (tags included); a release re-tags the digest built on
`main` later. There is no GitHub cache or artifact step: runners keep caches on
host paths, or on a per-job `emptyDir` (`land.yml` keeps `GOMODCACHE`,
`GOCACHE`, `YARN_CACHE_FOLDER` and `npm_config_cache` on `/scratch`, which
starts empty for every job, so no other job's cache is ever reused).

## Workflows

### `test.yml` (reusable)

Runs one test command. Inputs: `runs-on` (default `teknoir-ci`), `command`
(default `./scripts/test`), `go-version-file` and `node-version-file` (empty
skips the toolchain), `setup-envtest` (boolean), `envtest-version` (the
`setup-envtest` release tag to install, default `release-0.22`; the binaries
land in `/cache/tool-cache/envtest` and `KUBEBUILDER_ASSETS` is exported for
Kubernetes 1.34), `timeout-minutes` (30), `lfs`, `working-directory` (`.`).
Caller permissions: `contents: read`.
`CI=true` is set; `CLAUDECODE`/`AI_AGENT` are not, so test scripts stay loud.

### `land.yml` (reusable) - the merge gate

Private repos have no branch protection on GitHub Free, so this workflow is the
gate. It runs as three jobs so that PR code never runs with a write token:

| Job | Token | Does |
| --- | --- | --- |
| `test` | `contents: read`, `pull-requests: read`, `actions: read` | `select` picks the PR and checks state, label, base, head and Dependabot metadata; `prepare` checks the head out and merges the base (writes `base_tested`, and `comment` for a conflict); then setup-go/node/envtest read the version files from that tree; `test` runs `command` under `timeout --kill-after=1m` at `timeout-minutes - 5` and writes nothing |
| `merge` | `contents: write`, `pull-requests: write`, `actions: write` | no PR checkout: re-checks through the API and squash-merges exactly the tested commit, then dispatches |
| `cleanup` | `pull-requests: write` | removes the label and comments on a failed or cancelled run, and for the invalidations `test` found |

The caller repo is checked out with `persist-credentials: false`; the `test`
job's fetches authenticate on the command line in the select step, and the
`prepare` and `test` steps run with `env -u GH_TOKEN -u GITHUB_TOKEN` (the
`test` step runs PR code, so it also writes no step outputs: the cleanup job
builds a test-failure comment from the job results and the run URL). The
runner has no shared cache — `GOMODCACHE`, `GOCACHE`, `YARN_CACHE_FOLDER` and
`npm_config_cache` point at the job's own `/scratch` — and setup-envtest is
installed into that `GOMODCACHE`. Inputs: `runs-on` (`teknoir-land`), `label`
(`ready-to-land`), `command`, `go-version-file`, `node-version-file`,
`setup-envtest`, `envtest-version` (`release-0.22`), `timeout-minutes` (45),
`image-workflow` (dispatched on the base branch after the merge, usually
`image.yml`), `test-workflow` (dispatched on the base branch when the merge
lands on a base that was not tested, usually `test.yml`; empty: no dispatch),
`base` (`main`), `ci-workflows-ref` (`main`; the ref whose `scripts/land.sh` runs, keep it equal to your `uses:` ref; change it only to test a branch).
Caller permissions: `contents: write`, `pull-requests: write`,
`actions: write`.

Behaviour (logic in `scripts/land.sh`, tested by `scripts/test-land.sh`):

1. **Only the labelled tree lands.** A `labeled` run lands the PR in the event
   only if its live head is still the labelled head, and only if the PR targets
   `base` (a PR aimed elsewhere is unlabelled with "this PR targets `<base>`;
   land.yml lands only into `<base>`"). Scheduled and manual sweeps land the
   **oldest** open labelled PR against `base`, and only when the label was
   added *after* the head's first run appeared **and** after the last
   `head_ref_force_pushed` event (GitHub-assigned times, `actions: read` and
   `pull-requests: read`). A head with no run, or a label older than the head
   or the force-push, is unlabelled with "new commits after the label; add it
   again to land"; when the API answers cannot be read the label is left alone.
2. **Every event re-checks:** a PR that is not open or no longer carries the
   label is skipped.
3. New commits on a labelled PR (`synchronize`/`reopened`) remove the label
   and comment, unless the newest label is **newer than the run's `created_at`**
   — then that labelled run owns the head and this one leaves the label. A
   label event for another label is ignored.
4. Drafts are skipped (label removed, comment, exit 0).
5. **Dependabot decides from GitHub-assigned data**, never from the client-set
   author name or the PR text: the `gh pr view` author must be `dependabot[bot]`
   (a failed call refuses), every commit from `gh api .../pulls/<n>/commits`
   must be `true<TAB>dependabot[bot]` (verified signature, failed or empty call
   refuses), the `updated-dependencies:` block must have **one** `update-type:`
   line per entry and none of them `version-update:semver-major`, and no
   dependency whose version starts with `0.` unless the commit message has a
   from/to pair on a line naming that exact dependency (the four Dependabot
   forms) that keeps the minor version. A `(truncated)` body, or an entry count
   that differs from the `N` of "... with N updates", refuses too. A refused
   Dependabot PR is unlabelled with a comment and needs a person.
6. Merge conflicts, test failures, timeouts and a `merge` that fails without
   the PR being MERGED remove the label and comment with the run link.
7. **Before the merge the `merge` job re-checks everything through the API**:
   PR still `OPEN`, label still present, `headRefOid` still the tested head,
   `baseRefName` still the base, and the base branch still at `base_tested`.
   Any mismatch unlabels, comments ("changed during the land run; add the label
   again to land") and exits 0 — unless the live head carries a newer label
   (newer than its first run and its last force-push), which belongs to the
   run that label started: then it logs, writes the summary and exits 0 without
   unlabelling.
   `gh pr merge --squash --match-head-commit <tested head>` (no
   `--delete-branch`: the repo setting deletes branches). A gh error with the
   PR actually MERGED warns and continues.
8. After the merge it dispatches `image-workflow` (3 tries, warning only on
   failure) and then the caller's land workflow again if another labelled PR is
   waiting. A merge made with `GITHUB_TOKEN` starts no push workflows, which is
   why the dispatch is needed. The dispatches run before the advisory parent
   check, and that check and the pending count can never fail the job (a gh
   error leaves the value empty and the check is skipped). If the merge commit's
   first parent differs from `base_tested`, the run warns, dispatches
   `test-workflow` on the base (when set) and comments that the merge went onto
   an untested base and names that run — or says no test workflow is
   configured. There is no label removal after a successful merge.

Caller triggers: `pull_request` types `[labeled, synchronize, reopened]`,
`schedule` every 15 min, `workflow_dispatch`. The concurrency group keeps the
serial land group for the events that may land (`labeled` for
`ready-to-land`, the schedule, a manual run) and gives the non-landing ones
their own per-PR group, so they never queue behind a land or replace one — a
`labeled` event for any other label must not cancel a pending landing:

```yaml
concurrency:
  group: ${{ github.event_name == 'pull_request' && (github.event.action != 'labeled' || github.event.label.name != 'ready-to-land') && format('land-sync-{0}-{1}', github.repository, github.event.pull_request.number) || format('land-{0}', github.repository) }}
  cancel-in-progress: false
```

**Who may add the label:** integrating Opus sessions acting as Anders, after
review. DeepSeek, haiku and sonnet sessions never add it or merge. The label
plus a merge ship to staging (`main` is what Kargo verifies).

### `image.yml` (reusable)

Builds one image and pushes `sha-<8>`:

- **private:** from `refs/heads/main` **only** (the `teknoir-push` runner
  refuses every other ref, tags included), to
  `harbor.teknoir.cloud/teknoir/<image>` **and** `ghcr.io/teknoir/<image>` in
  the same push (same digest), with no second tag. A release re-tags the digest
  built on main later with `docker buildx imagetools create`; that is not part
  of this round.
- **public:** from `refs/heads/main`, or from a `refs/tags/v*` tag that is an
  ancestor of `origin/main`, to public `ghcr.io/teknoir/<image>`; a tag also
  pushes `:<tag name>`.

`latest` and branch-name tags are refused. The build is skipped when the
`sha-<8>` tag already exists, and any other tag in the list that is missing is
then created from it (a registry error while checking is an `::error::` and
fails the job rather than rebuilding). The one exception is a tag build with
`tag-build-args` set: it pushes no `sha-<8>` and is checked on its tag name
instead (see `tag-build-args` below). `image` must be a lowercase repository
name without registry or tag (`backstage`, `toe-app`), since the destinations
are `<registry>/teknoir/<image>`. Inputs: `image` (required), `context`, `file`,
`platforms` (`linux/amd64`), `target`, `build-args`, `tag-build-args`,
`version-file`,
`empty-files` (empty placeholder files to create, one relative path per line; allowed on private builds), `pre-build` (public
builds only; a private build with `pre-build` fails in the ref step), `lfs`,
`visibility` (`private`/`public`), `runs-on` (`teknoir-push`),
`timeout-minutes` (60).

The build and push step pushes only the `sha-<8>` tag (and, on a public `v*`
build, the tag name; on a tag build with `tag-build-args`, the tag name only).
The `version-file` tag is added afterwards, by the separate `version-tag` job
(below).
Every image carries the OCI labels `org.opencontainers.image.revision` (the
built commit) and `org.opencontainers.image.source` (the repository URL), set
by the workflow over any Dockerfile `LABEL` of the same name.

**Templated `build-args`.** A `build-args` value may use placeholders, with the
same `KEY=VALUE` per-line format:

| Placeholder | Expands to |
| --- | --- |
| `{sha8}` | first 8 characters of `GITHUB_SHA` |
| `{sha7}` | first 7 characters of `GITHUB_SHA` |
| `{sha}` | full `GITHUB_SHA` |
| `{ref}` | `GITHUB_REF_NAME` with `/` replaced by `-` (e.g. `feature-x`, `v1.2.3`) |
| `{version}` | the trimmed content of `version-file` (needs `version-file`) |

The expansion runs in a bash step and the result is what reaches the build;
the raw input is never interpolated into `run:` (it arrives through `env:`).
An unknown `{placeholder}`, or `{version}` without `version-file`, fails the job
with `::error::` naming the placeholder. The helpers live in
`.github/workflows/image.yml` (inline copies, one per bash step) and
`scripts/image-lib.sh`, which must stay identical (`lint.yml` diffs every copy;
`scripts/test-image-lib.sh` and `scripts/test-image-steps.sh` test them).

**`tag-build-args`.** Same format and placeholders as `build-args`, merged
over it when the ref is a tag (`refs/tags/*`), so a tag build can bake a
different version string into the binary (vpro's `tagBuildArgs`). A key in
both keeps the `tag-build-args` value; a key only in `tag-build-args` is
appended. On a branch, `tag-build-args` is ignored.

When it is non-empty on a tag, the tag build pushes **only** `<dest>:<tag>`
and never `sha-<8>` (vpro's `keep_ref`), so the branch artifact stays
immutable and the tag's build args really reach the released binary. The
`<dest>:<sha-<8>>` shortcut is not used for such a build: each destination's
`<dest>:<tag>` is checked with the tri-state helper instead.

| `<dest>:<tag>` on the destinations | Result |
| --- | --- |
| absent everywhere | build and push `:<tag>` with the tag's merged args |
| present in every destination | skip the build (existing content is never overwritten) |
| present in some, absent in others | `::error::`, job fails; one release is never split across destinations |
| any read error | `::error::`, fails closed |

The image job's `tag` output is the tag name on such a build, so the
`version-tag` job tags `:<version>` from `:<tag>`.

```yaml
# wg-hub (vpro: repos/wg-tunnel.yaml): the tag build bakes VERSION=v1.2.3
# and pushes only :v1.2.3; a branch build bakes VERSION=main-abc1234 in
# sha-<8>
    with:
      image: wg-hub
      context: .
      target: wg-hub
      platforms: linux/amd64,linux/arm64
      visibility: public
      runs-on: ubuntu-latest
      build-args: |
        VERSION={ref}-{sha7}
      tag-build-args: |
        VERSION={ref}
```

**`version-file`.** When set, the file (at the checked-out sha) must hold
`^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$`, e.g. `1.2.3` or
`1.2.3-rc.1`; anything else fails the job. `{version}` is the raw trimmed
content. The image tag is that value mapped the way vpro's `safe_tag` mapped
it: every character outside `[A-Za-z0-9_.-]` becomes `-` (so `1.2.3+build.1`
tags as `1.2.3-build.1`) and the result is capped at 128 characters. The
`version-tag` job then adds `:<version>` to **every** destination.

A version names an immutable release, so the `version-tag` job checks each
destination separately, and fails closed: a registry answer that is not a
positive "not found" (`429`, `5xx`, auth error, timeout) is an `::error::` and
fails the job rather than being read as "missing".

| State of `<dest>:<version>` across the destinations | Result |
| --- | --- |
| absent everywhere | each created from its own `<dest>:sha-<8>` (or `<dest>:<tag>` on a tag build with `tag-build-args`) |
| present somewhere, one digest | missing ones created from that digest (`imagetools create -t <dest>:<version> <present_dest>@<digest>`); present ones untouched |
| present somewhere with one digest, which this commit's tag does not share | `::warning::` (the version belongs to another commit), nothing overwritten; the missing destinations still get the existing digest |
| present with different digests on different destinations | `::error::` naming both digests, job fails, nothing written |
| any read error | `::error::`, job fails, nothing written |

The present digest is the release's content: a later commit that still carries
the same version never changes what `:<version>` means, it only fills in a
destination an earlier run left out.

The job runs only when `version-file` is set and the `image` job succeeded
(built or skipped), in a per-image, per-version concurrency group
(`ci-workflows-image-version-<repo>-<image>-<version>`,
`cancel-in-progress: false`), so two commits carrying the same version never
both create it. GitHub keeps one pending job per group: a newer run for the
same version can replace a pending one (it checks the same tag, and creates it
only where it is still absent), while runs for different versions are in
different groups and never cancel each other.

```yaml
# profile-plugins-helm stunnel (vpro: repos/profile-plugins-helm.yaml):
# images/stunnel/VERSION holds e.g. 1.2.3
    with:
      image: stunnel
      context: images/stunnel
      file: images/stunnel/Dockerfile
      platforms: linux/amd64,linux/arm64
      visibility: public
      runs-on: ubuntu-latest
      version-file: images/stunnel/VERSION
      build-args: |
        VERSION={version}
```
Caller permissions: `contents: read`, `packages: write`.
Outputs: `digest` (from the build, or read back from the existing image when
the build was skipped), `tag` (`sha-<8>`, or the tag name on a tag build with
`tag-build-args`).

The checkout keeps no credentials on disk (`persist-credentials: false`); the
one fetch (`git fetch --no-tags origin main`, for the ancestor check of a
public `v*` tag) runs only in that branch, where the repository is public and
an anonymous fetch works.

Private builds use the shared remote BuildKit (`BUILDKIT_HOST` is set in the
`teknoir-push` runner pod; the job fails with a clear message if it is empty)
and the Harbor push robot credentials (`HARBOR_USERNAME`/`HARBOR_PASSWORD`,
also from the runner pod). One `run` step reads them straight from the job's
environment, masks the password and pipes it to `docker login
--password-stdin`; nothing is written to `GITHUB_ENV`, `GITHUB_OUTPUT`, a
`with:` block or an `env:` block. Builds are reproducible: `SOURCE_DATE_EPOCH`
comes from the commit date and the exporter rewrites timestamps.
`--platform=$BUILDPLATFORM` cross-compiles Go; other multi-arch builds add
`docker/setup-qemu-action` (public only) and need `timeout-minutes: 90`.

### `chart-release.yml` (reusable)

Publishes every chart with chart-releaser (`skip_existing`). The prerelease
version check reads each chart's `version:` in `<charts-dir>/<chart>/Chart.yaml`
(the layout chart-releaser packages; subcharts under `<chart>/charts` are
packaging input, not releases). A published chart version is never changed or
deleted; bump the version.

**Refs.** Releases come from `release-branch` (default `main`);
`prerelease-branch` (default empty, e.g. `beta`) adds a second accepted ref.
Any other ref fails with `::error::`. The first step classifies the run:

- **Release branch:** as in vpro, no version check: the branch publishes
  whatever versions its charts carry. `ros-helm`, `triton-helm`, `deadend-helm`
  and `trust-chain-helm` release prerelease versions (`0.3.0-rc.1`,
  `0.0.0-alpha.3`) from `main` and rely on this.
- **Prerelease branch:** with `prerelease-version-check` (default `true`) every
  chart version must match `X.Y.Z-something` (`^[0-9]+\.[0-9]+\.[0-9]+-.+`),
  else the job fails naming the chart and version. The release is marked
  not-latest (`mark_as_latest: false`) so a beta never becomes the chart repo's
  latest version. Set `prerelease-version-check: false` for a repo whose beta
  branch releases versions without a prerelease suffix (`observatory-pipeline-helm`
  did this in vpro).

Concurrency is per ref: `ci-workflows-chart-release-<repo>-<ref>`,
`cancel-in-progress: false`, so release and prerelease runs of one branch
never overlap (both push gh-pages) and a run on one branch can never replace a
pending run on the other. GitHub still keeps only one pending job per group: a
newer push on the same branch can replace a pending run, so that run never
executes. The next push usually catches up (chart-releaser packages the charts
changed since the last tag); if a release is missing after that, rerun the
workflow with `workflow_dispatch` on that branch. Main and beta can now push
gh-pages at the same time; if a simultaneous index push makes chart-releaser's
index step fail (its `git pull` aborts), the job checks that every package of
this run already has its uploaded release, refreshes `origin/gh-pages` and runs
only `cr index --push` again (up to 3 times, 15/30/45 s apart), from the same
package files, so the index digest matches the uploaded asset. A successful
retry leaves the run green. Any other chart-releaser failure (packaging,
upload) is not retried and the run is red: fix the cause and rerun at the same
sha (a newer commit does not repackage that chart); rerunning is safe.

Inputs: `charts-dir` (`charts`), `runs-on` (`ubuntu-latest`), `helm-version`
(`v3.19.0`), `release-branch` (`main`), `prerelease-branch` (empty),
`prerelease-version-check` (`true`). Caller permissions: `contents: write`.

Chart repo caller (`examples/chart/chart-release.yml`):

```yaml
on:
  push:
    branches: [main, beta]

jobs:
  chart-release:
    uses: teknoir/ci-workflows/.github/workflows/chart-release.yml@main
    with:
      charts-dir: charts
      release-branch: main
      prerelease-branch: beta
    permissions:
      contents: write
```

A beta chart must then carry a prerelease version, e.g.:

```yaml
# charts/my-chart/Chart.yaml
version: 1.2.3-beta.1
```

A repo releasing from a `release` branch (line-crossings) sets
`release-branch: release` (and no `prerelease-branch`). A private chart repo
must also pass `runs-on: teknoir-ci`: it must never run on a hosted runner.

### `lint.yml` (this repo)

PR and `main` check. Job name is exactly `actionlint` (a ruleset requires that
check name): actionlint on every workflow including `examples/`, shellcheck on
`scripts/*.sh`, `bash scripts/test-land.sh`, `bash scripts/test-image-lib.sh`,
`bash scripts/test-image-steps.sh` (the bash steps of `image.yml`, extracted
from the YAML, against a stub registry and an emulation of the runner's
`GITHUB_OUTPUT` parser), and a diff of every inline `image-lib` copy in
`image.yml` against `scripts/image-lib.sh`.

### `watch.yml` (this repo)

Daily (06:17 UTC) check of the `actions-runner` image pinned in
`teknoir/platform-applications-gitops` `charts/ci-runners/arc/teknoir-ci.yaml`,
`teknoir-land.yaml` and `teknoir-push.yaml`; the oldest of the three pins is
the one compared, since GitHub retires runners by image age. A fetch or parse
failure is an `::error::` and fails the run. GitHub stops queuing jobs on
runners about 30 days old; when the pin is more than 21 days behind
`actions/runner`, it opens (or comments on) an issue labelled `ci-alert` with
the bump procedure, and closes stale ones.

## Caller examples

`examples/` holds complete caller files, copied unchanged into a repo's
`.github/workflows/`:

- `private-go/`: `go-version-file: go.mod`, `make test`.
- `private-node/`: `node-version-file: .nvmrc`, `./scripts/test`.
- `public/`: `runs-on: ubuntu-latest`, `visibility: public`, the only
  `image.yml` example that triggers on `v*` tags; no `land.yml` (public repos
  merge with `gh pr merge --auto --squash` under a ruleset).

The private `land.yml` examples carry the concurrency group above and set
`test-workflow: test.yml`. The private `image.yml` examples trigger on `main`
only: private releases re-tag a digest built on `main`, so a `v*` push has
nothing to build.

`<repo-name>` in the `image.yml` examples is a placeholder: set the image
repository name. Callers always pin `@main`.

## Running a caller locally

On demand only, for whoever edits a workflow:

```
act -W .github/workflows/test.yml
```

`~/.actrc` maps the runner labels to `ghcr.io/catthehacker/ubuntu:act-24.04`.
`actionlint` first; never in the DeepSeek loop (Docker stays closed there).

## Agent wait recipes

PR checks (green, red, or stuck at the timeout):

```
timeout 45m gh pr checks <n> --watch -i 30 --fail-fast
```

Landing (the label is removed on failure; the PR comment has the run link):

```
for i in $(seq 1 120); do
  gh pr view <n> --json state,labels
  sleep 30
done
```

Stop on `MERGED`. A missing label with the PR still open means the land job
failed: read the PR comment. Limit: 60 minutes.
