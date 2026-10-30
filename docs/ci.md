# CI

**Two workflows, two machines (since 2026-10-29).**

- **`.github/workflows/hosted-ci.yml`** tests every push to `main` on GitHub's hosted macOS
  runners. The repo is public, so standard runners cost nothing and have no minute cap, and the
  Free plan runs five macOS jobs at once. The `xcode-27` image matches this Mac's toolchain.
  Five jobs: Sync (two processes); Events, Settings, CLI and Design; Dashboard; FileExplorer
  (sharded); and the app target. Each push gets its own run, and none is cancelled. With a warm
  build cache a run takes about 6 minutes.
- **`.github/workflows/tests.yml`** runs on this Mac, the self-hosted runner, for every `v*`
  release tag (so cutting a release validates the exact commit on the recording machine), nightly
  at 03:00 Pacific, and by hand. It runs the machine-pinned suites the hosted runners skip.
  Maintenance lines keep their own copy and still test every push here.

The hosted VM is not this Mac: a 1024×768 screen at scale 1, three vCPUs, no printers, no working
Vision text recognition, no iCloud Drive. Tests that depend on any of those carry a
`.machinePinned` reason (below), and hosted runs exclude `all` of them.

**A red run is not automatically a red commit.** The runner is this Mac, and several
mechanisms here fail tests for reasons unrelated to the code — throttled CoreAnimation on
an unattended machine, fixed pumps under contention, process-wide state across parallel
suites. Before bisecting, work through
[flaky-triage.md](flaky-triage.md); it is one page, and it tells the mechanisms this
repo has actually hit apart from a regression. [flaky-tests.md](flaky-tests.md) behind
it carries the measurements and the fix for each.

## Scope

- All seven packages: `Modules/{Sync, Events, Settings, Design, Dashboard,
  FileExplorer}` and `SyncCloudCLI`.
- FileExplorer runs through `scripts/test-shards`: six chunks of whole suites,
  three test processes at a time. Its suites are main-thread bound, so one
  process uses one core — measured 2026-10-27 at 671 s wall and 725 s CPU, and
  345 s sharded, on a busier machine. The run is red unless every chunk prints its
  own count line and the counts add up to `swift test list`'s total. Chunks are
  balanced by each suite's measured cost in `scripts/test-costs/FileExplorer.tsv`
  (how it is measured, and why: the script's header). Refresh it with `scripts/test-shards --measure Modules/FileExplorer` when one
  chunk keeps finishing well after the rest. A stale file costs time, never coverage.
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
  skips prefs writes. DerivedData lives in the run's build directory (below).
- **`main` keeps its builds between runs on this Mac**, for the nightly and hand runs (hosted CI restores a GitHub cache of its own, with files dated by `scripts/restore-mtimes`). Every package's scratch path and
  the app's DerivedData live under
  `~/Library/Caches/SyncCloud-ci.noindex/main-<toolchain hash>/`, so a push
  run recompiles only what changed. Before this, `actions/checkout`'s
  `git clean -ffdx` took the in-workspace `.build` and `.dd` every run, and each
  run compiled all seven packages cold (~5 min). Tags, maintenance lines and a
  `workflow_dispatch` with `clean` still build cold in the job's temp directory,
  so a release's verdict never rests on an earlier build. A new toolchain gets a
  new directory and the old one is removed; `.noindex` keeps Spotlight out.
  If a red looks like a stale build, dispatch with `clean` before bisecting.
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
  step still resolves fresh. **The app now links one external dependency** —
  `swift-markdown`, which the Edit workspace's preview parses with — so that
  residual covers a shipping library rather than only a test-only one. What
  keeps it from mattering is the pin: `swift-markdown`, its `swift-cmark`
  parser, and the `swift-docc-plugin` / `swift-docc-symbolkit` pair it declares
  are all `exact:` in `Modules/FileExplorer/Package.swift`, so a fresh resolve
  can only land the versions already named. Bumping a dependency is a deliberate
  edit to those four pins plus a commit, which is the point.

### Machine-pinned tests

A suite is *machine-pinned* when it only produces a trustworthy verdict on the
machine that recorded it. Each one is marked at its own declaration with a
reason:

| Reason | What it means | Where it appears | On CI |
|---|---|---|---|
| `referenceImages` | compares against PNGs recorded on one Mac | Design, Dashboard, FileExplorer, Settings | **excluded** |
| `pixelSampling` | reads painted pixels out of a live renderer (`colorAt(`) | Design, Dashboard, FileExplorer, Settings | runs |
| `calibratedTiming` | latency thresholds tuned on this hardware | FileExplorer | runs |
| `layoutMetrics` | laid-out text, window and control geometry that tracks fonts, screen size and scale | Dashboard, Design, FileExplorer, app | runs |
| `textRecognition` | Vision text recognition, which errors on GitHub's hosted VMs | FileExplorer | runs |
| `iCloudDrive` | needs a signed-in iCloud Drive folder | Sync | runs |
| `liveProfile` | the developer's live filing profile and document tree | Sync | **excluded** |

The app target's tests read the switch through `xcodebuild`, which hands a test process only
variables prefixed `TEST_RUNNER_`: set `TEST_RUNNER_SYNCCLOUD_SKIP_MACHINE_PINNED` there, or the
app's pinned suites run regardless. Hosted CI (`.github/workflows/hosted-ci.yml`) excludes `all`; on 2026-10-29 its VM had a 1024×768 screen at scale 1, no printers, no
working Vision text recognition and no iCloud Drive, which is what the last three rows answer.

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

## Docs-only pushes start no run

A branch push that changes only root-level Markdown (`CLAUDE.md`, `ROADMAP.md`, …) or files under
`docs/` starts no run: no build reads them, and every repo-wide scan reads only `.swift` and `.plist`
files. Three are read by tests and still run: `RELEASE_NOTES.md` and `docs/releases.html`
(`PageStripCopyClaimTests`, `HelpBookTests`) and `README.md` (`HelpBookTests`). Markdown anywhere
else — a test's fixture, a package README — still runs, and so does every tag push, since GitHub
never applies path filters to tags. A skipped push also no longer cancels the code run before it, so
that run's verdict covers the docs commit on top. Measured when this was added (2026-10-28): 10 of
429 commits since 10-14 would have skipped.

**If you add a test that reads a doc**, add that file to the re-included paths in
`.github/workflows/hosted-ci.yml` in the same commit, or a push touching only it will never be tested.

## Verdicts on `main`: one run per push

Since 2026-10-29 every push to `main` gets its own `hosted-ci.yml` run: a concurrency group per
commit, nothing cancelled, so every commit has a verdict of its own and a break can be bisected
from CI alone. GitHub queues jobs beyond the Free plan's five macOS at once, so a burst of
landings waits rather than evicting. Check a push with:

```sh
gh run list --workflow hosted-ci.yml --commit <sha>
```

What follows describes `tests.yml`'s branch groups, which `main` used until then and which the
maintenance lines' own copies still use in their 2026-08-09 form (each push cancels the run in
progress).

