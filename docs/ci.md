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
- Machine-pinned suites are marked at the declaration with
  `.machinePinned(_:)` and a reason, and the workflow sets
  `SYNCCLOUD_SKIP_MACHINE_PINNED=referenceImages` to exclude only the image
  snapshots (see `Modules/Design/Tests/DesignTests/SNAPSHOTS.md`), whose
  reference PNGs only match the machine that recorded them. Excluded suites
  still compile, so breakage in their code is caught, and they report as
  *skipped with a reason* rather than silently vanishing. See
  [Machine-pinned tests](#machine-pinned-tests) for the reasons and the switch.
- App-target tests (the full `SyncCloudTests/` suite, hosted in
  SyncCloud.app; the count grows with the app, so it is not pinned here) run
  as a second step: `xcodegen` (absolute Homebrew path — the runner service
  PATH is minimal) + `xcodebuild test -scheme SyncCloud`, both under
  `arch -arm64`. Safe next to a live SyncCloud instance: the app's
  `XCTestConfigurationFilePath` guard stubs windows to `Color.clear` and
  skips prefs writes. DerivedData lives in `.dd/` inside the workspace.
- The loop runs every package even after a failure so one run reports all
  broken packages.
- **External dependency versions are not pinned, and a green run does not say
  which ones it tested.** `Package.resolved` is gitignored, so every checkout —
  CI's and yours — resolves afresh from the `from:` floors in the manifests:
  `swift-snapshot-testing` (1.18.0) in Design, Dashboard, FileExplorer and
  Settings, and `swift-argument-parser` (1.3.0) in `SyncCloudCLI`. The first is
  test-only; the second the CLI **links and ships**. So a run's verdict covers
  whatever resolved that day, and a build cut from a release tag can pick up a
  version no run ever exercised. Recorded here rather than closed: committing
  `Package.resolved` (and un-ignoring it) is what would close it.

### Machine-pinned tests

A suite is *machine-pinned* when it only produces a trustworthy verdict on the
machine that recorded it. Seventeen suites qualify, each marked at its own
declaration with a reason:

| Reason | What it means | Suites | On CI |
|---|---|---|---|
| `referenceImages` | compares against PNGs recorded on one Mac | the 4 `*SnapshotTests` | **excluded** |
| `pixelSampling` | reads painted pixels out of a live renderer (`colorAt(`) | 12, across Design, Dashboard, FileExplorer, Settings | runs |
| `calibratedTiming` | latency thresholds tuned on this hardware | `ColumnClickCostBenchmark` | runs |

```swift
@Suite(.serialized, .machinePinned(.pixelSampling)) struct AccentPreviewTests { … }
```

`SYNCCLOUD_SKIP_MACHINE_PINNED` selects what to exclude: `all`, or a
comma-separated list of reasons. **Unset runs everything**, so nobody working on
the recording machine needs to know it exists. An unrecognised value excludes
nothing — it fails safe, running more rather than silently skipping. The one
XCTest holdout, `HoverTintRenderTests`, opts into the same gate via
`XCTSkipIf`, since traits are a Swift Testing feature.

**Why a marker and not a name.** This replaced `--skip SnapshotTests`, which
selected by *type name* and therefore missed twelve equally machine-pinned
suites — `AccentPreviewTests` among them — that simply were not called
`*SnapshotTests`. Worse, the comments in those files positively asserted the
pixel assertions were "machine-independent", which they are not. Selection now
lives next to the code that does the pixel reading, where renaming a suite
cannot silently change what CI runs. (Swift Testing tags would be the idiomatic
marker, but SwiftPM 6.3 has no tag filtering — `--filter`/`--skip` match only
type names, so a tag would be decorative.)

The pixel-sampling suites and the benchmark are pinned to the renderer and the
machine in the same way the excluded PNGs are; they keep running because the
cost of being wrong is lower, not because they are machine-independent.

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
