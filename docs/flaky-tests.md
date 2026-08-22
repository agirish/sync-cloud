# Flaky tests

Tests here have failed for reasons that had nothing to do with the code under test — and each
time, the failure looked exactly like a real defect. `ColumnPreviewRevealTests` reported "the
deepest column is hidden behind the preview: column 420…630, visible 0…270", which is the precise
geometry of the bug it exists to catch. Nothing about that message says *the machine decided this*.

This file records the mechanisms that have actually produced false failures in this repo — and the
ones that produce no failure at all, which are the more expensive half. Mechanism 8 can hang the run
instead of failing it, and **four separate mechanisms here can leave an assertion passing having
examined nothing**: mechanism 2 (a fixed sleep before an absence assertion), mechanism 8 (a bound
whose expiry is discarded), mechanism 9 (an absence with no paired control that the signal ever
arrived) and mechanism 10 (a log window that rolled past the interval being read). Read 10 before
writing any assertion about `Logger.shared.entries`, and read all four before writing any assertion
that something did *not* happen — a vacuous pass is silent and permanent, so unlike a false failure
it costs you nothing to notice and everything to miss. **Mechanism 11 is not a flake at all** — it
is a *build* failure that reports itself exactly like a red suite, and it is filed here because here
is where you will look. Below: how to tell each from a regression
before you start bisecting, and the fix pattern for each. See [ci.md](ci.md) for what CI runs and the
runner's own quirks.

---

## First: is it a flake or a regression?

Do these in order. Steps 1–3 cost about a minute and have each been skipped, at least once, in
favour of a wrong conclusion.