### Before 2026-10-29: the running run finishes, then the newest push

Branch pushes to one ref share **one concurrency group** with
`cancel-in-progress: false`. A run that has started always finishes; a push that
arrives meanwhile waits, and runs once it ends. GitHub Actions holds at most one
*pending* run per group and evicts the older pending one on the next push —
unconditionally, no setting controls it — so a burst of landings tests the commit
already running and then the newest; the pushes between them never start.

- An evicted push shows `cancelled` with **no jobs at all**
  (`gh api repos/{owner}/{repo}/actions/runs/<id>/jobs --jq .total_count` → `0`).
  That is supersession, not breakage.
- A run that **started** and shows `cancelled` is not supersession: someone
  cancelled it, or the job hit its 90-minute timeout. Read its log.

Tags and `workflow_dispatch` runs keep **per-commit groups** (a SHA suffix in
the group key) and are never cancelled: cutting a release must get its own
verdict even if the branch moves during the run, and a deliberate manual re-run
must not be displaced by an unrelated push. The ref stays in the key so a tag
never shares a group with the branch push at the same commit.

**Never `gh run rerun` a branch run.** It re-enters the shared branch group, and
while pending it evicts the tip's own queued run. Re-run with a fresh
`gh workflow run tests.yml --ref main` instead, which has a group of its own.

History, because this policy has gone three ways. Ref-wide grouping first
dropped verdicts *silently* (2026-08-01 — v2.x `389b38fb` and `234e4312`, main
`957e173d`, all evicted with zero jobs), and the fix was per-(ref, SHA) groups so
every commit stayed bisectable. On 2026-08-09 that was reversed to tip-only, with
each push also cancelling the run in progress: a run cost 4-7 min of the
developer's own Mac, and stale runs during a burst starved both the machine and
the tip's verdict. On 2026-10-28 the cancelling half was dropped. With `main`'s
kept build a run takes about 14 minutes, and runs cancelled 20-30 minutes in had
thrown that time away. Letting a started run finish costs the tip up to one run
of extra wait and gives one more commit a verdict of its own.

Verifying a push therefore means checking the run for the **branch tip**:

```sh
gh run list --commit <tip-sha> --workflow tests.yml
```

A tip run that is queued behind a running one is normal. The tip having no run,
or a cancelled one, is as bad as red: nothing newer superseded it, so something
ate its run. A docs-only push has no run by design (above). For an
*intermediate* SHA of a burst, evicted-with-a-newer-green-descendant is the
expected state, but remember its content passed only as part of the descendant,
not on its own.

