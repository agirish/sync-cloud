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
- **External dependency versions are pinned — `Package.resolved` is committed.**
  Five of them: `SyncCloudCLI` and `Modules/{Design,Dashboard,FileExplorer,Settings}`.
  Sync and Events declare no external dependency and so have none. A run's verdict
  now names the versions it covered, and a build cut from a release tag links what
  CI tested.

  This was open until 2026-08-03 and closed with evidence rather than on principle.
  The manifests declare only `from:` floors — `swift-snapshot-testing` from 1.18.0
  and `swift-argument-parser` from 1.3.0 — and unpinned resolution had drifted a
  long way above both:

  | | declared floor | actually resolving |
  |---|---|---|
  | `swift-argument-parser` (the CLI **links and ships** this) | 1.3.0 | **1.7.0**, and **1.8.2** in a checkout made minutes later |
  | `swift-snapshot-testing` (test-only) | 1.18.0 | **1.19.4** in Settings, **1.19.3** in the other three |

  Two things there are worth keeping. The shipping dependency was **five minor
  versions above its floor and moved again between two checkouts on the same
  machine within the hour** — that is the tag-reproducibility hole, demonstrated
  rather than hypothesised. And the same tree was testing against **two different
  versions of the same library** depending on which package you ran, which no
  green run would ever have told you.

  The pinned set was verified before it was committed, not after: the CLI's 72
  tests against `swift-argument-parser` 1.8.2, and all four snapshot-consuming
  packages against `swift-snapshot-testing` 1.19.4 — including a Design run with
  the reference-image suites **not** excluded (0 suites skipped, all 251 tests
  executed), since re-pinning the snapshot library is exactly the change that
  could move image comparison.

  **Residual, deliberately left open.** The app target resolves through the
  generated `SyncCloud.xcodeproj`, which is gitignored, so its
  `xcshareddata/swiftpm/Package.resolved` cannot be tracked and the app-target
  step still resolves fresh. That is tolerable because the app links no external
  dependency — only the test-only snapshot library reaches it — whereas the CLI,
  which does ship one, is pinned. Bumping a dependency is now a deliberate
  `swift package update` plus a commit, which is the point.

### Machine-pinned tests

A suite is *machine-pinned* when it only produces a trustworthy verdict on the
machine that recorded it. Each one is marked at its own declaration with a
reason:

| Reason | What it means | Where it appears | On CI |
|---|---|---|---|
| `referenceImages` | compares against PNGs recorded on one Mac | Design, Dashboard, FileExplorer, Settings | **excluded** |
| `pixelSampling` | reads painted pixels out of a live renderer (`colorAt(`) | Design, Dashboard, FileExplorer, Settings | runs |
| `calibratedTiming` | latency thresholds tuned on this hardware | FileExplorer | runs |

**No count is kept here, and no list of suite names.** Both drift the moment a
suite is added — this table said "Seventeen suites … 12 pixelSampling …
`ColumnClickCostBenchmark`" while the tree held 19, 13 and two benchmarks. Naming
them would also reintroduce, in prose, exactly the type-name coupling that made
`--skip SnapshotTests` miss twelve suites (below). The declarations are the
authoritative list; ask the tree, not this file:

```sh
grep -rE '^[[:space:]]*@Suite\(.*machinePinned\(' --include='*.swift' Modules SyncCloudCLI
```

The `^[[:space:]]*` anchor is load-bearing: without it the pattern also matches
prose in doc comments that quotes an `@Suite(…)` line, which is how a first
attempt at this note counted 20.

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

## Tip-only verdicts on branches

Branch pushes to `main` or `v2.x` share **one concurrency group per ref** with
`cancel-in-progress: true`, so during a burst of landings only the newest push
keeps a run: each push cancels the group's older runs, both the one already
executing on the runner and any still queued. Two separate mechanisms produce
that, and it helps to know both when reading a cancelled run:

- `cancel-in-progress: true` cancels runs that have already **started** (they
  have a job with partial logs).
- Independently, GitHub Actions holds at most one *pending* run per group and
  evicts the older pending one on the next push — unconditionally, no setting
  controls it. An evicted run has **no jobs at all**
  (`gh api repos/{owner}/{repo}/actions/runs/<id>/jobs --jq .total_count` → `0`).

Either way, a `cancelled` run on a branch means **superseded by a newer push**,
not broken.