**No verdict at all?** If the run never finished — no output, log frozen mid-line, nothing named —
none of the steps below apply: they all assume a failure you can read. Go straight to
[mechanism 8](#8-the-wait-that-hangs-instead-of-failing).

**No `Test run with N tests` line in the output?** Then no test ran, and nothing in this file
below applies — the *build* failed, and only the reporting makes it look like a test did. Exit 65
and `** TEST FAILED **` are what a broken build looks like from the outside. Go to
[mechanism 11](#11-the-build-failed-before-any-test-ran) and do not bisect the commit.

**A test asserting on `Logger.shared.entries`, failing only in the full suite?** `entries` is a
rolled 1000-line window shared by every suite at once, so a line that really was written can be gone
by the time the assertion reads —
[mechanism 10](#10-a-log-assertion-reading-a-window-that-has-already-rolled). Do not bisect the code
that writes the line; check whether the test reads the buffer whole. The same section's other half
is the reason to go there even when nothing is failing.

**1. Read the timing, not just the verdict.** A suite that normally finishes in 10s taking 57s is
the single strongest tell. Condition-based waits give up at their deadline, so a starved test
*spends* its whole ceiling — 25s or 32s per test — before failing. Real geometry bugs fail
instantly.

But a spent ceiling says only *the condition never held*, not *why*. Starvation and a premise
that was false from the start are indistinguishable by timing alone — mechanism 7 spends the
whole deadline without the machine being loaded at all. Two things separate them. **Was the rest
of the suite slow too?** Starvation is never selective. And **did the suite's other tests of the
same shape survive?** `ColumnDrillSourceTests` has two tests that wait on the same deferred
navigation and run within 50ms of each other; load takes both, and on 2026-08-01 only one failed.

**2. Check what else is running.**

```bash
uptime                          # load average — anything over ~8 on this Mac is contention
pmset -g | grep lowpowermode    # 1 = CoreAnimation throttled
pgrep -fl 'xcodebuild|swift-frontend' | grep -v actions-runner
git worktree list               # every one of these is a session that may be building
```

**The self-hosted runner IS this Mac.** A local build competes directly with CI, and there are
routinely many worktrees open at once — ten, on 2026-08-01, with load peaking above 20. A CI red
that coincides with your own full-suite run is very likely yours, and not in the way you think.

**3. Run the OLD source under the SAME conditions.** This is the step that settles it, and the one
easiest to skip. On 2026-08-01 a suite failed 4/4 and CI had been green on the previous commit, so
the new commit looked guilty. It wasn't:

| Source | Machine | Result |
|---|---|---|
| new commit | idle | 573/573 pass, 10s |
| **previous commit** | **load ~10** | **4 failures, 52s** |

The second row is the whole argument. Without it you are comparing a commit against a *different
machine state* and calling the difference a regression.

**4. Do not stop at `--filter`.** Passing in isolation proves almost nothing — most of these
mechanisms need the rest of the suite present to fire. Confirm against the full suite, ideally
twice.

**5. Never judge `swift test` from piped output.** Under the x64 agent it exits 1 with everything
passing; `… | tail` masks the real exit code. See [ci.md](ci.md#rosetta-corollary-swift-test-exit-code-lies-under-x86_64).

If steps 1–4 point at the environment, say so *with the evidence* and re-run. If they don't, it's
your commit — keep going.

---

## Reproducing a load-sensitive failure on purpose

Suspected flakes are worth confirming rather than assumed. Load the machine, run the suite, then
**verify the load generators actually died** — a leaked spinner poisons every later measurement on
a machine that also runs CI.

```bash
for i in $(seq 1 6); do (yes > /dev/null &); done
uptime
arch -arm64 swift test --filter <Suite>
pkill -x yes; pgrep -x yes || echo "clean"
```

Use CPU spin, not `sleep`, when validating that a timing test can actually fail — a sleeping
process contends for nothing and proves nothing.

---

## The mechanisms

### 1. The machine decides the verdict — throttled CoreAnimation

**Symptom.** A view test asserting a scroll offset, a caret, or any animated end state fails with
the start state, having burned its full wait. Passes when someone is at the machine; fails on
pushes made overnight.

**Mechanism.** The tests mount an offscreen, never-key `NSWindow`. When the display sleeps — or in
Low Power Mode on battery — CoreAnimation stops ticking for it, so a `withAnimation` never
advances and the `scrollTo` inside it never lands. Measured on one commit, one build: 6/6 pass with
the display awake, 5/6 fail with it asleep. Heavy CPU load starves it the same way.

**Fix.** Take the animation from the environment and let the test inject `nil`. Note the trap:
a harness-level `.transaction { $0.animation = nil }` **loses** to an explicit `withAnimation` at
the state change, so the nil has to be where that call reads it.

Then pin the default, or the fix quietly costs you the coverage it bought. Once every test in the
suite injects `nil`, nothing reads what the app actually ships — a default that drifted to `nil`
would delete the animation for real users while the whole suite stayed green. One assertion on the
environment's default closes it, and mutation-check that it is the *only* test that fails when the
default changes; if others fail too, they are reading the shipped value by accident and the
injection is not doing what you think.

**See.** `92e2bdf` — *Decide the column reveal's tests by the code, not the machine's power state*;
`bd3a1e96` — *Pin the reveal animation the app ships* (the default nothing was reading);
`Modules/FileExplorer/Tests/FileExplorer/ColumnPreviewRevealTests.swift`.

### 2. Fixed pumps and fixed sleeps

**Symptom.** Passes under `--filter`, fails in the full suite. Flake rate drifts between batches
rather than sitting at a stable percentage.

**Mechanism.** A fixed window is ample on an idle machine and nowhere near enough when several
hundred tests contend for the main thread. Worse, a fixed sleep *before* an absence assertion makes
it vacuous — "nothing happened" is indistinguishable from "it hasn't happened yet", and the test
passes for the wrong reason forever.

**Fix.** Wait for the movement you expect *first*, then wait out its animation. Poll a real
observable, and drain queue **turns** rather than wall time. Quiescence alone is never sufficient:
it cannot tell "finished" from "not started".

**Live instance, 2026-08-03.** `testCreateFolder` in
`Modules/Sync/Tests/Sync/FileOperationsTests.swift` called `undoManager.undo()`, slept a flat
100ms, and asserted the folder was gone. The undo's removal runs inside
`Task { await enqueueFileOperation … }`, so 100ms was never a bound on anything — it was ample on
an idle machine and short of it under full-suite load on the self-hosted runner. Run
`30823146574` attempt 1 on `v2.x` failed the assertion; attempt 2 of the identical SHA passed,
and the same commit was green on `main`. Replaced with `waitUntil` on the folder's disappearance
plus the usual drain. Mutation-tested by making the undo's removal a no-op: the test now fails at
the 5s timeout with the labeled expectation instead of passing — the wait is read, not discarded.

**Note the shape of the assertion.** This one is safe to wait on because the folder is asserted
*present* first, so the wait watches a real transition rather than an absence. A wait for a state
that was already true when the wait began proves nothing at all.

**"Drain, then sleep a bit more" — check whether the drain was already the gate.** The sweep after
the above found two more, both a `waitUntil` on `activeFileOperationsCount == 0` followed by a flat
200ms / 300ms in front of an absence assertion:
`CopyUndoDriftAndTransientTests.copyUndoRefusesWhenDestinationSizeDrifted` and
`DeleteRedoOccupantTests.deleteUndoRefusedThenRedoLeavesOccupantAlone`. Neither needed the sleep,
and the reason generalises to every undo/redo test here: the handlers registered by
`registerCopyRedo` / `registerTrashItems` (and their undo twins) run **synchronously** inside
`undo()`/`redo()` and call `preCountFileOperation()` **before** spawning the Task that enqueues the
work — unconditionally, even when there are no params to act on. So the count is already above zero
when the wait begins, and `enqueueFileOperation` decrements only after its body returns. That is
what makes the drain a real gate here rather than the quiescence this section warns about: it
genuinely cannot read "not started" as "finished". Both were mutation-tested by putting the refused
item back into the redo params, and both fail without the sleep — in ~0.03s, where the sleeps had
been charging half a second for the same verdict.

A trailing sleep after a wait is worth reading as a signal, not noise: either the wait is not a gate
and needs replacing, or it is and the sleep is dead weight. Establish which before deleting it.

**When the effect is invisible, add the seam — do not settle for a sleep.** The same sweep's last
statement-level instance,
`PaneRetargetInvalidationTests.retargetInvalidationClearsDifferencesButKeepsDuplicates`, slept 100ms
before asserting that `invalidateDifferencesForPaneRetarget`'s follow-up `applyFilters()` pass had
resurrected nothing. Nothing observable moves: the pass runs over already-cleared state, computes
what is already published, and every assignment in the publish block is guarded by "assign only what
changed", so it writes no published property. A queue marker does not substitute — `applyFilters`
suspends on a detached compute, so a Task enqueued behind it runs *during* that suspension, long
before the publish. **Started is not landed**, and that trap catches marker-drains specifically.

The fix was to relax `lastPublishedFilterGeneration` from `private` to a readable (still not
writable) test seam: it moves at the exact moment a pass commits, which is the only thing that
happens at all. Prefer that to a sleep whenever the alternative is a guess — an access level is a
compile-time change, while a guessed window is a permanent hole in the assertion.

That hole was real here, not theoretical. Deleting the insurance pass **entirely** passed under the
100ms sleep and fails at the deadline now. Mutate in both directions when you replace a sleep in
front of an absence: remove the mechanism (does the wait notice it never happened?) *and* model the
bug (does the assertion still fire, and does the wait land before the damage is visible?). Passing
the second alone is what a vacuous wait looks like.

**A sleep that sets up an interleaving is guessing at a PRECONDITION — wait for that, and assert
it.** The sweep's last instance, `BulkOperationsTests.testLatestQueuedScanWins`, slept 10ms between
starting one scan and issuing a second so the second would be *queued* rather than run. Unlike the
cases above, that sleep bridged a real gap — but losing the guess did not fail the test. The two
scans simply ran in sequence, the outcome assertions (one difference, `latest.txt`) held anyway,
and the queue the test is named for went unexercised. **With `runOrQueueScan` mutated never to
queue, the pre-fix test passed.** A sleep protecting a setup step tends to hide a missing assertion
about that step, because the happy path usually produces the same visible outcome either way.

`executeScan` sets `isScanning` synchronously on entry, so the precondition is observable and the
wait can *be* the precondition. Waiting on it also collapsed the test: with the slot held,
`runOrQueueScan` returns without scanning, so the second request needs no Task of its own and
`pendingScanRequest` can be read straight after the call — which is the assertion that was missing.
Dropping the wait now fails three assertions *deterministically*, where the sleep made the same
mistake only under load.

Convert the hand-rolled `while … Date() < deadline` settle loops when you meet them, too: bounded,
so never a hang, but wall-clock rather than `ContinuousClock`, and a loop whose exit condition has
more clauses than the assertions after it passes on timeout for the clauses nobody re-checks.

**A condition wait is a fixed window too — read what its budget is denominated in, 2026-08-03.**
`walkingOntoACloudOnlyFileNeverHandsItToQuickLook` in
`Modules/FileExplorer/Tests/FileExplorer/ColumnPreviewProbeLifecycleTests.swift` did everything this
section asks: it polled a real observable — is a `QLPreviewView` mounted yet — and gave up at a
deadline. It flaked anyway, twice during the v2.9 pre-tag review, because **waiting for the right
thing is only half of it.** Its budget was ten wall-clock seconds, spent one 8ms layout pass at a
time; what it was actually waiting for was main-actor turns. Under a full-package run those two
units come apart:

| Machine | Layout passes the wait got | Wall clock they cost | Held? |
|---|---|---|---|
| idle, `--filter` | 21 | 0.19s | yes |
| full package, 8 spinners | **3** | 13.25s | **no** |

Reproduced deliberately on the procedure above, and the pass count is the whole diagnosis: a loop
sleeping 8ms per turn should manage well over a thousand passes in ten seconds and got three,
because a hundred `@MainActor` suites were mounting views on the one main actor it needed back. Note
which way the requirement moves — the *slower* the machine, the *fewer* passes are needed, since
the 180ms settle and the 1200ms held probe are long elapsed by the second pass. Measured need under
load: **5**, for the probe's hop off the main actor, its resumption, the settle, the state write and
the layout that finally builds the view. It got 3.

Those numbers are from `main` at `05c7a81c`. The file is byte-identical on both lines and it
reproduces on `v2.x` at `4fa91ae4` as well — 1 full-package run in 3 under 8 spinners, failing the
same `settled` require — which is why the fix landed on `v2.x` first.

So the fix is not a longer deadline and not a shorter settle — **neither buys a turn.** It is a
floor on passes: give up only once the deadline has passed *and* `pumpFloor` (50) layout passes
have been made. On a healthy machine the floor is reached in half a second and the deadline still
governs — a regression injected at `hasSettled` still fails in 10.10s, exactly as before, now
naming the 1010 passes it made. Starved, the same wait now clears at pass 5 whenever that arrives:
4/4 full-package runs under 8 spinners, one taking 25.3s to do what takes 1.5s idle. Mutation-tested
on the defect the test exists to catch — the stale probe surviving the item change — which still
fails on the cloud-only path reaching Quick Look, not on the wait.

**Three suites had a private copy of this loop, so fixing one left two bugs.**
`ColumnPreviewRevealTests`, `ColumnPreviewDownloadWiringTests` and
`ColumnPreviewProbeLifecycleTests` carried it byte-identical, against the same congested main
actor; the duplication was harmless right up to the moment the loop turned out to be wrong. It now
lives once, in `LayoutPumpWait.pump`, and the floor with it — the two suites that only ever call
it keep a one-line `wait` of their own, so none of their ~25 call sites moved. **When you fix a
copied helper, grep for its twins before you call it done**; the shape is
`while Date() < deadline { window.layoutIfNeeded() … }`.

**That grep was never actually run, and it was the point.** Corrected 2026-08-03: the claim above
that the loop "now lives once" was false when it was written, and understated the residual by an
order of magnitude. Running the recipe this section itself gives —

```sh
grep -rn -A2 'while Date() < deadline {' Modules --include='*.swift' \
  | grep -E 'layoutIfNeeded|layoutSubtreeIfNeeded'
```

— finds **two more byte-identical copies** of the migrated helper, which have now been migrated to
`LayoutPumpWait.pump`: `CloudDownloadWiringTests.settle` and
`PaneBackgroundDeselectMountedTests.settle`. That is the same "fixing one left two" failure the
shared seam exists to prevent, one radius out, and this doc asserting it could not happen is what
stopped anyone looking. The signature stayed on both, so none of their call sites moved.

**Sort the rest by whether there is a condition to starve — that is what `pumpFloor` fixes.** A
loop with no condition is a fixed settle, a different (and separately recorded) problem; the floor
does nothing for it.

*Conditional, wall-clock-bounded, still unfixed.* These are the real residual:

- `ExpandingSearchFieldTests.becomesEditingText` — in **Design**, not FileExplorer. A sweep that
  greps only `Modules/FileExplorer` will not see it.
- ~~`HeaderLadderTests.settle(_:atRows:)`, `SectionRowHeightTests` and
  `DifferencesTableIdentityTests.settle(_:atRows:)`~~ and
  ~~`DifferencesTableIdentityTests.wait(for:timeout:)`~~ — **all four migrated 2026-08-04.** They
  polled `layoutSubtreeIfNeeded()` on a host **view**, not a window, and returned a *measurement*
  rather than a Bool, so adopting the floor needed a view-based entry point on `LayoutPumpWait`
  rather than a substitution. That entry point exists, and they now use it; each returns its pass
  count alongside its measurement and every caller names it in the failure message.

  **What prompted it, and the part worth copying.** Two of them failed in the same seven
  full-package runs — `DifferencesTableIdentityTests.widthSurvivesTheGroupingToggle` at 0 rows
  against 12, `SectionRowHeightTests.comfortableDrawsTheHeaderAtTheFloor` at no rows at all — while
  new mounted-view suites (the lens-cache work) were landing alongside. That is the second time
  added mount load has tipped an unmigrated wait, after `FoldAllToggleBindingTests` below, and it
  is the reason to migrate the residual rather than wait for each one to be seen.

  **The floor itself is now tested** (`LayoutPumpWaitTests`), which it never was, despite ten suites
  in the target depending on it. That matters because the floor's guarantee could not be shown from
  the migrated suites: on an idle `--filter` run their rows arrive on the FIRST pass, so setting the
  deadline to zero and watching them pass proves nothing — a check that looked like a verification
  and was not. The guarantee is a property of the loop, and against a counter it is deterministic:
  with the deadline already spent, a condition needing 25 passes still gets them. Mutation says
  `pumpFloor = 0` fails it; `pumpFloor = 24` does **not**, because the loop re-evaluates
  `condition()` once after the deadline, so the real guarantee is `pumpFloor + 1` evaluations.
- `ColumnDrillSourceTests.settle` — **the grep above misses it**, because it writes
  `while !condition() && Date() < end`. It does fail on expiry via `#require`, so it cannot pass
  vacuously, but it forwards no `#_sourceLocation`, so every caller's timeout is reported against
  the helper's own line.

*Unconditional fixed pumps — not this defect.* `pump(_ window:seconds:)` in
`ColumnClickCostBenchmark`, `ColumnPreviewLayoutTests`, `ColumnPreviewRevealTests`,
`ColumnTapSelectionTests`, `PaneColumnsLayoutLoopTests`, `PaneColumnsScrollTests`, and in the three
layout-budget suites. They pump for a fixed interval and check nothing, so there is no condition to
be starved of turns.

**One of them has now been seen to fail — 2026-08-04, `FoldAllToggleBindingTests`.** It gave up in a
full-package FileExplorer run with the table showing **0 rows** against an expected 15, and then
passed three times out of three under `--filter`. That is this mechanism with nothing else in it:
its wait was a bare `while Date() < deadline` with fifteen seconds, no pass floor, and a 50 ms sleep
per turn. Fifteen seconds *looks* generous, which is exactly why the shape survives review — the
rows need main-actor turns and a congested run has fewer of them per second, not more.

It has been migrated to `LayoutPumpWait.pump(_ view:upTo:until:)` and now reports its pass count on
failure. The run that surfaced it was made congested by new mounted-view suites landing alongside
(the pane search); nothing about the defect was new, only the load.

The rest are listed by name, and by category, so the next sweep starts from a true inventory instead
of rediscovering one — **and note that the grep recipe above is necessary but not sufficient**: it is
blind to the `while !condition() && …` form and to waits outside `Modules`.

**The failure message should name the passes, not just the verdict.** A wait that gave up after 3 of
them was starved; one that gave up after 1010 was disproved. That is the difference between this
mechanism and a real bug, and it costs one integer to report.

**Live instance, 2026-08-03 — quiescence cannot see a scroll that moves nothing.**
`ColumnPreviewRevealTests.testClosingThePreviewLeavesAScrolledBackStackWhereItWas` failed its
fixture, `#require(clip.bounds.origin.x == 0)` reading **570.0**, "fixture failed to scroll the
stack back". A reveal is two attempts: one deferred a main-queue hop, one at `revealRetryDelay`.
Both resolve the same target, so once the first has landed **the second moves the stack by zero
points** — there is no movement for a quiescence window to see, and `settle` reports the stack at
rest while the retry's `proxy.scrollTo` is still owed a SwiftUI update. Idle, that update is the
very next turn (measured: one turn after the attempt makes its call, 3/3) and nobody notices. Under
the congestion the entry above measures it arrived over a second later — *after* the test's own
scroll-back — and put the stack back on the reveal's target. Traced on a failing run: retry issued
at t+0.52s, test scrolled to 0 at t+0.85s, stack at 570 by t+2.3s with no attempt having run in
between.

This is the trap `settle`'s own doc comment names, arriving from the side it does not cover.
Waiting for the movement you expect first is not enough when a *later* mover is a no-op at the
moment it fires: quiescence cannot tell "finished" from "issued, and worth zero points until you
move".

Fixed by draining the reveal chain *before* the scroll-back rather than trusting stillness after it
(`quiesceReveals`, called from `scrollBack`), bounded by the QUEUE the way `maxOriginDrift` already
bounds its absence: a marker queued now has a strictly later deadline than any retry an earlier
trigger queued, and the main queue drains `asyncAfter` blocks in deadline order, so when it fires
every attempt has RUN however far the machine has slipped. **Running is not landing**, so a turn
drain follows it.

**Verified deterministically rather than by re-rolling the flake**, which is the part worth copying:
with `openPreview`'s trailing `settle` removed so the retry is guaranteed outstanding, removing
`quiesceReveals` reproduces `origin.x → 570.0` on an **idle** machine under `--filter`, and
restoring it passes. A flake fix that can only be argued from pass rates is a flake fix you cannot
check; find the ordering that makes it certain. Mutation-tested on the defect the test exists for —
the unconditional falling-edge reveal — which still fails `maxOriginDrift`, i.e. reaches the real
assertion instead of dying at the fixture. Then loaded full-package runs, zero occurrences: 8 while
this fix was carried alongside an equivalent-in-spirit version of the entry above, and 5 more on the
shipped pairing of the two (3 on `v2.x`, 2 on `main`), plus CI green on both. Before: 5 of 7.

**The shared `waitUntil` had the same defect as every helper above, and the widest reach of any of
them — floored 2026-08-08.** `Modules/Sync/Tests/Sync/TestSupport.swift` and its byte-identical twin
in `SyncCloudTests/TestSupport.swift` were `while ContinuousClock.now < deadline`, five seconds, a
10 ms sleep, no floor. Every Sync and app-target suite waits through them — ~150 call sites, none of
which passes an explicit `timeout:`, so the default was the whole budget and a floor could not
collide with a deliberately short one.

**Reproduced here before porting the fix, rather than assumed from the suite next door.** Poll
counts logged across a full Sync run: most waits return on the *first* poll, and the tail is where
the shape shows — 4 polls in 0.523s idle, and under the CPU-spin recipe above a worst rate of
**223 ms per poll** against a nominal 10 ms. Five seconds buys ~500 evaluations at the nominal rate
and ~22 at that one. No Sync wait has been *seen* to fail; the margin is what was gone.

`waitPollFloor = 50` on both copies, and the poll count now goes in the failure message. Mutation:
with the deadline set to **zero**, all 1167 Sync tests still pass — the floor alone carries all 135
waits a full run makes.

**The floor is tested this time** (`WaitUntilFloorTests`), rather than left as the untested constant
`pumpFloor` was. Same shape as `LayoutPumpWaitTests`, and it reproduces that suite's two results
exactly: `waitPollFloor = 0` fails the floor test twice (the helper's own labeled expiry at 0 polls,
then the count at 1 against 25), while `waitPollFloor = 24` — one under the demand — fails **only**
the premise guard, because the post-deadline re-check buys a 25th evaluation. The real guarantee is
`waitPollFloor + 1`. Note what cannot be tested here: `waitUntil` reports expiry by *recording a
failure* rather than returning a Bool, so there is no passing test for the never-holds case; that
half was checked by hand.

**The sweep that finds this defect keys on the BOUND, not on the body — and the older recipe above
does not.** That one filters `while Date() < deadline` by a following `layoutIfNeeded`, so it sees
only layout pumps: it misses a condition wait that pumps nothing, misses `ContinuousClock`
entirely, and misses any helper whose closure is not spelled `condition()`. A floored loop reads
`while <n> < <…>Floor || <clock> < deadline`, so excluding `Floor` leaves exactly the unfloored
ones, whatever they poll:

```sh
grep -rn --include='*.swift' -E 'while .*(Date\(\)|ContinuousClock\.now) *<' Modules SyncCloudTests \
  | grep -v '/\.build/' | grep -vi floor
```

**The exclusion must be case-insensitive, and it was not.** The recipe published here filtered
`grep -v Floor`, which counts a loop floored with a lowercase variable — `while polls < floor ||
…`, the form a helper that names its own parameter `floor:` produces — as *unfloored*. It inflated
this line's headline number by one, because `ShortcutRevealTrackerTests` is floored
exactly that way — and the whole point of quoting a reproducible command is that the number it
prints can be trusted. (`v2.x` was unaffected: it has no such loop.)

Run on this line 2026-08-18: **38 unfloored clock-bounded loops**, against 4 floored ones correctly
excluded. Most of the 38 are fixed pumps with no condition to starve — the separate problem this
section already distinguishes. The one shape that *does* poll a condition, and so still carries
this defect:

- `BulkSyncCancellationAndReservationTests` and `MergeCancelMidCopyTests` — **do not fix these
  alone.** `awaitProgress()` is a *synchronous* method on a mock `FileManaging`, called from the
  seam, so it can neither be `async` nor use this package's already-floored `waitUntil`; it must
  block a real thread. That is mechanism 10's structure exactly, and mechanism 10's proposed real
  fix — a dedicated thread outside the cooperative pool — is the same fix these two want. Doing
  them separately means rebuilding the same seam twice.

`ExpandingSearchFieldTests`, `CloudDownloadWatchTests` and `CloudDownloadWiringTests` came off this
list on 2026-08-18. **`CloudDownloadWiringTests` still has a hit at `WatchPark.park`, and it is not
this defect**: that loop detects *cancellation* — a cancelled `Task.sleep` throws at once — and its
`!released` clause is a cooperative exit so a 45 s park does not outlive the test. There is no
condition being starved, and a floor would be meaningless on it. Sort by "is there a condition to
starve" before adding anything here.

Naming one and calling it "the real residual" is how this list stayed wrong through two sweeps; the
count above is reproducible, so check it rather than trusting the prose.

**This section reached `v3.x` on 2026-08-17, eight days after the fix it describes.** The fix
commit landed on `main` and was carried to `v2.x`, and nothing carried it here — so this line went
on running the unfloored wait, and CI proved it twice within an hour: `testAListParkedInTop\
OverscrollIsPulledHome` gave up at 46.1s and `testAListParkedPastTheBottomIsPulledToTheEnd` at
39.9s, on two consecutive runs where `main` and `v2.x` were green on the same code. Two sightings
on one line while the others pass is not load; it is a missing backport, and it is worth writing
down that the flake register itself can be the thing a line is missing.

**`PaneColumnsScrollTests` is the one that is fixed, and it is off the list because it was SEEN to
fail rather than because it was next.** On 2026-08-09 `testARestTheGrownViewportMadeIllegalIsPulled\
Back` gave up after 49.6s in CI, on a runner that was simultaneously building another checkout —
the second sighting of this mechanism in the wild after `FoldAllToggleBindingTests`, and the first
to take a run red. Both of that file's `waitForOrigin` copies (byte-identical, in two suites) now
delegate to `LayoutPumpWait.poll`.

`poll` is a NON-pumping floored wait, and the distinction is the point: `pump` drives layout every
turn, which is right for a layout result and wrong here — the clip's origin is moved by the
watchdog, not by a layout pass, and `layoutIfNeeded` disarms AppKit's runaway-layout guards, so
substituting `pump` would have been the tidy migration and would have quietly widened what a
sibling suite tolerates. What is shared is the FLOOR, which is the part that was wrong.
`LayoutPumpWaitPollTests` pins it, beside the existing `LayoutPumpWaitTests`, with the same
`pumpFloor = 0` / `= 24` mutation results the `pump` floor records.

**One trap this fix walked into, worth knowing before you write the next entry here.** The first
version of the new doc comment quoted the old loop verbatim — the literal string
`while` + `Date() < deadline` on one line — which the sweep above counts. Two real loops were
removed and two comment lines took their place, so the total did not move at all and *looked* like
a change that had done nothing. Prose in this repo is inside the grep's haystack: quote a defective
loop by describing it, not by reproducing it.

**And the fix's own deadline test was this exact defect, twice.** It first asked for `pumpFloor +
20` passes inside a 5-second deadline: green under `--filter`, red in the full FileExplorer run at
51 passes against the 70 it wanted. Retuned to `pumpFloor + 2` inside *sixty* seconds it still got
only 51 — because 50 passes cost over a minute in `main`'s FileExplorer run against ~5 seconds in
`v2.x`'s, a 12× spread between two runs of the same kind of suite. **There is no deadline generous
enough to be safe: seconds do not convert to passes at any fixed rate, which is this whole mechanism
in one sentence.** So `poll` takes an injectable `now`, and the test freezes it — the deadline is
then permanently live and the CONDITION decides when the loop ends, which is a property of the loop
rather than of the machine. Anything asserting that N seconds buys more than the floor is a
throughput bet; write the discriminator instead.

**Both numbers and both lists are per-line, like this file's SHA refs.** `v2.x` reads 42 and 4, and
its residual is eight, because the four view-based settles migrated on `main` on 2026-08-04 are
still unmigrated there — and its floored count is lower because it has neither the Dashboard copy of
`LayoutPumpWait` nor the view-based `pump` entry point `main` added to the FileExplorer one, only
the window-based original. It does now carry `poll` and `LayoutPumpWaitPollTests`, which is where
this fix landed first. Re-run the sweep on the line you are on; do not cherry-pick the count.

**See.** `c2584e6` — *Poll the drill tests' observables instead of pumping a fixed window*;
`3a4ee8a` — *Poll for the revealed search field's caret instead of a fixed pump*;
`33bcc30d` — *Wait out the New Folder undo instead of guessing 100ms at it*;
`9543b941` — *Let the drain be the gate the two redo tests already had*;
`156cea74` — *Wait for the insurance filter pass to publish, not for 100ms*;
`4347dfcd` — *Wait for the scan slot the queued-scan test needs, and assert it got queued*;
`pumpFloor` and `pump` in `Modules/FileExplorer/Tests/FileExplorer/LayoutPumpWait.swift`;
`quiesceReveals` in `Modules/FileExplorer/Tests/FileExplorer/ColumnPreviewRevealTests.swift` — the
last two cited by symbol rather than SHA on purpose, since this file's SHA refs are per-line and a
cherry-pick between `v2.x` and `main` has to swap every one of them by hand.

### 3. Process-wide state, and suites running in parallel

**Symptom.** A suite fails only when a specific other suite runs; two suites pass alone and fail
together; a test observes a change it never made.

**Mechanism.** Static caches, memos, and `UserDefaults` are process-wide, and swift-testing runs
suites in parallel by default. The sharpest edge: **`@AppStorage` notifies by key *name*,
process-wide.** `.defaultAppStorage` isolates the stored *values*, not the change *events* — so a
write in one suite fires another suite's `onChange` driver even with separate suites.

**Fix.** `@Suite(.serialized)` on anything that writes process-wide state, with the reason in the
doc comment — every one of them says why it needs it. For values, use a per-mount scratch defaults
suite rather than the standard domain.

**Known residual — recognise it before you bisect.** `.serialized` closes only the *intra*-suite
half: it stops a suite's own writers overlapping its own assertions. A *different* suite writing
the same key concurrently is untouched, and swift-testing offers nothing finer — the only real fix
is nesting the suites under one `.serialized` parent, which costs more wall clock than the flake
does. So this is deliberately left open. The signature, all four together:

- an **absence** assertion fails ("this must stay where the user put it"), not a positive one;
- the observed value is the pane's exact **legal extreme** — a scroll offset equal to the far end,
  never an arbitrary number;
- it does **not** reproduce under `--filter`, only in the full suite; and
- the rest of the run is green.

That combination is another suite's mount, not your bug. The live instance is
`ColumnPreviewRevealTests`' two absence tests against `ColumnPreviewLayoutTests`, which writes all
three pane-width keys on every mount; the failures land at exactly 150pt and 570pt. Never observed
in ~20 full-suite runs, so it stays unfixed — **if it does fire, that is the signal to spend the
restructure**, and worth a line here recording that it finally did.

**It looked like it fired, 2026-08-03 — and it had not. Read this before spending the
restructure.** Two full-package runs under load failed `clip.bounds.origin.x == 0` at exactly the
two numbers this section predicts: **570.0** in `testClosingThePreviewLeavesAScrolledBackStackWhereItWas`
on `main` at `05c7a81c`, **150.0** in `testAPreviewWidthCommitLeavesAPreviewlessPaneAlone` on `v2.x`
at `4fa91ae4`. Two tests, two extents, both named above. It was recorded here as the predicted
mechanism confirming itself; it was not that, and the way it was caught is worth more than the
correction.

**Both are `#require`s in the FIXTURE, not the absence assertions.** The signature's first point is
that an *absence* assertion fails — the `maxOriginDrift` line, "this must stay where the user put
it". `clip.bounds.origin.x == 0` two lines above it is the fixture checking its own scroll-back took,
and it fails with the message "fixture failed to scroll the stack back". Same test, same number,
different claim. The cause is the pane's **own** reveal retry landing after that scroll-back —
mechanism 2, written up under [that section](#2-fixed-pumps-and-fixed-sleeps) — and it was then
reproduced **deterministically on an idle machine under `--filter`, with three tests of this one
suite running and `ColumnPreviewLayoutTests` nowhere in the process.** No foreign write can be
involved in a run that mounts no foreign pane. Since the fix, 8 loaded full-package runs, zero
occurrences.

So the residual **remains unfired**, and the restructure it defers still has no signal. What this
episode adds is a sharper test for the next candidate, because the number and the test name are now
known to be reachable two ways:

- **Check which line failed.** Absence assertion, or fixture? Only the first is this mechanism.
- **Check whether a foreign pane was even mounted.** `--filter` to this suite alone: if it still
  reproduces, nothing process-wide is involved. This is the step that settles it, and it is cheap.
- A re-render driven by another store's write was measured *not* to move a stack by itself — SwiftUI
  restores no remembered offset here — so a foreign write can only reach a pane through a reveal
  DRIVER its edge guards let through. That narrows what to look for to four `onChange` handlers.

**See.** `d282ac6` — *Isolate DifferencesView test mounts in per-mount scratch defaults*;
`Modules/FileExplorer/Tests/FileExplorer/CloudOnlyBadgeCacheTests.swift` for the shape of the note.

### 4. Leaked defaults suites

**Symptom.** Accumulating `<SuiteName>-<UUID>.plist` files in `~/Library/Preferences`, and
occasionally a test reading a previous run's value. **At enough scale it stops being cosmetic and
starts failing tests** — see the stall below.

**Mechanism.** A defaults suite outlives the test that made it; `cfprefsd` rewrites the backing
plist after the process exits.

**Fix.** Tear the suite down *and* delete its backing plist; record every wiped suite in the
ledger, and sweep by SHAPE as well as by name (below).

**"Bounded and self-clearing" was wrong — 3,551 had accumulated by 2026-08-03.** This entry used
to say the count oscillates rather than grows, and to measure across several runs before believing
the mechanism was broken. Do not trust that: it is exactly the advice that lets a real leak sit.
The ledger can only ever sweep what a *previous run recorded*, and most creation sites are a bare
`UserDefaults(suiteName:)` with a `defer` — they record at wipe time, so a run that is **killed**
(cancelled CI job, interrupted `swift test`, a mutation experiment stopped by hand) leaves suites
nothing will ever name. A session doing many such runs leaks steadily and invisibly. The ledger
held ~108 names against 3,551 files on disk.

The sweep now also matches `<prefix><-|.><UUID>.plist` with **uppercase** hex, older than an hour,
which needs no prior record and so covers killed runs too. Two edges, both mutation-tested in
`ScratchPlistSweepTests`: the **uppercase requirement is the safety margin**, because real domains
carrying a UUID write it lowercase (`com.openai.chat.RemoteFeatureFlags.164320f2-…`) — relax it to
case-insensitive and the sweep deletes real preferences. The **age floor** is what makes it safe
while other worktrees are testing concurrently; their live suites are minutes old.

**What it costs when it gets bad.** Cold `defaults domains` — which enumerates that directory —
measured **2.38s** at 4,036 files and **0.10s** at 538. `cfprefsd` is one daemon shared by every
process on the machine, so a stall there is felt process-wide, by every test touching defaults at
once.

**Telling that stall from ordinary machine load — read the PASSING durations, not just the
failures.** On 2026-08-03 six tests failed and it looked selective, which points away from
environment. It wasn't: **259 of 1226 tests took ≥10s in that run, against 3 in a green one**, and
the run's total wall clock was only 14.76s — impossible unless everything in flight went through
one global ~10s freeze. The six "failures" were merely the only tests carrying a 10s bound; they
were the detector, not the cause. Chasing what those six had in common (they shared the semaphore
gates) was a wrong turn — the shared thing was the deadline.

**See.** `8c46d65` — *Delete the backing plist when a test's scratch defaults suite is torn down*;
`5b495f7` — *Record every wiped defaults suite in the ledger, not just ScratchDefaults'*;
`074ba127` — *Sweep the scratch plists a killed run could never record*.

### 5. Tests racing a real-time window

**Symptom.** Fails near a boundary — a freshness cutoff, a recency window — and only sometimes.

**Mechanism.** The test races wall-clock time it does not control. Unwinnable by construction.

**Fix.** Inject the instant (`at:` / `now:`) so the window is a value, not a race.

#### Seen: `ScanSupersedenceTests.testScanQueuedFromCancelledPredecessorStillPublishes`

Red on CI at `e10bdbf6` (2026-08-04), on `await waitUntil("scan starts") { manager.isScanning }`,
followed by the two assertions that depend on it. **A rerun of the very same SHA passed**, and the
commit under it touched only `Modules/FileExplorer` tests and a doc — while CI runs packages
**sequentially with `Modules/Sync` first**, so that suite had finished before anything of the
commit's ran. It is the flake, not the change.

The window is `mockFM.enumeratorDelay = 0.15`: scan A must still be walking when the test observes
`isScanning`. Miss the 150ms and A has already finished, `isScanning` is false, nothing queues, and
all three assertions fall together — which is what makes it read like a real supersedence
regression rather than a timing miss.

**Not reproduced locally in 28 runs**: 12 `--filter` idle, 8 `--filter` under eight spinners, 8
full-package idle, 6 full-package under load (loadavg 10.7). So the CI runner's own
osx-x64-under-Rosetta environment is part of it, and a local green says little here.

Left alone deliberately rather than half-fixed by widening the delay, which only moves the
boundary. The real fix is mechanism 5's: make the walk's progress a value the test controls — a
seam that lets it hold A inside the walk until the assertions have run — instead of racing 150ms of
wall clock. Worth doing when someone is next in this file; worth knowing about before blaming a
commit for it.

### 6. Load-scaled benchmarks

**Symptom.** A timing assertion fails on a busy machine and passes on an idle one.

**Mechanism.** An absolute threshold encodes the machine it was written on.

**Fix.** Retune from the test's own printed measurement rather than guessing, and validate that the
assertion can fail using CPU spin — never `sleep`.

**A ratio is not immune, 2026-08-03.** `HeaderLadderCostBenchmark.computingTheRungBeatsSearchingForIt`
failed the full package with `speedup → 1.7575 > 1.8`, a 2.4% miss. Its comment argues a ratio
needs no nominal constant and "a faster machine cannot break it" — true of a faster machine, false
of a *contended* one, because the two arms are sampled **sequentially**. Load that drifts between
the searched arm and the computed arm lands entirely in the ratio, so the quantity that was
supposed to cancel does not.

It was environmental. Interleaved full-package runs, alternating the pre-change commit and the
change under test on the same loaded machine (CI was running concurrently — the runner is this
Mac):

| Round | pre-change | with the change |
|---|---|---|
| 1 | 2.71x | 2.58x |
| 2 | 2.24x | 2.84x |
| 3 | 2.89x | 2.57x |

3/3 green on both arms, means 2.61x and 2.66x against a 1.8 bar — the failing 1.76 sits outside
both. **Interleave the arms; do not run all of one then all of the other**, or the load drift
becomes the result. The suspicion was worth checking rather than waving away: the change under test
lengthened a main-actor pump in a suite that runs in parallel with this benchmark, which is a real
causal path, just not the one that fired.

### 7. The machine decides the verdict — the keyboard

**Symptom.** A mounted-view test spends its whole deadline and reports the end state it started
with. Looks exactly like mechanism 1 or 2, but the machine is **idle** and the rest of the suite is
its normal speed. One test fails while its siblings, waiting on the same thing, pass.

**Mechanism.** Production code consulted `NSEvent.modifierFlags` — which is not a property of the
event, the view, or even the process. It is **the global state of the machine's keyboard, sampled
at the instant the code runs.** `PaneColumnsView`'s navigation guards used it to answer "is this a
plain click?", so `ColumnDrillSourceTests` — which drives `selectRowIndexes` directly, with no
event and no modifiers of its own — was really asking *what is the person at this Mac holding
right now*. Hold ⇧ or ⌘ at that instant and the guard correctly refuses to navigate, the deferred
block is never queued, and the test waits out its full 20s for something nobody asked for.

Sampled at 50 Hz while someone worked normally at this Mac: **5 distinct blocking holds in 35
seconds**, ⇧ and ⌘, the longest 1.26s — about 5% of instants. A full suite holds the window open
for minutes, which is why `--filter` never reproduced it.

Note what this is *not*: the same suite under CPU spin at load 11 delivered its navigation in 10s
and passed. Starvation is real here and the deadline absorbs it with about 2× to spare; it is
worth knowing that margin is 2× and not 100×, but it was not the cause.

**Fix.** Take the modifiers from the environment (`paneClickModifiers`), defaulting to `nil` =
ask the keyboard, so the app is unchanged and the test pins `[]`. Pin `.shift` and the failure
reproduces on the exact signature, which is how it was confirmed — and that pin is now a test in
its own right, covering the ⇧-selects-without-navigating rule that had no mounted coverage.

Any ambient global read has this shape. `NSEvent.modifierFlags` is still read directly in
`DifferencesView`, `PaneBreadcrumb`, `ModifierTracker` and `MacApp/ContentView.swift`'s
`applyColumnNavigation` — that last reads the same link-or-⌥ test as `PaneBreadcrumb`, so the app
target is NOT clean either. None is under a test that drives it today, but the seam is the answer
if one grows.

**See.** `Modules/FileExplorer/Tests/FileExplorer/ColumnDrillSourceTests.swift`;
`paneClickModifiers` in `PaneColumnsView.swift`.

### 8. The wait that hangs instead of failing

**Symptom.** No verdict at all. The run produces no test output and never finishes; the log stops
mid-line — often right after `Build complete!` — and names no test. One core sits pegged near
100%.

**Mechanism.** This one is *not* a flake: it is deterministic, and it is in this file because the
symptom sends you hunting for one. An unbounded `while <condition> { await Task.yield() }` has no
exit but the condition, so a regression that stops the condition from ever holding converts a test
*failure* into an infinite busy spin. Two things then conspire to tell you nothing: `swift test`
buffers stdout in blocks, so the log freezes rather than reporting how far it got, and a live pid
is not evidence of progress. On 2026-08-02 a change that made `confirmVerifiedCopy()` return nil
left `testVerifiedCopyExcludesConcurrentBulkRuns` spinning on `bulkSyncProgress == nil` for 15+
minutes at 25% CPU. This is the worst case on the self-hosted runner, which is the same Mac local
builds use.

**Diagnosing it.** `sample <pid>` is the only truth — macOS has no `timeout(1)`, and neither the
log nor the pid will tell you which test is stuck:

```bash
pgrep -f SyncPackageTests
sample <pid> 5 -file /tmp/hang.txt
```

**Fix.** `waitUntil(_:timeout:_:)` in `Modules/Sync/Tests/Sync/TestSupport.swift`. It polls a
main-actor condition, gives up at its deadline, and records a **labeled** `#expect` failure, so the
run continues on to the real assertions instead of parking. Measured with the same regression
injected at the call site: the old spin was still running at 155s at 117% CPU and never
terminates; the bounded wait failed at 5.03s naming its condition, followed by the five downstream
assertions.

Bounded waits are fine and should be left alone — a `ContinuousClock` deadline in the loop
condition, or a `for _ in 0..<N { await Task.yield() }` settle loop. Both terminate. Grep for the
shape; every hit must carry a deadline. Scope it across **both** test corpora — `Modules/*/Tests`
alone cannot see the app-level `SyncCloudTests/` target, and a check that never looks at a third
of the tests will eventually certify a hang it never examined:

```bash
grep -rn "await Task.yield()" Modules SyncCloudTests | grep "while "
```

A deadline is only half of it: a bound whose **expiry is discarded** converts a hang into a
vacuous pass. The loop returns, the test carries on against state it never actually reached, and a
positive control asserts nothing — "the gate engaged and the result still published" and "the gate
never engaged" look identical afterwards. Record the timeout and assert on it, the way
`awaitSignal` and `FirstStatGate.releasedByTimeout` in `Modules/Sync/Tests/Sync/TestSupport.swift`
do, and `parkUntilReleased` in `FileSyncManagerFilingTests.swift` does for the classifier parks.

**See.** `75cf7904` — *Bound the four spin-waits that could hang the Sync suite instead of
failing*; `Modules/Sync/Tests/Sync/InFlightSyncStateTests.swift`.

### 9. A mounted view is a live subscriber, in every suite at once

**Symptom.** A suite that asserts one surface *ignored* something starts failing the day an
unrelated suite gains a mounted-view test. It passes under `--filter` every time; it fails in the
full run most times. The value it reads has been changed by nobody it can see.

**Mechanism.** A mounted SwiftUI view is not inert — it holds whatever subscriptions its body
declares, and `NotificationCenter.default` is process-wide. `FileTreeView` carries one
`.onReceive(.cloudDownloadRequested)`, and it used to be scoped by `PaneToken` alone — a token
names a *surface*, not a test, so **every mounted left pane in the process accepted every `.left`
post in the process.** `CloudDownloadWiringTests` posts from `.left` to prove a right pane ignores
it, a left pane mounted by a different suite latched it instead, that pane's watch called
`CloudOnlyBadgeCache.forget`, and the ghost path the assertion rests on went `nil`. Measured on
2026-08-02: adding one left-pane mount to `ColumnPreviewDownloadWiringTests` took
`theRightPaneIgnoresTheLeftPanesRequest` from "never seen to fail" to 3 failures in 3 full runs.

It is mechanism 3's family, but the actor is different and so is the fix: no cache is being
written and no defaults key is shared. What is shared is the *notification*, and `.serialized`
cannot help because the two suites are different suites.

**The token workaround this section used to prescribe was bankrupt, in two ways.** Pick a surface
no other suite posts — except all three are already spoken for as the *ignored* token somewhere
(`.left` by two routing tests, `.right` by a third, `.singleSource` by the suite that took it), so
a fourth mounting suite has nothing left to pick. And worse, it hid the failure the other way
round: a foreign pane on the surface a routing test uses as its POSITIVE control forgets that path
*for* it, so the control is satisfied by a stranger and the test asserts nothing about the pane it
mounted. **No mutation could have caught that**, which is the sharpest way to see it: on a shared
channel the pane under test and a foreign pane of the same surface run the same code, so any edit
that deafens one deafens both. There was nothing to vary.

**Fix — give each mounted pane a channel of its own.** `FileTreeView(downloadChannel:)` takes the
`NotificationCenter` its subscription is built on, and `CloudDownloadRequest.post(…, through:)`
takes the one to announce on. Both default to `.default`, which is what the app runs on — it has
exactly one pane per surface, so the routing decision is unchanged there. A test passes a fresh
`NotificationCenter()` per mount and posts through that same one. Two panes on two channels cannot
reach each other whatever tokens they carry, and a positive control can only be satisfied by the
pane the test mounted.

**The two production posters thread it as well, as of 2026-08-03.** The row context menu's Download
(`FileContextMenu`) and the preview column's button (`ColumnPreviewColumn`) both used to call
`post` with no `through:`, so they resolved to `.default` however the pane around them was mounted.
In the app that is the same object and nothing shipped changes; the gap was that the invariant
above held only for tests posting *directly*. A test that mounted a pane on a private channel and
drove the real Download would have posted to `.default` — the pane under test never hears its own
request, which reads as a routing defect that does not exist, while whatever else is on `.default`
acts on it. The channel is now carried down `FileTreeView` → `PaneColumnsView` → `FileContextMenu`
/ `ColumnPreviewColumn`, so a pane and its own posters are on one channel whichever channel that
is. Neither call site is reachable from a test today (both sit behind a real `MaterializationStatus`
call against a provider placeholder), which is exactly why this was worth fixing before it bit.

**Every test that mounts a `FileTreeView` must pass one** — including the ones with no interest in
downloads at all (`PaneOutlineRepublishTests`, `PaneColumnsLayoutLoopTests`,
`ColumnClickCostBenchmark` all do), because the subscription exists whether the test wants it or
not. Unlike picking a token, this never runs out. As of 2026-08-03 every mounting test in the
package carries its own channel; none is left on `.default`.

Verified by mutation, from a pristine copy: with the pane's `.onReceive` dropping every post, all
three ignore tests fail on their TAKEN assertion rather than passing the absence vacuously. The
control is load-bearing at last.

**Which cost the shipped default its only coverage, so pin it directly.** While one mounting suite
was still on `.default`, a default post really did travel to a default-channel pane once per run.
Now nothing exercises `.default` at all, and both halves of it are a silent edit away: retarget
`CloudDownloadRequest.post`'s `through:` default and the app's Download button announces into a
void, retarget `FileTreeView.downloadChannel`'s and every pane goes deaf — with every suite green
either way, because they all pass their own. Two assertions close it, and neither mounts anything:
`CloudDownloadRoutingTests.theDefaultChannelIsTheAppsOwn` posts with no `through:` and observes
`.default` (filtering on a per-run unique path, or a parallel suite's post would satisfy it), and
`FileTreeViewPaneNameTests.testAPaneMountsOnTheAppsChannelByDefault` reads the property off a pane
built the way `ContentView` builds one. Both were mutation-checked against the retargeted defaults.
**Anything given a test-only default needs this**: the moment the last real user of a default is a
test that stopped using it, it is unpinned.

**And note what pinning the poster costs: the rule now runs both ways.** `theDefaultChannelIsTheAppsOwn`
cannot pin `post`'s default without putting a real `.cloudDownloadRequested` on `.default`, so it is
the one thing in the target that posts there. Nothing hears it today — `FileTreeView`'s `.onReceive`
is the only subscriber to that name in the codebase, and no test mounts a pane on `.default`. Mount
one there again and that post arms a real `.left` watch inside it, against a path with no file
behind it, for the poll's full ten-second budget. So "every mounting test passes its own channel" is
not merely hygiene for the mounting suite; it is what keeps the poster's pin harmless.

Tear the mount down too — `window.contentView = nil` in a `defer`, which drops the last reference
to the SwiftUI graph and takes the subscription with it. It bounds a pane's afterlife within its
own suite; the channel is what separates one suite from another. And do not reach for
`window.close()`: a `.titled` window is released on close by default (`isReleasedWhenClosed`),
which over-releases the test's own reference and kills the process with no verdict at all —
mechanism 8's signature, from a line that looks like tidying up.

**See.** `Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift` (`downloadChannel`),
`Modules/FileExplorer/Tests/FileExplorer/CloudDownloadWiringTests.swift` (`mount`, `teardown(_:)`),
`Modules/FileExplorer/Tests/FileExplorer/CloudDownloadRoutingTests.swift`
(`theDefaultChannelIsTheAppsOwn`).

### 10. A log assertion reading a window that has already rolled

**Symptom.** Two shapes, and it is the second that earns this entry.

- A **presence** assertion fails for a line that really was written — in the full suite only, never
  under `--filter`, and re-running sometimes clears it.
- An **absence** assertion **passes**, having looked at nothing at all. There is no symptom. That is
  the symptom.

**Mechanism.** `Logger.shared` is one process-wide singleton, `entries` is one published array
(`Modules/Events/Sources/Events/Logger.swift:166`), and it is capped at the newest **1000** lines —
`Modules/Events/Sources/Events/Logger.swift:376`:

```swift
if entries.count > 1000 {
    entries.removeFirst(entries.count - 1000)
}
```

swift-testing runs suites in parallel — the same premise as mechanism 3 — so every suite in the
package writes into that one array at once. A test that reads `Logger.shared.entries` *whole* is
therefore reading a window whose contents were decided by whatever else happened to be running, and
1000 lines is not many when a full package run is walking trees and syncing files in a dozen suites
beside you.

**Why it presents as a flake rather than as a bug.** Under `--filter` your suite is very nearly the
only writer, 1000 is effectively unbounded, and the window never rolls. In a full-suite run the rest
of the package logs past your line *while your own fixture is still working* — awaiting an
operation to drain, walking a fixture tree, waiting on a quiescence poll. Same source, opposite
verdicts, decided by what else was scheduled: step 4 of the triage above ("do not stop at
`--filter`") exists for mechanisms like this one.

**The two directions cost differently, and that asymmetry is the point.** A rolled window turns a
presence assertion into a false **failure** — noisy, visible, someone bisects for a day. It turns an
absence assertion into a false **pass** — silent, and permanent, because nothing will ever draw
attention to it again.

**It is not the only mechanism here that can do that, and an earlier draft of this section claimed
it was.** Mechanism 2 makes an absence vacuous with a fixed sleep before it; mechanism 8 does it with
a bound whose expiry is discarded; mechanism 9 does it with an absence that has no paired control
proving the signal could have arrived. All four delete coverage in silence, and a reader taught that
only this one can will not go looking for the other three. What *is* particular to this one is where
the trigger lives: the other three are visible in the test's own source, while this one fires on the
volume of unrelated suites, so the same test is honest or vacuous depending on what else was
scheduled beside it.

**Where this line stands, counted 2026-08-16.** Ten files on `v3.x` name `Logger.shared.entries`,
and every one of them is a test:

```sh
grep -rl "Logger.shared.entries" Modules SyncCloudTests MacApp   # 10, every one a test file
grep -rl "flush marker" Modules SyncCloudTests MacApp            # 6 of them, the flush-only idiom
```

**One of the ten carries the exposed shape** — an *absence* assertion over the whole buffer with no
marker guard, which is the half that cannot report its own failure:

- `Modules/Sync/Tests/Sync/UndoRedoLogLabelTests.swift:40` —
  `#expect(!(await loggerContains("User triggered Redo: Delete 1 Items")))`, pinning that no redo has
  claimed the label yet. Its helper at `:16-19` writes a `label-pin flush marker` **after** the call
  and never asserts it survived, then searches the whole buffer. The four siblings in the same test
  (`:37`, `:38`, `:45`, `:46`) are presence assertions, so a roll would fail *those* loudly while
  `:40` passed for free — the asymmetry visible inside one test.

One is the whole exposed surface on this line, and that is a smaller number than it looks. `v2.x`
carries the same mechanism with four such assertions, three of them in a
`FilingScanAbandonmentLogTests` that does not exist here; a suite of that shape is one backport or
one new feature away, and the rules below are what it should be written against on arrival.

The rest read presence over the whole buffer, where a roll costs a loud false failure rather than
silence: `CopyMoveBehaviorPinTests` (ten, `:56`–`:254`, helper `:21-24`), `RedoFailureReportingTests`
(`:86`, `:128`, `:205`, `:253`, helper `:21-24`), `BulkFailureAggregationTests` (`:85`, `:100`,
helper `:107-110`), `CopyUndoDriftAndTransientTests` (`:389`, `:412`, inline), and
`FileSyncManagerFilingTests:454` — a `.filter{}.count` differenced against a baseline taken earlier
in the same test, so eviction between the two reads makes the count go *down* and it fails rather
than passing.

Two more are worth telling apart from the rest before you read them as exposed:

- `AnthropicKeychainTests:161` and `:271`, and `IgnoredItemsStoreTests:86`, poll for their line
  inside a `waitUntil` immediately after the call that writes it. That is rule 3 below, by
  construction, and their windows have almost no time to move. A roll makes them spend their whole
  ceiling and then fail, so read the timing (triage step 1) before blaming the code that writes the
  line.
- `Modules/FileExplorer/Tests/FileExplorer/ColumnPreviewRevealTests.swift:1345-1347` bounds its
  window by *time* (`$0.timestamp >= since`). That stops an older foreign line matching, but it does
  nothing about eviction: **a timestamp filter is not a survival guard**, because an evicted line and
  a line never written are both simply absent from what you filter.

**Fix.** Four rules. The first two are the whole of it; the second two are what make them hold.

1. **An absence assertion needs BOTH guards: your own marker FIRST, required to have survived, AND
   an awaited flush LAST.** The marker goes in *before* the call under test and the assertion reads
   only from it onward, so a window that rolled past your own opening marker fires the guard and
   says the reading was vacuous instead of passing. That closes **eviction** — and it says nothing
   about **visibility**, which is the other way this assertion reads an empty interval.
   `Logger.log(level:message:)` is `nonisolated`: it hands the entry to a FIFO queue drained by a
   `@MainActor` flush task (`Modules/Events/Sources/Events/Logger.swift`, `log(level:message:)` and
   `flushPendingEntries()`). On a `@MainActor` test that does not suspend between the call under
   test and the read, that flush has not run, and the line is simply not in `entries` yet. Close it
   by awaiting one more entry's task before reading — `await Logger.shared.debug("… flush
   marker").value` — which, the queue being FIFO, drains everything enqueued before it.

   **Measured 2026-08-17, as a pair, because this rule used to say only the first half.** A
   `@MainActor` probe applying the marker and the guard but no trailing flush **passed** an absence
   for a line its own call under test had just written. The identical probe with one awaited flush
   added **failed**, correctly seeing the line. A third — flush present, and 1100 filler lines
   rolling the window between the marker and the read — failed on the survival guard instead. The
   two guards are independent and both are load-bearing: the flush cannot see eviction, and the
   marker cannot see the queue. Every implementation on this line already had the flush; it was the
   advice that had dropped it.
2. **For a presence assertion, read strictly BETWEEN two of your own markers** — open, act, close —
   rather than over the buffer. This does three jobs at once: the opening marker is the eviction
   guard as above, the *awaited* closing marker is rule 1's flush (which is why this shape has never
   shown the visibility bug — it supplies the drain as a side effect of bounding the top, and that
   is worth knowing deliberately rather than relying on by accident), and the bounded slice stops a
   *foreign* line with the same text satisfying your assertion, which a whole-buffer `contains`
   cannot distinguish from your own. Where a closing marker is impractical, the substitute is a
   fixture string no other suite can write — a per-test temp-root name or a UUID — and it should be
   stated in the suite's doc comment, not assumed; note that dropping the closing marker also drops
   the flush, so an absence half then needs one of its own.
3. **Read as soon as the decision is taken, not after the work completes.** Most of these lines are
   written synchronously at the top of an operation, long before it finishes; awaiting the whole
   operation just hands the rest of the package more time to roll your line away. Wait on the
   decision's own observable instead of on the drain.
4. **`.serialized` when a sibling in the same suite writes the same line.** The bounded slice keeps
   out lines from *before* and *after*, not lines a concurrent sibling drops *inside* it. (The
   cross-*suite* half is mechanism 3's known residual, and is closed here only by rule 2's unique
   fragment — grep the package before trusting one.)

**The model to copy is already on this line.** `plantLogMarker(_:)` and `logLines(since:)` in
`Modules/Sync/Tests/Sync/UndoDriftIdentityTests.swift` are rule 1 implemented, and their doc
comments state this mechanism in as many words. (Cited by **symbol**, deliberately: the line range
this used to name was correct when written and silently wrong two commits later, which is a bad
trade for a file whose whole value is being checkable. Prefer a symbol plus a file when you add a
citation here — `grep -n` costs the reader nothing and does not rot.)

`plantLogMarker(_:)` writes `undo-drift-marker <label> <UUID>` **before** the operation.
`logLines(since:)` then writes its own awaited CLOSING marker — which is rule 1's flush — resolves
that marker's index *first*, searches for the opening marker only within `entries[..<end]`, and
returns the slice strictly between the two. When the opening marker is gone it records *"the log
window rolled past this test's own marker — the 1000-entry cap evicted it, so nothing can be
concluded about the refusal line"* instead of returning a window. Ten tests in that suite use it.

It implements **both** halves of rule 2: `logLines(since:)` writes its own CLOSING marker, resolves
that index first, then searches for the opening marker only within `entries[..<end]`, and slices
strictly between the two.

**It was open-ended until 2026-08-17 — and closing it is NOT what fixed the coverage it was losing.**
The window ran `entries[start...]` to the end of the buffer, on the stated ground that every
assertion in the suite matches a string unique to its own fixture. That was not true of it:
`undoOfANestedNormalizePass…` and `undoAfterARedoOfANestedNormalizePass…` assert the
**byte-identical** line `Undo (Normalize 2 Names): moved 2 of 2 item(s) back to source, 0 restore
failure(s), 0 left in place`, both are `@MainActor` but both suspend at `waitUntil`, so they
interleave. CI runs this target **without** `--no-parallel` (`.github/workflows/tests.yml`), so
parallel is the configuration that ships.

**Measured, and the result is the lesson: rule 2 alone did not close it, rule 4 did.** Remove the
second test's own undo so it writes no line at all, and delay the sibling so its identical line lands
inside the second test's window: the presence assertion PASSED, satisfied by a line its own code
never wrote — and it passed *just the same* with the window bounded strictly between its own markers,
because the sibling's line is INSIDE the window, not after it. Bounding keeps out lines from before
and after; nothing but serialization keeps out a concurrent sibling writing into the middle. With
`@Suite(.serialized)` the same mutation fails immediately (3 issues → 4). **So do not read rule 2 as
covering rule 4's job.** The bound is still worth its one line — it removes the tail between the
flush and the read — but a unique-fragment substitute, and now the bound too, is only as good as a
grep of the whole package proves it to be. Run one; if a sibling can write your line, serialize.

Two more things to know if you copy it. Searching for `start` inside `entries[..<end]` is what makes
the bounds unreversible by construction — see the trap warning below. And it records an `Issue`
rather than requiring, so the test continues against the `[]` it returns.

**What makes that safe is the `Issue.record`, and nothing else.** An earlier draft here said it was
safe "because it then returns `[]` and the real assertions fail too" — which is exactly backwards
for the half that matters. Five of this suite's absence assertions have the shape
`lines.allSatisfy { !$0.contains(…) }`, and `allSatisfy` over an empty array is vacuously **true**
(measured: `([] as [String]).allSatisfy { _ in false }` is `true`). On a fired guard every one of
them passes. The recorded `Issue` is the whole reason a rolled window is not a silent pass here. So
if you copy this helper, copy the `Issue.record` with it — a variant that merely `return []`s on a
missing marker turns those five absence assertions into five vacuous passes at a stroke. Better
still, prefer a `#require` in a fresh one, so the vacuous reading stops the test rather than merely
annotating it.

**Resolve the index before you slice, and never slice inside `#expect`.** `entries[a...b]` on
reversed bounds *traps* rather than failing, and a trap inside an expectation takes the whole test
host down with it — a rolled buffer would then report as infrastructure and lose the rest of the
run's verdicts. `logLines` above gets this right: it resolves `start` and `guard let`s it before
indexing anything.

**A flush marker is NOT an eviction guard — so add the marker, do not drop the flush.** Six of the
ten files here only flush, and the fix for them is to gain a survival guard, not to trade one guard
for another: the flush is what makes the line *visible* at all (rule 1's second half), and a
"modernised" test that replaced its flush with an opening marker would go back to reading an
interval its own line has not reached yet. The common idiom —

```swift
await Logger.shared.debug("some-test flush marker").value
return Logger.shared.entries.contains { … }
```

— is doing something real and necessary: the queue is FIFO, so awaiting a fresh entry's task
guarantees everything enqueued before it is *visible* in `entries` (see `log(level:message:)` and
`flushPendingEntries()` in `Modules/Events/Sources/Events/Logger.swift`). But visibility is not
survival. The marker is written **after** the call under test and its presence is never asserted, so
it proves your line has arrived while saying nothing about whether it has already been pushed out.
Recount rather than trusting the ratio above — it is meant to move.

None of the six has been observed to roll on this line, and they are not wrong today. The five that
assert only presence will tell you when it happens, loudly. `UndoRedoLogLabelTests` will not — not
for its one absence half.

**This mechanism has a different number on each line, so cite it by name.** It is **10** here, 11 on
`v2.x`, and 12 on `main`, because the three registers accumulated different entries before it. Write
"the rolled log window" — a bare number goes stale the moment a text is cherry-picked between lines,
and one commit on `v2.x` already refers to that line's entry by `main`'s number.

**This line's register is missing an entry `v2.x` has, and the number above is why it matters.**
`v2.x` carries a mechanism 10, *"Every gate parks at once, on the pool their releases need"* —
`ParkGate.park()` blocking real threads on a `DispatchSemaphore` until the pool starves. That entry
was never brought forward, which is the only reason the rolled log window took the number 10 here.
It is a genuine gap and not an inapplicable one: `ParkGate` is used by six test files on this line
(`grep -rl ParkGate Modules`), so the mechanism can fire here exactly as it does on `v2.x`. **When
someone does backport it, it cannot simply keep its `v2.x` number** — 10 is taken on this line.
Renumber it, or better, land it under its name and leave the numbers to fall where they may. Until
then this gap was recorded only in the message of `cfaa320a`, where nobody reading the register
would find it.

#### The uncapped on-disk log — a better substrate, and why it is not a free win

**Measured on `main`, 2026-08-22, and it applies here unchanged because the parts it rests on are
the same on this line.**

Everything above operates inside `entries`, so every remedy it offers is shaped by that array's
1000-line cap. The log has a second copy with no cap: `Logger.shared.logFileURL`. Two properties
make it the better substrate for these assertions, and neither is obvious — the append happens **at
the call site**, synchronously inside the `nonisolated log(level:message:)` and *before* the flush
task is returned (`logWriter.append(entry.formattedString + "\n")`), so the file preserves call
order and needs no flush marker to become visible; and the 1000-line trim lives in
`flushPendingEntries()` and touches `entries` alone, so the file never rolls. Under a test runner it
is a per-process temp file (`sync-cloud-tests-<pid>.log`, see `defaultLogFileURL()`), so it is
scoped to the run and does not touch `~/sync-cloud.log`. All three of those are true on this line —
checked, not assumed.

**But moving to it makes the shared-fragment collision worse, not better.** The haystack stops being
the last 1000 lines and becomes the entire run. Switching substrate closes eviction and *widens*
rule 4.

**And windowing does not close it either, because a window bounds time, not authorship.** Bound the
assertion strictly between its own markers and a *foreign suite's* line still lands inside the
window and wins a `last {}`. Rule 4 prescribes `.serialized` for the same-suite case and otherwise
sends you to "pick a fragment no other suite writes" — sound advice that does not always have a move
available, because **the production code decides the wording, not the test**. On `main` the sentence
that forced this is written by seven call sites in `FileSyncManager+Duplicates.swift`; there was no
unique fragment to pick.

**So: filter by authorship.** Those refusals each name a path, and a fixture root is a per-test UUID
temp directory, so the fixture's own root is a witness that the line is *yours*:

```swift
let line = mine.last { $0.contains("<the shared sentence>") && $0.contains(base.path) }
```

Check the filter is not circular before using it — on `main` it is not, because the assertions read
the refusal's *wording* and the copy's *name*, never the root itself.

**Audit the fragments rather than assuming.** Grepping every `loggedLine(containing:)` fragment in
the package against the sources is the cheap step, and it is what tells you whether you need the
authorship filter at all; on `main` exactly one fragment was over-shared.

**Verify a log fix in parallel.** `--no-parallel` cannot see any of this, and CI runs the package
target parallel. A serial-only green is what let a red landing go out on `main`.

**The reference implementation is `logLines(tag:during:)` in
`Modules/Sync/Tests/Sync/TestSupport.swift` on `main`, and it is not on this line** — this line's
`TestSupport.swift` has no on-disk reader. Nothing here is owed a port on its own; the entry is
carried so that a session on this line reaching for the disk log finds the trap already written
down rather than paying for it again.

**See.** `flushPendingEntries()` in `Modules/Events/Sources/Events/Logger.swift` for the cap and
`entries` for the shared array; mechanism 3 for the parallel-suites premise this rests on, and for
the foreign-line half — which rule 2 closes only *before and after* the window, never inside it;
see the subsection just above. First measured on `main`, in `f87d9e11` — *Account for a rollback
and a widening the log could not explain* — where a presence assertion reported a missing line,
twice in parallel runs, for a line that had been written. That commit is not on this line and
neither is the test it cost, but the cap and the parallel suites are, and `UndoDriftIdentityTests`
reached the same conclusion here independently.

### 11. The build failed before any test ran

**This is the one entry here that is not a flake**, and it is in the file because at a glance
nothing distinguishes it from one. Every other mechanism is a test that failed for a reason outside
the code under test. This is a build that never produced a test at all — and it reports itself with
exit 65 and `** TEST FAILED **`, the same as a red suite.

**Symptom.** The app-target step (`App-target tests (xcodegen + xcodebuild)`) fails; all seven
package suites pass in the same run. The step's output contains no test names, no failures, and no
summary:

```
error: Could not compute dependency graph: unable to load transferred PIF:
PIFLoader: GUID 'PRODUCTREF-PACKAGE-PRODUCT:IssueReporting-2041EB56849B4D1-dynamic'
has already been registered
Testing cancelled because the build failed.
** TEST FAILED **
```

**The tell is an absence: no `Test run with N tests` line.** A regression names a test. A flake
names a test. This names none, because there were none to name. It is the first thing to check on
any red, and it costs one command:

```bash
gh run view <run-id> --log | grep 'Test run with' || echo 'NO TEST-COUNT LINE — nothing ran'
```

Use that form rather than `grep -c`, which **exits 1 when the count is zero** and will read as a
failed command instead of an answer.

**Mechanism** (2026-08-20). The four module manifests that need a snapshot-testing net declared it
floating — `.package(url: ".../swift-snapshot-testing", from: "1.18.0")` — and SnapshotTesting
floats every one of its own dependencies in turn:

```
Modules/{Dashboard,Design,FileExplorer,Settings}
  → swift-snapshot-testing   from: "1.18.0"
    → swift-custom-dump      from: "1.3.3"
      → xctest-dynamic-overlay  from: "1.2.2"
```

The SPM side of that was pinned by committing `Modules/*/Package.resolved`. **The Xcode workspace
keeps a second, separate resolution** at
`SyncCloud.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and
`SyncCloud.xcodeproj/` is gitignored (`.gitignore:45`) — so that pin never covered it, and it
re-resolved freely. The app-target build loads the four local packages *and* the workspace's own
resolution. On 2026-08-20 they disagreed:

| package | `Modules/*/Package.resolved` (tracked) | workspace resolution (gitignored) |
|---|---|---|
| swift-snapshot-testing | 1.19.4 | 1.19.4 |
| swift-custom-dump | 1.6.1 | 1.7.0 |
| xctest-dynamic-overlay | 1.11.0 | **1.12.0** |
| swift-issue-reporting | absent | **2.1.0** |

`xctest-dynamic-overlay` 1.12.0 moved the `IssueReporting` product out into the separately-named
repo `swift-issue-reporting`. The drifted workspace took **both** packages, and both vend a product
called `IssueReporting`. Two packages, one product GUID, PIF load fails — before a single file is
compiled.

**Three things made this expensive to diagnose, and each is worth knowing on its own.**

- **`gh run rerun --failed` does not clear it.** The stale resolution lives in the runner's
  checkout, not in the run. Re-running replays it.
- **A local `xcodebuild test` passed throughout.** The primary checkout's workspace resolution was
  dated 16 July and had simply never re-resolved — it still held snapshot-testing 1.19.3, older than
  the tracked pin. **A local green here proves your workspace file is old, and nothing else.** Any
  checkout that re-resolves, including a brand-new worktree, is exposed.
- **The upstream tag was withdrawn while this was being investigated.** `git ls-remote` on
  `xctest-dynamic-overlay` came back with a maximum tag of **1.11.0** — no 1.12.0 anywhere — while
  the runner's package cache still held it, with the revision recorded for "1.12.0" being that
  repo's current `HEAD`. So the failure could not be reproduced from the network at all, only from
  that cache; and once CI wiped `.dd`, not even from there. **A red that stops reproducing has not
  necessarily been fixed.** An upstream tag being pulled cures the symptom and leaves the cause — a
  floating requirement — exactly where it was.

**The fix.** Every external package is pinned `exact:` in all four manifests, transitives named
explicitly so that they are pinned too. Two things about that shape are load-bearing:

- **A root-level requirement is the only thing that constrains a transitive.** `exact:` on
  swift-snapshot-testing alone leaves custom-dump and the overlay free to move, which is what
  floated in the first place. The transitives are declared even though no target uses them; that is
  the whole point of declaring them.
- **`Modules/*/Package.resolved` is not a substitute, because the Xcode workspace does not read
  it.** Pinning in the manifest constrains both resolutions, since both start from these manifests.

Bump the four together, and re-run the app target — not just the package suites — after any change
to them. `SyncCloudCLI` was pinned in the same pass, though it is a different case: it is not in
`project.yml`, so it has only one resolution and its lockfile was already authoritative. Nothing in
the graph floats now, which is the invariant worth keeping — the second resolver is what made this
one expensive, not what made it possible.

**If it recurs, clear the runner's stale state; it is not in the run.**

```bash
R=~/actions-runner-synccloud-x64/_work/sync-cloud/sync-cloud
rm -rf "$R/SyncCloud.xcodeproj" "$R/.dd"
```

Then confirm the app-target step reports a real `Test run with N tests` line, rather than trusting
the green tick.

---

## When you fix one

**Mutation-test it.** Re-introduce the defect and confirm the test fails on the exact value you
expect. A test written against a flake is especially prone to passing for the wrong reason: on
2026-08-01 a cancellation test passed under mutation because it exercised an opt-out path and never
reached the cancellation it claimed to cover. Re-run the mutation *after* writing the test, not
before.

If the invariant is only reachable through a race, make the trigger injectable rather than trying
to stage the race. A guarded rename is worth a seam.

**Do not race a concurrent session.** Check `git worktree list` and recent commits touching the
file first. Two sessions rewriting one test harness is worse than the flake.
