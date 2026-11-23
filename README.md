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
then created from it. Inputs: `image` (required), `context`, `file`,
`platforms` (`linux/amd64`), `target`, `build-args`, `empty-files` (empty placeholder files to create, one relative path per line; allowed on private builds), `pre-build` (public
builds only; a private build with `pre-build` fails in the ref step), `lfs`,
`visibility` (`private`/`public`), `runs-on` (`teknoir-push`),
`timeout-minutes` (60).
Caller permissions: `contents: read`, `packages: write`.
Outputs: `digest` (from the build, or read back from the existing image when
the build was skipped), `tag`.

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

Publishes every chart under `charts-dir` with chart-releaser (`skip_existing`),
from `main` only: the first step fails with `::error::` on any other ref. A
published chart version is never changed or deleted; bump the version. Inputs:
`charts-dir` (`charts`), `runs-on` (`ubuntu-latest`), `helm-version`
(`v3.19.0`). Caller permissions: `contents: write`.

### `lint.yml` (this repo)

PR and `main` check. Job name is exactly `actionlint` (a ruleset requires that
check name): actionlint on every workflow including `examples/`, shellcheck on
`scripts/*.sh`, and `bash scripts/test-land.sh`.

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