### One commit on `main` does not build: `cb2147b9` — skip it when bisecting

`cb2147b9` ("Retire the Tidy machinery names") **fails to compile**, and it is on
`main` and under the `v4.0` tag. `git bisect` will land on it eventually; when it
does, `git bisect skip` is the answer. It is the only such commit — its child
`b4ac3a21` builds.

The break is one call. That commit renamed `TidyView` to `LensWorkspaceView`, and
`Modules/FileExplorer/Tests/FileExplorer/FilingSpendWordingTests.swift:57` still
reads `TidyView.refineHelp(…)`. At that commit no type named `TidyView` is
declared anywhere, `refineHelp` lives on `LensWorkspaceView.swift:2458`, and the
FileExplorer test target is `path: "Tests/FileExplorer"` with no `exclude:` and no
`sources:` — so SPM compiles that file and the symbol cannot resolve. The child
commit spells it `LensWorkspaceView.refineHelp`.

**Two things let it through, and both are worth knowing rather than the commit
itself.** The fix was written but **amended into the following commit instead of
this one**, so the branch tip was always green and the defect existed only at an
intermediate SHA. And evicted pushes (above) mean no run ever compiled this SHA
on its own — the policy that saves the machine 4-7 minutes per superseded commit
is exactly the policy that cannot catch this. The general rule: **when a rename
lands, let each commit build before writing the next one**, because nothing in CI
is watching the commits between pushes.

It is **not** being repaired. `cb2147b9` is an ancestor of the published `v4.0`
tag, so rewriting it would change every SHA after it and orphan both the tag and
the GitHub release that points at it. A broken build at one intermediate commit is
much cheaper than that.

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

The mitigation was to run the agent as the **osx-x64 build under Rosetta**
(`~/actions-runner-synccloud-x64`, same registration — the `.runner` /
`.credentials*` files are arch-independent and were copied over), which takes
a different fork path through the translation layer. **That is no longer how
it runs.** As of 2026-10-28 the LaunchAgent starts the native arm64 agent in
`~/actions-runner-synccloud` (2.338.0, node24), Rosetta is not installed on
this Mac (`arch -x86_64` answers "Bad CPU type"), and the x64 copy is unused.
If a run wedges the way described above, that is the first thing to revisit.
If a run wedges anyway: kill the `Runner.Worker` processes, restart the runner,
re-run the workflow with a fresh `workflow_dispatch`. Track the OS bug before
blaming test code — every wedge so far happened in the runner agent, never in
`swift test`.

### Rosetta corollary: `swift test` exit code lies under x86_64

Historical while the agent is native, and kept because the workflow still
carries its fix. Under the x64 agent, `swift test` inherits x86_64 and then **exits 1 with
every test passing** (isolated by A/B: same workspace + native arm64 → 0;
x86_64 → 1; env and cwd innocent). The workflow therefore runs the payload
as `arch -arm64 swift test …`. When checking test outcomes by hand, never
judge from piped output (`… | tail`) — the pipe masks the real exit code;
that mistake let this slip past local verification once already.

### Transient: SPM dependency resolution times out

The app-target step resolves Swift packages over the network before it builds
anything, so a momentary loss of reachability to github.com fails the step
without a single test having run. Seen on main `405cc6f5` (run 30776561209):

```
skipping cache due to an error: Couldn’t fetch updates from remote repositories
xcodebuild: error: Could not resolve package dependencies:
  Failed to clone repository https://github.com/pointfreeco/swift-snapshot-testing:
    fatal: unable to access '…': Recv failure: Operation timed out
```

**It reads like a code failure and is not one.** The job's verdict is
`failure`, the step named is `App-target tests (xcodegen + xcodebuild)`, and
the obvious reading — the commit broke the app target — is wrong. Three things
identify it, all cheaper than a bisect:

- The **package suites in the same run passed**. They build from the same
  checkout; a real compile or test break would take them down too.
- The error is `Could not resolve package dependencies`, above any compiler
  diagnostic. Nothing was built, so nothing in the commit was exercised.
- The step is fast — it dies at the network timeout, not after a full build.

`gh run rerun <id> --failed` is the fix; `405cc6f5` went green on the first
re-run with every step passing. Unlike the pending-eviction case above, the run
does have jobs (`… /jobs --jq .total_count` → `1`), so a re-run reliably gets a
slot. If it fails twice in a row on the same SHA, stop treating it as transient
and check the runner's own connectivity — the resolution step has no retry of
its own.

Deliberately here and not in [flaky-tests.md](flaky-tests.md): that file is
about tests whose *verdict* the machine decided. Here no test ran at all.
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