Tags and `workflow_dispatch` runs keep **per-commit groups** (a SHA suffix in
the group key) and are never cancelled: cutting a release must get its own
verdict even if the branch moves during the run, and a deliberate manual re-run
must not be killable by an unrelated push. The ref stays in the key so a tag
never shares a group with the branch push at the same commit.

History, because this policy has now gone both ways: ref-wide grouping
originally dropped verdicts *silently* (2026-08-01 — v2.x `389b38fb` and
`234e4312`, main `957e173d`, all evicted with zero jobs one second after the
next push, unrescuable by `gh run rerun` while the burst lasted), and the fix
was per-(ref, SHA) groups so every commit stayed bisectable. On 2026-08-09 that
was deliberately reversed: the runner is the developer's own Mac, a run costs
4-7 min of its time, and stale runs during a burst starved both the machine and
the tip's verdict. The trade is explicit now — a commit superseded mid-burst
has no verdict of its own, and bisecting a break found at the tip may need old
SHAs re-run by hand. Do that in a quiet moment: `gh run rerun` re-enters the
shared branch group, so a stale-SHA rerun and a live tip run cancel each other.

Verifying a push therefore means checking the run for the **branch tip**:

```sh
gh run list --commit <tip-sha> --workflow tests.yml
```

The tip having no run, or a cancelled one, is as bad as red — nothing newer
superseded it, so something ate its run. For an *intermediate* SHA of a burst,
cancelled-with-a-newer-green-descendant is the expected state, but remember its
content passed only as part of the descendant, not on its own.

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

### The runner only runs while the Mac is awake — and sleep reads as a red run

The runner is a LaunchAgent on this Mac, so a job survives only as long as the
machine does. **Closing the lid kills the job in flight**, and so does idle
sleep on battery; the nightly `Maintenance Sleep` / `Sleep Service Back to
Sleep` cycle then keeps it dead, because the DarkWakes in between are 2–45
seconds and never long enough to run anything. Read the machine's own account
with `pmset -g log | grep 'Entering Sleep'` before reading anything into a
red run.

**What it looks like from GitHub is a failure that names nothing.** The run
is `failure`, the package-suites step is `cancelled` (or every step's
conclusion is `null`), there is **no test output at all**, and
`gh run view <id> --log-failed` returns empty. About ten minutes after the
machine stops answering, GitHub gives up on the connection and fails the job:

| run | SHA | machine slept | job failed |
|---|---|---|---|
| `32104076252` | `b290a64b` (`v3.x`) | 06:06:22Z, `Clamshell Sleep` | 06:17:06Z |
| `32111380208` | `b9b276f0` (`v3.x`) | 09:16:59Z, `Maintenance Sleep` | 09:27:00Z |

Both on 2026-08-18. For the first, the Dashboard package — the only one that
commit touched — had been run by hand on the same tree minutes earlier and was
green, which is what settled that the red was not about the code. The second is
the sharper lesson: the runner picked that job up at 09:17:00Z, one second after
the machine entered sleep, and lost it ten minutes later without executing a
single test.

**The local logs are where the verdict actually is**, in
`~/actions-runner-synccloud-x64/_diag/`:

- `Worker_*.log` — `[StepsRunner] Step result: Canceled`, with no `✘` and no
  `Test run with N tests` anywhere above it. The worker does not learn the job
  is gone until the machine wakes, and its completion call then fails with
  `Job not found: <guid>. job ref not found` — an hour later, in the run above.
- `Runner_*.log` — `[BrokerServer] SocketException (89): Operation canceled`
  and a retry backoff, which is the listener discovering the same thing.

**`gh api repos/agirish/sync-cloud/actions/runners` will say `offline` while
`Runner.Listener` is very much alive in `ps`.** That combination is this, not
a wedged agent — do not go hunting for `Runner.Worker` processes to kill (see
the fork-deadlock section above, which is the failure that *does* want that).

There is nothing to fix in the runner. Re-run the job when the Mac is awake
and on power:

```sh
gh run rerun <id> --failed
```

If the listener does need a restart, it takes `stop` then `start` **from the
runner root** — `./svc.sh restart` is not one of its verbs
(`[install, start, stop, status, uninstall]`):

```sh
cd ~/actions-runner-synccloud-x64 && ./svc.sh stop && ./svc.sh start
```

That reconnects in seconds and buys nothing on a machine that is about to
sleep again, which is exactly how the second run in the table above was lost.
