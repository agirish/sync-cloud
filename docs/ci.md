# CI

`.github/workflows/tests.yml` runs the seven SPM package test suites on every
push to `main` or `v2.x` and on every `v*` release tag (so cutting a release
validates the exact commit being tagged), on a self-hosted runner
(GitHub-hosted macOS minutes bill at
10x on a private repo, and the hosted toolchain lags the one this repo is
developed against).

**A red run is not automatically a red commit.** The runner is this Mac, and several
mechanisms here fail tests for reasons unrelated to the code — throttled CoreAnimation on
an unattended machine, fixed pumps under contention, process-wide state across parallel
suites. Before bisecting, work through
[flaky-tests.md](flaky-tests.md#first-is-it-a-flake-or-a-regression); it records the
mechanisms this repo has actually hit and how to tell one from a regression.

## Scope

- All seven packages: `Modules/{Sync, Events, Settings, Design, Dashboard,
  FileExplorer}` and `SyncCloudCLI`.
- Machine-pinned image snapshots (`*SnapshotTests` suites, see
  `Modules/Design/Tests/DesignTests/SNAPSHOTS.md`) are excluded with
  `--skip SnapshotTests`: their reference PNGs only match the machine that
  recorded them. They still compile, so breakage in snapshot test code is
  caught.
- App-target tests (the full `SyncCloudTests/` suite, hosted in
  SyncCloud.app; the count grows with the app, so it is not pinned here) run
  as a second step: `xcodegen` (absolute Homebrew path — the runner service
  PATH is minimal) + `xcodebuild test -scheme SyncCloud`, both under
  `arch -arm64`. Safe next to a live SyncCloud instance: the app's
  `XCTestConfigurationFilePath` guard stubs windows to `Color.clear` and
  skips prefs writes. DerivedData lives in `.dd/` inside the workspace.
- The loop runs every package even after a failure so one run reports all
  broken packages.

### Machine-pinned tests that DO run on CI

The snapshot skip's rationale ("reference PNGs only match the machine that
recorded them") is honest but incomplete: other machine-pinned tests run on
CI anyway. Eleven suites sample rendered pixels directly via `colorAt(`
(painted-fill and contrast assertions across Design, Dashboard, FileExplorer
and Settings), and `ColumnClickCostBenchmark`
(`Modules/FileExplorer/Tests/FileExplorer/ColumnClickCostBenchmark.swift`)
asserts against latency thresholds calibrated on this hardware. These are
pinned to the renderer and the machine in the same way the skipped PNGs are.

This is currently sound because the self-hosted runner IS the recording
machine — the same Mac that recorded the snapshot references, tuned the
benchmark, and renders the sampled pixels, so there is no second renderer to
disagree with. It stops being sound the moment the runner moves to different
hardware or a different macOS version: expect the pixel-sampling suites and
the benchmark to fail there for machine reasons, not code reasons, and plan
to re-validate (and re-record/re-calibrate) on the new machine — see the
re-record workflow in `Modules/Design/Tests/DesignTests/SNAPSHOTS.md`.

## Per-commit verdicts

The concurrency group is **per (ref, commit)** — `tests-${{ github.ref }}-${{
github.sha }}` — with `cancel-in-progress: false`. Both halves are load-bearing,
and they cover different cases:

- `cancel-in-progress: false` stops a newer push from killing a run that has
  already **started**.
- The **SHA in the group key** stops a newer push from evicting a run that has
  **not started yet**. `cancel-in-progress` does not cover this: GitHub Actions
  holds at most one *pending* run per group, so under a ref-wide group a third
  push cancels the queued second one before it ever creates a job.

Grouping by ref alone therefore dropped verdicts silently. During a burst of
landings on 2026-08-01, v2.x `389b38fb` (run 30718845541) and `234e4312` (run
30718896990), plus main `957e173d` (run 30718657891), were all cancelled with
**zero jobs created**, each one second after the next push to the same branch —
while the branch still read green because a later SHA passed. `gh run rerun`
could not rescue them: for ~40 min each re-queued attempt lost the single
pending slot to the next push again. Note the two symptoms that identify this
rather than a `cancel-in-progress` cancellation: the run has **no jobs at all**
(`gh api repos/{owner}/{repo}/actions/runs/<id>/jobs --jq .total_count` → `0`),
and runs that had already started sailed through the same burst untouched.

With per-commit groups no run can evict another, so a burst of close landings
each land a green/red verdict and a break is bisectable to the exact SHA — which
matters because commits here get audited. Serialization is the **runner's** job,
not the concurrency group's: only one self-hosted runner exists, so a dispatched
run's job waits `queued` until it frees up. A run is ~4-7 min of runner time
(median ~5), so the per-commit cost is acceptable on our own hardware; wall-clock
during a burst is much longer because of that queue. If a long burst ever backs
the queue up, cancel stale runs with `gh run cancel <id>` — deliberately, per
SHA, so you know which commits you gave up a verdict for.

Verifying a push means checking the run for **that exact SHA**, not the branch:

```sh
gh run list --commit <sha> --workflow tests.yml
```

A SHA with no run at all is as bad as a red one.

## Runner

Registered as `synccloud-mac` (labels `self-hosted`, `macOS`), installed at
`~/actions-runner-synccloud`. Re-register after a machine move:

```sh
cd ~/actions-runner-synccloud
./config.sh --url https://github.com/agirish/sync-cloud --token <from repo settings → Actions → Runners → New> --name synccloud-mac --unattended
```

### Known issue: fork deadlock on macOS 26 (Tahoe)

macOS 26 has a fork regression: children forked from a multithreaded process
can wedge pre-exec, spinning one thread at 100% CPU (observed with the
runner's .NET host; also reported against Ruby on 26.1). Symptom: a job step
"runs" forever, `ps` shows a second `Runner.Worker spawnclient` process in
state `R` at 100% CPU with a tiny footprint, and killing it only makes the
worker fork another. Ruled out by direct A/B on this machine:
`DOTNET_EnableWriteXorExecute=0` (verified present in the worker's env, still
wedged), LaunchAgent vs interactive `./run.sh` (both wedge). The arm64 agent
wedged in 3 of 3 runs, at a different spawn each time.

Current mitigation: the agent runs as the **osx-x64 build under Rosetta**
(`~/actions-runner-synccloud-x64`, same registration — the `.runner` /
`.credentials*` files are arch-independent and were copied over), which takes
a different fork path through the translation layer. If a run wedges anyway:
kill the `Runner.Worker` processes, restart the runner, re-run the workflow.
Track the OS bug before blaming test code — every wedge so far happened in
the runner agent, never in `swift test`.

### Rosetta corollary: `swift test` exit code lies under x86_64

Under the x64 agent, `swift test` inherits x86_64 and then **exits 1 with
every test passing** (isolated by A/B: same workspace + native arm64 → 0;
x86_64 → 1; env and cwd innocent). The workflow therefore runs the payload
as `arch -arm64 swift test …`. When checking test outcomes by hand, never
judge from piped output (`… | tail`) — the pipe masks the real exit code;
that mistake let this slip past local verification once already.
