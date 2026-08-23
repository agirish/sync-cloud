# Flaky tests

Tests here have failed for reasons that had nothing to do with the code under test — and each
time, the failure looked exactly like a real defect. `ColumnPreviewRevealTests` reported "the
deepest column is hidden behind the preview: column 420…630, visible 0…270", which is the precise
geometry of the bug it exists to catch. Nothing about that message says *the machine decided this*.

This file is the **evidence appendix**. It records the mechanisms that have actually produced false
failures in this repo — and the ones that produce no failure at all, which are the more expensive
half — with the measurements behind each and the fix pattern for each.

**If you are staring at a red suite right now, start at
[flaky-triage.md](flaky-triage.md)**, not here: it is one page, it tells the mechanisms apart, and
it links back to each section below. Come here once you know which one you have — or when you are
about to write an assertion that something did *not* happen, in which case read mechanism 12 and the
three beside it in [the silent half](flaky-triage.md#the-silent-half--read-before-writing-any-absence-assertion).

**Mechanism 13 is not a flake**, and is filed here anyway because this is where you will look: it
is a *build* failure that reports itself as exit 65 and `** TEST FAILED **`, exactly like a red
suite. Its tell is an absence — no `Test run with N tests` line.

See [ci.md](ci.md) for what CI runs and the runner's own quirks.

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

**Fixed here too, 2026-08-08 — `PaneColumnsOverscrollReturnCycleTests`.** Three failures in one
afternoon: twice in loaded local runs and once **in CI**, where it took the whole line red. The tell
each time was the *duration* — **22.8–25.6 s to give up against 1.4 s isolated**, i.e. it burned its
entire wait rather than settling on a wrong value, which is starvation and not a bad answer.

The pull home is an `NSAnimationContext` group with `allowsImplicitAnimation`, so it is this
mechanism exactly, reached through AppKit rather than through `withAnimation`. A grep for the
SwiftUI shape does not surface it, which is why it sat under mechanism 2's *unconditional pumps*
list looking harmless. **Match on the hazard — an animation deciding a test's verdict — not on the
API that starts it.**

Fixed the way this section prescribes: `WatchdogView.pullDuration` is injectable beside the
`axisLock` seam already there, all seven test mounts set it to **0**, and 0 means *no animation
group at all* rather than a fast one — a zero-duration group still defers through CoreAnimation and
starves identically. `thePullHomeShipsAnimated` pins the 0.25 s default, because once every mount
injects zero nothing reads what the app ships; both halves were mutation-checked.

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

**A pump that never pumps — `RunLoop.main.run(until:)` with no window in the process, 2026-08-21.**
`MergeUndoGroupingAndGateTests` and `DuplicateBatchRedesignTests` each carried a
`closeTheUndoEventGroup()` helper — `RunLoop.main.run(until: Date().addingTimeInterval(0.02))` —
whose stated job was to turn the runloop so NSUndoManager's event-scoped group closes before the
next registration. Measured in the Sync test process: **the call returns in ~2 µs and
`groupingLevel` still reads 1 on the very next line.** So it was not merely a fixed sleep of the
wrong length; it was not a sleep at all, and it closed nothing. What actually closes the group in
those tests is the next ordinary `await` — one 10 ms `Task.sleep` takes the level from 1 to 0,
because handing the main thread back lets the main queue be serviced. The separation both suites
depended on was being supplied by whichever suspension happened to follow the helper.

**The mechanism is WINDOW PRESENCE, not `swift test`,** and an earlier revision of this paragraph
said the latter. `run(until:)` returns as soon as the main runloop has no input source attached to
it; a mounted `NSWindow` attaches one, and nothing else in these processes does. Same call, three
readings each. The Sync row is this entry's original measurement; the two FileExplorer rows are
what re-measuring it in a target that DOES mount windows produced, 2026-08-21:

| Where | Elapsed for a 0.02s deadline |
|---|---|
| Sync target, no window | 1.79e-4 s, 1.63e-6 s, 4.2e-7 s |
| FileExplorer target, no window | 2.1e-4 s, 2.0e-6 s, 0.0 s |
| **FileExplorer target, ONE `NSWindow` mounted** | **0.0247 s, 0.0227 s, 0.0220 s** |

Forty spins with a window cost 0.998 s — it really blocks. So the generalisation condemned code
that is fine: `PaneTreeCarryBackWiringTests:88,152,159,228,234,236`,
`PaneColumnCarryOverRenderTests:131,134` and `CountPillResetObservationTests:105` all spin
`run(until:)` in suites that mount windows (3, 1 and 1 `NSWindow(` respectively), and they pump.

**The converse is a real cross-suite hazard, and it is the one to carry away.** Whether such a
loop pumps depends on whether ANY window is mounted in the process when it runs — not on whether
the suite that wrote it mounts one, because Swift Testing interleaves suites on the same main
actor. Measured in one serialized run: the *identical* windowless call read ~2 µs when it ran
alone, and 0.023–0.028 s when an earlier test in the same run had left a window open — the coupling
demonstrated in the harmless direction. It runs the other way for free: a suite that mounts a
window and then CLOSES it turns a neighbour's `run(until:)` from a real pump into a no-op, with no
failure anywhere, because a loop that waits for a duration cannot report that it waited for
nothing. That is the same lesson as the helper above, one step out: **a wait that must
pump has to assert what it was pumping for.** This is the same family as "Process-wide state, and
suites running in parallel" and as "Text-field focus is arbitrated process-wide, so any suite can
evict another's field editor" — one more thing a suite can silently take away from a neighbour.

Replaced by a shared `closeTheUndoEventGroup(_:)` in `TestSupport.swift` that polls
`groupingLevel` and **fails, naming the level and the poll count**, if it never reaches zero. The
general lesson is the one this section already makes, one step earlier: a helper that waits for a
duration cannot report that it waited for nothing. Only a helper that asserts its condition can.

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

**Live instance, 2026-08-08 — five seconds bought four polls.**
`ShortcutRevealTrackerTests.holdingOptionAlonePublishesTheReveal` (Modules/Design) failed on CI run
`31263358127`, `main` at `5bdb9b36`, and the identical SHA passed on re-run. Its suite-local
`waitUntil` was the plain wall-clock form: `while ContinuousClock.now < deadline`, five seconds, a
5 ms sleep per turn, no floor.

**The poll count is what settles the diagnosis, and it is worth instrumenting before choosing a
fix.** The wait looked merely slow — 1.85s idle for a 0.2s hold, 3.6–4.4s under the CPU-spin recipe
above — which reads as "the machine is busy, raise the timeout". Counting the polls says otherwise:
**34 polls in 0.207s** under `--filter`, and **4 polls in 4.44s** in a full Design run. The hold had
elapsed many times over; the loop was short of *turns to notice it*, and a bigger number of seconds
buys those at the same terrible rate. Note also that it is the run's **first** wait that starves —
later ones in the same run came back in 3–5 polls — so a suite whose slow wait sits early is the
one that fails.

Fixed with `pollFloor = 50` on the suite's own helper, the same number and reason as
`LayoutPumpWait.pumpFloor`, and the count now goes in the failure message. Mutation-tested both
ways: with the deadline set to **zero** the whole suite still passes, so the floor alone carries it;
with `ShortcutRevealTracker.publish()` made a no-op the wait fails naming **803 polls**, which is
what "genuinely disproved" looks like next to the starved 4.

**The inventory above was built by a layout-shaped grep, and is blind to this whole family.** It
filters `while Date() < deadline` on a following `layoutIfNeeded`, so it cannot see a condition wait
that pumps nothing, and matching on `Date()` misses `ContinuousClock` outright — this one was
invisible to it twice over. Sweep for the *bound*, using the canonical recipe below.

Sweeping for the bound is what surfaced the widest case here — the shared `waitUntil` in
**`Modules/Sync/Tests/Sync/TestSupport.swift`** and its twin in **`SyncCloudTests/TestSupport.swift`**:
every Sync and app-target suite waits through them, including the `testCreateFolder` fix
recorded above, which replaced a flat sleep with exactly this helper. Both are floored as of the
entry below.

**Both copies floored, 2026-08-08.** They were `while ContinuousClock.now < deadline`, five seconds,
a 10 ms sleep, no floor. ~150 call sites, none of which passes an explicit `timeout:`, so the
default was the whole budget and a floor could not collide with a deliberately short one.

**Reproduced here before porting the fix, rather than assumed from the suite next door.** Poll
counts logged across a full Sync run: most waits return on the *first* poll, and the tail is where
the shape shows — 4 polls in 0.523s idle, and under the CPU-spin recipe above a worst rate of
**223 ms per poll** against a nominal 10 ms. Five seconds buys ~500 evaluations at the nominal rate
and ~22 at that one. No Sync wait has been *seen* to fail; the margin is what was gone.

`waitPollFloor = 50` on both copies, and the poll count now goes in the failure message. Mutation:
with the deadline set to **zero**, all 1167 Sync tests still pass — the floor alone carries all 135
waits a full run makes.

**The floor is tested this time** (`WaitUntilFloorTests`), rather than left as the untested constant
`pumpFloor` was. Same shape as the v3 line's pass-floor tests for `LayoutPumpWait`, and it
reproduces their two results exactly: `waitPollFloor = 0` fails the floor test twice (the helper's own labeled expiry at 0 polls,
then the count at 1 against 25), while `waitPollFloor = 24` — one under the demand — fails **only**
the premise guard, because the post-deadline re-check buys a 25th evaluation. The real guarantee is
`waitPollFloor + 1`. Note what cannot be tested here: `waitUntil` reports expiry by *recording a
failure* rather than returning a Bool, so there is no passing test for the never-holds case; that
half was checked by hand.

**The canonical sweep keys on the BOUND, not on the body.** A floored loop reads
`while <n> < <…>Floor || <clock> < deadline`, so excluding `Floor` leaves exactly the unfloored
ones, whatever they poll — which is why this recipe supersedes both narrower ones above:

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

Run on this line 2026-08-18: **35 unfloored clock-bounded loops**, against 4 floored ones correctly
excluded. Most of the 35 are fixed pumps with no condition to starve — the separate problem this
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

**`poll` is invisible to the sweep above, deliberately and with a cost.** It reads an injected
`now()` rather than `Date()`, so the pattern matches neither its floored form nor an unfloored one
— which means the sweep would NOT catch someone deleting its floor. That guard moved to
`LayoutPumpWaitPollTests` instead, where `pumpFloor = 0` fails two assertions. Any future wait that
takes a clock has to carry its own floor test for the same reason; the grep cannot see it.

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

**Both numbers and both lists are per-line, like this file's SHA refs.** `v2.x` reads 42 and 3, and
its residual is eight, because the four view-based settles migrated on `main` on 2026-08-04 are
still unmigrated there — and its floored count is lower because it has neither the Dashboard copy of
`LayoutPumpWait` nor the view-based `pump` entry point `main` added to the FileExplorer one, only
the window-based original. It does now carry `poll` and `LayoutPumpWaitPollTests`, which is where
this fix landed first. Re-run the sweep on the line you are on; do not cherry-pick the count.

**A bound whose expiry is discarded says nothing when it expires, 2026-08-22.**
`waitUntil` in `Modules/Dashboard/Tests/Dashboard/FileActionHandlerOperationTests.swift` polls up
to 200 × 20ms and then **returns normally**. Nothing reads the outcome, so when the budget runs out
the test simply carries on and asserts against state that never arrived:

```swift
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
}
```

`testCopyItemsFromLeftCopiesToRightPane` failed on the two lines *after* that wait — the banner's
message `nil` against `Copied "copy-me.txt" to RightSide`, and `isUndoable` `nil` against `true` —
19.7 seconds in. **Neither message mentions waiting**, so the run reads as "the banner is wrong"
when what happened is "the banner had not been published yet". That is this mechanism wearing the
face of a behavioural defect, which is the reason it is filed rather than retuned.

**The tell is both assertions failing with `nil` on the left.** State that arrives *wrong* fails one
assertion with a value in it; state that has not arrived at all fails every assertion about the same
object, all of them nil. A void-returning wait cannot tell you which, and that is what to fix — the
expiry has to be a failure carrying its own message, not a `return`.

Environmental, and measured both ways: it failed in run `32595371148` on the self-hosted runner —
**which is this Mac**, the same fact "Load-scaled benchmarks" records — while a full Dashboard
package run was executing locally beside it at load average 16. The same 490-test suite is green
locally in 46.3s and green on CI in run `32597536957` in 41.3s.

**Two more things in the same file, both the shape this mechanism warns about.**
`for _ in 0..<200 where !condition()` does not exit early: `where` skips the *iteration*, so the
condition is evaluated 200 times and only the sleep is skipped once it holds. Harmless today, but it
reads like a break-on-success loop and is not one, so anyone tuning the budget down is shortening a
wait they believe already returns. And `waitForOperationsToFinish` returns as soon as
`activeFileOperationsCount == 0` — **including before the operation has started**, which is
"quiescence cannot tell finished from not started" verbatim. Here it is covered by the `waitUntil`
on the file landing that runs before it; on its own it is not a wait at all.

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

#### Seen: `ScanSupersedenceTests.testCancellingScanAbortsTheDiskWalkPromptly`, 2026-08-11

A full `Modules/Sync` run went red on **two** tests at once, immediately after a full
`Modules/FileExplorer` run on the same machine. Both tests exist on both release lines and nothing
about the mechanism is line-specific, so this entry is identical on each:

- `ScanSupersedenceTests.testCancellingScanAbortsTheDiskWalkPromptly` —
  `Date().timeIntervalSince(cancelledAt) → 9.985 < 2.0`. A **2-second** budget missed by **5×**.
- `FileSyncManagerFilingTests.staleTryAnotherDeferMustNotReleaseTheNewRoundTripsGuard` —
  its park timed out.

Both passed on re-run with `--filter`, and the **whole package then passed on a quiet machine in
11.8 s** — against a first run slow enough for a 2 s deadline to overrun by eight. That spread is
the diagnosis: same suite, same binary, an order of magnitude apart in wall clock.

Two things worth carrying forward. **A 5× miss reads like a hang, not a flake** — the instinct is
that something is genuinely deadlocked, and 9.98 s against 2 s is far easier to believe as a real
regression than mechanism 6's 2.4% miss. It is not; the budget is simply absolute. And **two
unrelated tests failing in one run is evidence for the environment, not against it** — a change
that broke scan cancellation has no path to a filing-defer park, so a common cause outside both is
the cheaper hypothesis. Check the machine before the diff.

The change under test that day touched only a new `@Published` flag neither suite reads, which is
what made the environmental read easy to confirm. When it is not that clear, interleave the arms as
mechanism 6 describes.

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

**Second failure, 2026-08-14 — interleaving was necessary but not sufficient.** The same test
failed the v4.0 cut commit at `speedup → 1.7669 > 1.8`, on a commit that changes two version
strings, a generated plist and a markdown file — nothing this benchmark can reach, and the
benchmark file itself unchanged since `7afac3a4`. The arms are interleaved now, as the entry above
prescribes, and it failed anyway. Runs of the identical benchmark — `a76f45b9` and `b012c1c7` are
adjacent on `main`; `869be3ca` is `a76f45b9`'s `v2.x` twin, the same change measured on the other
line, not a third commit:

| commit | searched | computed | speedup |
|---|---|---|---|
| `a76f45b9` pass (`main`) | 22.32ms | 9.17ms | 2.44x |
| `869be3ca` pass (its `v2.x` twin) | 20.11ms | 7.85ms | 2.56x |
| `b012c1c7` fail | 27.11ms | 15.34ms | **1.77x** |
| `b012c1c7` rerun | 38.63ms | 13.90ms | 2.78x |

**Both arms picked up nearly the same *absolute* time, not the same proportion** — +4.8ms and
+6.2ms. That is the signature of an additive term, and interleaving does not remove one: it cancels
load that *drifts between* the arms, while a steady overhead present during both survives. An
additive `d` collapses a ratio whenever the arms differ in magnitude, because `(a+d)/(b+d) < a/b`,
and here the computed arm is a third the size of the searched one — so the same milliseconds cost
it proportionally far more. The rerun makes the point from the other side: `searched` was the
slowest of all four at 38.63ms and the ratio still passed comfortably, because that run's inflation
was multiplicative rather than additive.

Note the probe median was **~7.3ms on all three of the original runs, failing and passing alike**,
and the sibling columns benchmark reported `slowdown=1.00x` during the failure. The probe did not
see this. Do not read a healthy probe as evidence the machine was quiet. (The failing run's probe is
quoted as 7.3ms here and 7.4ms at the end of this entry — the same reading rounded from different
places, not two measurements.)

**If it fires a third time, fix it rather than documenting it again** — this entry has now been
written twice. Two fixes were proposed at this point: subtract the probe baseline from each arm
before taking the ratio, or assert on the absolute difference between the arms.
**The second was taken and the first is now withdrawn** — read on before acting on it. Subtracting a
probe baseline cannot work when the probe does not reliably rise with the load (see the end of this
entry), and the section closes by advising against a CPU probe as a load signal for anything that
renders; leaving the suggestion here unmarked is how it would get built anyway.

**Third failure the same day, and now FIXED — the test asserts the saving, not the ratio.** It fired
again ~40 minutes later at `1.7239` on `2e2ec8f2`, another commit that cannot reach this code. Per
the line above, that made it a fix rather than a third write-up. Two corrections to what is written
above, both found by measuring instead of reasoning:

- **"the absolute difference stayed stable" was too strong.** The savings were 12.26, 13.15, 11.77
  and **24.73** — the rerun is a 2x outlier, because its `searched` arm was inflated to 38.63ms. The
  accurate claim is narrower and is the one the fix rests on: **the saving never approaches zero, and
  the failing runs' savings (11.77ms, 11.15ms) sit inside the passing runs' range.** The ratio is
  what separates pass from fail; the saving does not, which is exactly why it is the better bar.
- **The bar never had the headroom its comment claimed** ("set well under the measured speedup"). An
  idle, isolated, single-suite run measured **2.02** — 0.22 above a 1.8 bar under the best conditions
  this machine offers. Three flakes were not bad luck; the bar was sitting in the noise.

Eight runs, idle-and-isolated through full-CI contention:

| condition | searched | computed | saving | ratio |
|---|---|---|---|---|
| CI pass `a76f45b9` | 22.32ms | 9.17ms | 13.15ms | 2.44x |
| CI pass (its `v2.x` twin `869be3ca`) | 20.11ms | 7.85ms | 12.26ms | 2.56x |
| CI **fail** `b012c1c7` | 27.11ms | 15.34ms | 11.77ms | 1.77x |
| CI pass (rerun) | 38.63ms | 13.90ms | 24.73ms | 2.78x |
| CI **fail** `2e2ec8f2` | 26.56ms | 15.41ms | 11.15ms | 1.72x |
| local idle x3 | 22-23ms | 9.05-11.25ms | 11.51-13.93ms | 2.02-2.49x[^r] |
| CI pass `2ec1a442` (the fix) | 26.39ms | 15.99ms | 10.40ms | **1.65x** |

[^r]: Ratios and savings throughout these tables are computed from the unrounded medians and then
rounded, so a row can differ by 0.01 from the quoted arms recombined (`a76f45b9` reads 2.44x where
22.32/9.17 gives 2.4340). Each column of the `local idle x3` row is additionally the range over
three runs, not one run read across: the widest
saving and the highest ratio come from different runs of the three, so the four columns cannot be
recombined into a single consistent triple. Every other row is one run and does reproduce exactly.

**The last row is the validation, and it is the one to remember.** The commit that fixed this
measured a *lower* ratio than either failure it replaced — 1.65x against 1.77x and 1.72x — under the
same full-suite contention. The old bar would have taken CI red a fourth time on the fix itself. The
saving read 10.40ms and passed.

Ratio range 1.65-2.78, crossing its bar three times out of nine. Saving range 10.40-24.73ms, never
near zero. The test now asserts `saving > 6.0ms` — 42% below the smallest ever measured — and **the
mutation proves it still discriminates**: putting the six-child search back in the computed arm
gives `saving=0.08ms` and fails. Both contention modes push the saving the safe way, additive leaving it flat and
multiplicative widening it, which is why no load-scaling is needed.

The probe is now printed and **explicitly not asserted on**. The old type comment claimed the bar
"stretches by that factor" and no code ever did that — a load-scaling that existed only in prose. It
could not have worked anyway: the probe read **9.2ms idle and 7.4ms on the contended CI run that
failed**, so it is anti-correlated with the starvation it was meant to detect. **A probe that never
feeds an assertion is never checked, and this one had been wrong for as long as it had been there.**

**A saving floor does not guard the second regression, so the arithmetic is now measured directly.**
The type comment claimed the bar catches both "the search is back" and "the arithmetic itself became
expensive". Only the first is true of a saving, and the demonstration is unambiguous: putting a full
layout back inside the timed rung loop drives one `rung(fitting:)` from ~20µs to **19,611µs**, and
**the saving assertion passes right through it at 16.07ms**. A thousandfold regression, invisible to
the bar that claims to catch it. The fix is not to bring the ratio back — contention is what broke
that — but to time `rung(fitting:)` on its own, away from any view building, against a 400µs
ceiling — one to two orders of magnitude from the regression it guards, so load cannot reach it.
(One reappearing row build is ~4,000µs against that 400µs bar, and the mutation above measured
19,611µs; an earlier draft of this said three orders, which overstated the margin by ~30x.)

**Calibrate a bar from a contended run, not a quiet one.** The first ceiling tried was 40µs, chosen
against an idle 23.73µs and looking generous. Four runs later it was plainly wrong:

| run | rung | probe | searched | saving | ratio |
|---|---|---|---|---|---|
| quiet | 23.73µs | 8.5ms | 23.97ms | 14.02ms | 2.41x |
| quiet | 20.48µs | 9.0ms | 26.84ms | 15.93ms | 2.46x |
| contended | 43.26µs | 15.1ms | 57.72ms | 26.94ms | 1.88x |
| contended | 41.00µs | 16.2ms | 56.62ms | 23.54ms | **1.71x** |

40µs would have failed the third run outright. The last row is worth its own note: **the retired
1.8x ratio would have failed there too**, a fourth flake on an unchanged tree, measured rather than
argued — while the saving ranged 14.02-26.94ms against its 6ms floor throughout.

**A saving floor can also fail on an improvement**, which is worth knowing before reading a red as a
regression: the saving is proportional to what building one header row costs, so an edit that makes
the row much cheaper shrinks both arms and the gap between them. The failure message names both
possibilities, and the rung ceiling is what tells them apart — if it still passes, nothing got
expensive and the floor wants re-deriving.

**`ColumnClickCostBenchmark` was scaled by the same probe, and there it really did multiply the
bar.** `slowdown = max(1.0, probeMedian / 10ms)` against a 120ms budget. Keep the runs straight,
since the point of the entry is a number nobody checked: during the CI run where the *header*
benchmark failed on starvation, this test printed **`slowdown=1.00x`** and passed, so its multiplier
was floored and its bar unstretched — no inflated ColumnClick median is recorded beside it. The
9.2ms-idle against 7.4ms-contended pair is the *header* benchmark's probe, and it is the direct
evidence that a CPU probe is anti-correlated with this machine's starvation. The **163ms with
nothing regressed** is from a separate, earlier deliberate-starvation run whose `slowdown` print was
not recorded. Put together: a multiplier that demonstrably does not rise, guarding a bar the
documented worst case already sits above. It is now a fixed 250ms: above that worst case, still far below the ~290ms click the test was
built to chase, and legitimate as an absolute because `.machinePinned(.calibratedTiming)` pins it to
the machine it was calibrated on. The probe is printed and asserted on nowhere.

A tight FNV loop and a run-loop-driven render are starved by different things — the loop only wants
a core, the render waits on the main run loop and the window server — which is why one was never
going to measure the other. **Do not reintroduce a CPU probe as a load signal for anything that
renders.**

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

---

### 10. Every gate parks at once, on the pool their releases need

**Symptom.** Several Sync tests fail together, all with the same expectation and all at ~12.5 s
wall clock:

```
✘ testPrefetchFastPathClearsStaleLoadingSpinner()  DifferenceResolutionTests.swift:399
    Expectation failed: !((gate → SyncTests.ParkGate).releasedByTimeout → true → true)
```

They arrive in a cluster (4 and 7 issues in two runs here), the cluster's membership changes from
run to run, and every member is a `ParkGate` or `FirstStatGate` user. Seen across
`DifferenceResolutionTests`, `AutoVerifyOnScanTests`, `BulkCopyExclusionTests` and
`FileSyncManagerTests`.

**This is the honest half of mechanism 8 doing its job, not a regression.** `releasedByTimeout` is
the recorded-expiry flag that section argues for: the parked call gave up at its 10 s bound instead
of being released, and says so, rather than resuming quietly and letting the test assert against
state it never held. So the failure is real — it just is not about the code under test.

**Mechanism.** `ParkGate.park()` blocks a **real thread** on a `DispatchSemaphore` for up to 10 s,
and the async side of the test is what signals `release` — so the release needs a thread to get
there. swift-testing starts its suites together, which means the gated tests all park at
*the same moment*, near the very start of the run.

Sampled 1 s into a full parallel run: **9 threads simultaneously blocked inside
`ParkGate.park` / `FirstStatGate.gateIfFirst`, 8 of them on `com.apple.root.*.cooperative`
queues** — the Swift cooperative pool, whose width is the core count (10 logical here). The parks
are holding very nearly the whole pool, and every release has to be scheduled on what is left,
alongside the ~1,900 other tests that also just started. In a run that passes they all clear within
about 4 s (sampled at t≈4 s: none left). In a run that fails, some are still waiting at their 10 s
bound — which is why every failure lands on the same number: the bound, not the work, is what ends
the wait.

It is therefore a function of **how many tests run concurrently**, not of how busy the machine is —
and those two are easy to confuse, because both correlate with "the suite is slow right now".

**The measurements that separate them** (2026-08-11; `main` at `375d98f5`, `v2.x` at `faf23c13`;
10 logical cores):

| What was run | Result |
|---|---|
| The four affected suites alone, in parallel, ×3 | pass, 0.12 s |
| The same four suites alone under 8 `yes` spinners | pass, 0.124 s |
| The whole Sync suite (170 suites), in parallel, ×4 | 1 pass / 3 fail (4, 4, 7 issues) |
| The whole Sync suite, `--no-parallel` | pass, 27.6 s |
| The whole **v2.x** Sync suite (109 suites), in parallel, ×4 | pass, ×4 |

CPU saturation does not reproduce it and serialising cures it, which is what makes this a shortage
of *threads* rather than of cycles. The v2.x row is the same point from the other side: that line
carries the same gates and the same 10 s bound and simply runs 61 fewer suites, so it currently
sits under the threshold — below it, not immune to it.

**Confirming it on a given run.** Sample the test binary in the first second — that is the only
window in which the parks are all in flight, and a sample taken at t≈6 s finds nothing and looks
like a refutation:

```bash
(arch -arm64 swift test --package-path Modules/Sync &)
for i in $(seq 1 60); do PID=$(pgrep -f SyncPackageTests | head -1); [ -n "$PID" ] && break; sleep 1; done
sample "$PID" 1 -file /tmp/s.txt
grep -cE 'ParkGate.park|gateIfFirst' /tmp/s.txt        # how many are parked right now
grep -B99 'ParkGate.park' /tmp/s.txt | grep -c cooperative   # …and how many hold a pool thread
```

**Diagnosing it.** Before reading any diff, run the suite twice more, and run it once from a clean
checkout of the line's tip — the primary checkout is already sitting there:

```bash
arch -arm64 swift test --package-path Modules/Sync                      # again: does the set change?
arch -arm64 swift test --package-path Modules/Sync --no-parallel        # serial: does it clear?
```

A cluster whose membership moves between runs, and a clean serial pass, together mean the commit in
front of you is not the cause. A single member that fails **every** time, serial included, is a
genuine gate regression: something stopped signalling `release`.

**Fix.** None applied — this is registered rather than fixed, because every candidate has a cost
worth weighing first, and the failure is loud and self-describing when it happens:

- Raising the 10 s bound trades a false failure for a slower one and does not remove the starvation;
  it only moves the threshold, which is what the growing suite count will find again.
- `.serialized` on the six gated suites is the targeted version of the `--no-parallel` result above,
  and costs only those suites their overlap.
- Not blocking a pool thread at all is the real fix: the park exists to hold a **synchronous** seam
  call in flight, so it needs a thread of its own (a dedicated `Thread`/`DispatchQueue` outside the
  cooperative pool) rather than whichever one the seam happened to be called on.

Whichever is taken, mutation-test it: a gate that no longer engages and a gate that engages and is
released look identical from the outside — that is the whole reason `releasedByTimeout` exists.

**See.** `Modules/Sync/Tests/Sync/TestSupport.swift` (`ParkGate.park`, `FirstStatGate`,
`awaitSignal`); mechanism 8 above for why the bound records its own expiry; mechanism 3 for the
other way suites-in-parallel decides a verdict.

---

### 11. Five palette tests the fixture dismissed out from under itself — FIXED

**Fixed on 2026-08-16.** Kept because the symptom is worth recognising on sight, and because two of
the reasoning errors that held it open for weeks generalise well beyond it.

**Symptom.** Only the **app-target** step fails; all seven package suites pass. Five
`CommandPalettePanelTests` fail together, every expectation saying the same thing a different way —
the child window is not there (`panel → nil`, `childWindows → []`, `count → 0`). Each fails in
**well under a tenth of a second**: 0.079s, 0.041s, 0.032s.

**Cause.** The fixture's `present` helper called `host.orderOut(nil)` right after
`CommandPalettePanelController.present`, to keep a 900×600 titled window off the user's desktop.
That one call dismissed the palette it had just raised, and it reproduces on demand. The chain,
every link observed: ordering out a parent takes its child with it; a child ordered out while it
holds key posts `didResignKey`; the controller's resign observer answers that with `dismiss()`
(correct app behaviour — losing key is exactly when the palette should close); `dismiss()` calls
`removeChildWindow` and clears `panel`, which is the entire failing signature, produced inside
`present` before the first `#expect` is reached. **Delivery is synchronous** — a `NotificationCenter`
block observer registered with `queue: .main` runs on the spot when the post is on the main thread —
which is how three of the five could lose without ever awaiting.

**Fix**, in the fixture only (`SyncCloudTests/CommandPalettePanelTests.swift`). The host is
**borderless** and **parked past every display** rather than titled and ordered out: borderless is
the case `constrainFrameRect` skips (15/15 each way — a titled host is dragged back onto the
display, which is why the old entry recorded parking as spent). `present` orders nothing out.
`theHostAndItsPanelStayOutOfSight` accepts **either** remedy, so neither is pinned. **Every
dismissal is witnessed** and reported into the failure message with the app's activation state and
stack frames — the part that matters if it returns, because the five messages could not distinguish
"never attached" (a real regression in `present`) from "attached and then torn down". And
**`onlyTeardownEverOrdersAWindowOut`** scans the fixture's own source and fails if anything outside
`teardown` orders a window out; without it, re-adding the fatal call leaves the suite green until
the next run on which the panel happens to hold key.

#### The two reasoning errors that kept it open

**A probe run in a state where the mechanism cannot exist is not a refutation.** This exact theory
was tested, fired **once in twenty-one runs**, and was written off as noise. The probe was a
standalone binary — and in one of those `NSApp.keyWindow` is `nil` and **no window is ever key**, so
twenty of those runs could not have fired whatever the code did. The single firing was the signal.
Before a null result retires a hypothesis, check the harness could have produced a positive.

**"Removing the `orderOut` breaks the suite" was true, and still not a reason to keep it.** It broke
exactly one assertion while fixing the other four. Reading a one-test regression as "this remedy is
spent" is what closed the door on the right answer for weeks.

A third, from the same afternoon: `CommandPalettePanel.swift` set `panel.hidesOnDeactivate = true`
as "a second belt" — but **`addChildWindow` clears the flag**, and the assignment ran before it, so
it was inert for as long as it was written down. The first attempt to explain *that* blamed the
`.nonactivatingPanel` style mask, which a four-mask probe refuted outright. **Naming a cause without
measuring it is the error this whole entry is about, and it was made twice in one afternoon.** The
line is deleted rather than moved, because `NSApp.deactivate()` with the palette up is measured to
close it outright — strictly better than hiding it.

**A single measurement of an environment is a measurement of that environment then.** The suite's
note had read "real key transfer is not observable in this test host", and two tests were retired on
it. Whether an `xcodebuild` host is frontmost depends on what else the machine is doing — which is
the whole of the burst pattern, and why CI pass, CI fail, local pass and local fail were all
observed on unchanged code.

**What is NOT closed**, and it is live rather than theoretical: the panel really does take key here,
so a genuine key change during a test still dismisses it, as does a stray mouse-down anywhere in the
app. Both need a runloop turn, so neither can reach the three synchronous tests, but both can reach
the two `async` ones. **Consecutive green runs are not evidence that they never will** — this came
in bursts over hours. If it reappears, read the witness in the failure message rather than counting
reruns.

#### Still true, and worth keeping

**Check whether the failure spent time.** Every assertion here is a *missing object* and fails in
under 0.1s; a starved test *spends* its ceiling, 25s or 32s. A stall and an absence look nothing
alike, and reaching for a timing cause before checking which one you have is how this entry
accumulated two dead hypotheses.

**Do not bisect `MacApp/`.** The app code these tests cover did not change across any of the
failures: two of the three failing commits were documentation-only, and two sessions hit it on
disjoint file sets.

**The display hypothesis is DEAD; do not re-derive it.** `pmset -g log` recovers display state
retrospectively, so it settles without a new run: two captured app-target runs sit inside a
display-OFF window and **passed**. The lock correlation was never confirmed — one matching pair and
one unexplained failure.

**See.** `SyncCloudTests/CommandPalettePanelTests.swift` — `makeHost` carries the deduction and the
measurements in full; `5c851773` for the change that introduced the `orderOut`; mechanism 1 for the
display-asleep sibling, which is a window that exists and will not animate.

### 12. A log assertion reading a window that has already rolled

**Symptom.** Two shapes, and it is the second that earns this entry.

- A **presence** assertion fails for a line that really was written — in the full suite only, never
  under `--filter`, and re-running sometimes clears it.
- An **absence** assertion **passes**, having looked at nothing at all. There is no symptom. That is
  the symptom.

**Mechanism.** `Logger.shared` is one process-wide singleton, and `entries` is capped at the newest
**1000** lines — `Modules/Events/Sources/Events/Logger.swift:376`:

```swift
if entries.count > 1000 {
    entries.removeFirst(entries.count - 1000)
}
```

swift-testing runs suites in parallel, so every suite in the package writes into that one array at
once. A test that reads `Logger.shared.entries` *whole* is therefore reading a window whose contents
are decided by whatever else happened to be running — and 1000 lines is not many when a full package
run is walking trees and syncing files in a dozen suites beside you.

**Why it presents as a flake rather than as a bug.** Under `--filter` your suite is very nearly the
only writer, 1000 is effectively unbounded, and the window never rolls. In a full-suite run the rest
of the package logs past your line *while your own fixture is still working* — awaiting a refresh,
walking a fixture tree, waiting on a quiescence poll. Same source, opposite verdicts, decided by what
else was scheduled: step 4 of the triage above ("do not stop at `--filter`") exists for mechanisms
like this one.

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

**Measured, not theorised.** `f87d9e11` records it in as many words — *"`Logger.shared.entries` is
capped at 1000, so a test that awaits a whole refresh before reading can watch its own line get
evicted by other suites — this failed twice in parallel runs before both halves were made to read
immediately"* — and the finding is kept next to the test it cost, in the doc comment of
`wideningAOnePaneRefreshSaysSo` in `Modules/Sync/Tests/Sync/LoggingGapTests.swift`: the first
version of that test awaited the refresh and then reported a missing line **for a line that had
been written**.

**Fix.** Four rules. The first two are the whole of it; the second two are what make them hold.

1. **An absence assertion needs BOTH guards: your own marker FIRST, `#require`d to have survived,
   AND an awaited flush LAST.** The marker goes in *before* the call under test and the assertion
   reads only from it onward, so a window that rolled past your own opening marker fails the
   `#require` and says the reading was vacuous instead of passing. That closes **eviction** — and it
   says nothing about **visibility**, which is the other way this assertion reads an empty interval.
   `Logger.log(level:message:)` is `nonisolated`: it hands the entry to a FIFO queue drained by a
   `@MainActor` flush task (`log(level:message:)` and `flushPendingEntries()` in
   `Modules/Events/Sources/Events/Logger.swift`). On a `@MainActor` test that does not suspend
   between the call under test and the read, that flush has not run, and the line is simply not in
   `entries` yet. Close it by awaiting one more entry's task before reading — `await
   Logger.shared.debug("… flush marker").value` — which, the queue being FIFO, drains everything
   enqueued before it.

   **Measured 2026-08-17, as a pair, because this rule used to say only the first half.** A
   `@MainActor` probe applying the marker and the `#require` but no trailing flush **passed** an
   absence for a line its own call under test had just written. The identical probe with one awaited
   flush added **failed**, correctly seeing the line. A third — flush present, and 1100 filler lines
   rolling the window between the marker and the read — failed on the `#require` instead. The two
   guards are independent and both are load-bearing: the flush cannot see eviction, and the marker
   cannot see the queue. Every implementation in this repo already had the flush; it was the advice
   that had dropped it, which is why `ContentSignalExtractorTests` below keeps both.
2. **For a presence assertion, read strictly BETWEEN two of your own markers** — open, act, close —
   rather than over the buffer. This does three jobs at once: the `#require`d opening marker is the
   eviction guard as above, the *awaited* closing marker is rule 1's flush (which is why this shape
   has never shown the visibility bug — it supplies the drain as a side effect of bounding the top,
   and that is worth knowing deliberately rather than relying on by accident), and the bounded slice
   stops a *foreign* line with the same text satisfying your assertion, which a whole-buffer
   `contains` cannot distinguish from your own.
3. **Read as soon as the decision is taken, not after the work completes.** Most of these lines are
   written synchronously at the top of an operation, long before it finishes; awaiting the whole
   operation just hands the rest of the package more time to roll your line away. Wait on the
   decision's own observable instead — `LoggingGapTests` starts the refresh as a `Task` and waits
   only for `activeRefreshKey` to move.
4. **`.serialized` when a sibling in the same suite writes the same line.** The bounded slice keeps
   out lines from *before* and *after*, not lines a concurrent sibling drops *inside* it.
   `PaneTabsStoreTests` needs it because `aCorruptValueReadsAsNothingStored` emits the very sentence
   `anUnreadableStoredStripIsReportedRatherThanSilentlyReplaced` asserts. (The cross-*suite* half is
   mechanism 3's known residual. Closing it by picking a fragment no other suite writes — grep the
   package before trusting one — works only when the wording is yours to choose; when production
   code writes the same sentence from several call sites, filter by authorship instead, per the
   subsection below.)

**Measured, 2026-08-17, and it is why rule 4 is not optional where it applies.**
`Modules/Sync/Tests/Sync/UndoDriftIdentityTests.swift` had rule 1 and only half of rule 2: its
`logLines(since:)` wrote a closing marker and then sliced `entries[start...]` to the end of the
buffer anyway. Two of its tests assert the **byte-identical** line `Undo (Normalize 2 Names): moved
2 of 2 item(s) back to source, 0 restore failure(s), 0 left in place`, both are `@MainActor` but
both suspend at `waitUntil`, so they interleave — and CI runs this target **without**
`--no-parallel`, so parallel is the configuration that ships. Remove one test's own undo so it
writes no line at all, delay its sibling so the identical line lands inside its window, and the
presence assertion PASSED on a line its own code never wrote. **It passed just the same once the
window was bounded strictly between its own markers**, because the sibling's line is INSIDE the
window, not after it; `@Suite(.serialized)` is what made the same mutation fail (3 issues → 4). Both
landed. Read rule 2 as closing the *before and after*, never as covering rule 4's job.

#### The uncapped on-disk log — a better substrate, and why it is not a free win

**Measured 2026-08-22, in the order the mistakes were made, because the sequence is the lesson.**

Everything above operates inside `entries`, so every remedy is shaped by its 1000-line cap. There is
a second copy of the same stream that has no cap: `Logger.shared.logFileURL`. Two properties make it
the better substrate for these assertions, and both are worth stating because neither is obvious —
the append happens **at the call site**, synchronously inside the `nonisolated log(level:message:)`
and *before* the flush task is returned (`logWriter.append(entry.formattedString + "\n")`), so the
file preserves call order and needs no flush marker to become visible; and the 1000-line trim lives
in `flushPendingEntries()` and touches `entries` alone, so the file never rolls. Under a test runner
it is a per-process temp file (`sync-cloud-tests-<pid>.log`, see `defaultLogFileURL()`), so it is
scoped to the run and does not touch `~/sync-cloud.log`.

`logLines(tag:during:)` and `loggedLineOnDisk(containing:)` in
`Modules/Sync/Tests/Sync/TestSupport.swift` read it.

**But moving to it makes the shared-fragment collision worse, not better** — the haystack stops
being the last 1000 lines and becomes the entire run. Switching substrate closes eviction and
*widens* rule 4. That is not a prediction: `9af896bf` said so in its own commit message and then left
`MergeUndoGroupingAndGateTests` matching a 7-call-site fragment with `last {}` off the newly
unbounded file. It passed under one full-suite ordering and failed under another.

**And windowing does not close it either, because a window bounds time, not authorship.** Bound the
same assertion strictly between its own markers and a *foreign suite's* refusal still lands inside
the window and wins the `last {}`. Rule 4 prescribes `.serialized` for the same-suite case and
otherwise sends you to "pick a fragment no other suite writes" — which is sound advice that does not
always have a move available, because **the production code decides the wording, not the test**.
`"at the last check before removal"` is written by **7 call sites** in
`Modules/Sync/Sources/Sync/FileSyncManager+Duplicates.swift`; there is no unique fragment to pick.

**So: filter by authorship.** Every one of those refusals names a path, and each test's fixture root
is a per-test UUID temp directory, so the fixture's own root is a witness that the line is *yours*:

```swift
let line = mine.last { $0.contains("at the last check before removal") && $0.contains(base.path) }
```

Check the filter is not circular before using it — here it is not, because the assertions read the
refusal's *wording* and the copy's *name*, never the root itself.

**Audit the fragments rather than assuming.** Grepping every `loggedLine(containing:)` fragment in
the package against the sources found this to be the only over-shared *literal*; the rest are
single-site or carry a test-injected token. That audit is the cheap step and it is what tells you
whether you need the authorship filter at all.

**But that grep only sees literals, and it missed two live cases the same day it was written.** A
fragment computed at RUNTIME — a file name, an id, anything derived from fixture state — never
appears in a source grep, so the question has to be asked of the value instead: *can another episode
in this process produce this same string?* Both misses were file names, and they failed that test in
different ways.

- `FilingVerdictSetAsideMessageTests` matched on the set-aside's name,
  `<cache>.unreadable-<stamp>`. `UnreadableSetAside.destination` stamps to the **second** and
  uniquifies only against the directory it writes into — which is all a file needs — so two episodes
  in different temp roots a millisecond apart produce the byte-identical name. Concurrent siblings in
  the suite then satisfied each other's assertions; `theTwoCallersDoNotMakeTheSamePromise` compared a
  sentence with itself.
- `StorageLensPreservationTests.storeURL` put the test's name in the **directory** and called every
  file `storage-lens.json`. All seven lines `StorageLensStore` writes name the file by
  `lastPathComponent` alone, so the fragment identified the file's *kind*. Measured the silent way:
  delete the call under test outright, so the test performs no action at all, and it still **passed**
  — carried entirely by a sibling's line.

Neither line carries a directory, so authorship could not be recovered from the text; the fix in both
was to make the fixture's own file name unique. **Where the test owns the name, that beats every
filter** — it makes the fragment identify the episode instead of the artifact.

**Verify a log fix in parallel.** `--no-parallel` cannot see any of this, and CI runs the package
target parallel. A serial-only green is what let the first landing go out red.

**Slice from the opening marker first, then search inside that slice.** `messages[a...b]` on
reversed bounds *traps* rather than failing, and inside an `#expect` that takes the whole test host
down with it — a rolled buffer would then report as infrastructure and lose the rest of the run. See
`SyncCloudTests/TestSupport.swift` (`textBetween`) and `TextBetweenTests` for the same hazard in
source scans.

**A flush marker is NOT an eviction guard — so add the marker, do not drop the flush.** Most sites
here still only flush, and the fix for them is to gain a survival guard, not to trade one guard for
another: the flush is what makes the line *visible* at all (rule 1's second half), and a
"modernised" test that replaced its flush with an opening marker would go back to reading an
interval its own line has not reached yet. The common idiom —

```swift
await Logger.shared.debug("some-test flush marker").value
return Logger.shared.entries.contains { … }
```

— is doing something real and necessary: the queue is FIFO, so awaiting a fresh entry's task
guarantees everything enqueued before it is *visible* in `entries`. But visibility is not survival.
The marker is written **after** the call under test and its presence is never asserted, so it proves
your line has arrived while saying nothing about whether it has already been pushed out.

Count it before trusting it, because the ratio is moving. Re-counted **2026-08-17: twelve files**
still use the flush-only idiom against **five** that read a bounded window.

```sh
grep -rl "flush marker" Modules SyncCloudTests                   # 14 files, but see both notes below
grep -rlE 'debug\("[a-z-]+ window open' Modules SyncCloudTests   # 4  — MISSES one adopter, below
```

**Neither number is the answer on its own, and the arithmetic is the point of keeping this here.**
Of the 14 files matching `flush marker`, two are not flush-only sites:
`Modules/Sync/Tests/Sync/PaneTabsTests.swift` matches only in the prose of a doc comment (it is a
bounded-window adopter), and `SyncCloudTests/ContentSignalExtractorTests.swift` now reads a bounded
window *and* keeps its flush. 14 − 2 = **12**. And the adopter regex structurally cannot find
`ContentSignalExtractorTests`, which builds its marker into a variable and passes it as
`debug(marker)` rather than as a string literal; 4 + 1 = **5**. A previous revision of this note
annotated the first command "one hit is this note's prose", which was doubly wrong: the prose hit is
in a test file, and `docs/` is not even in the grep path, so this file cannot match its own command.
Read the hits, do not trust the count.

They are not wrong today, and none has been observed to roll;
`LoggingGapTests` in particular is safe for a different reason, rule 3 — it reads at the decision, so
its window never has time to move. The rest are one busy suite away, and the ones asserting
*absence* will not tell you when it happens.

**The live exposed sites, as of 2026-08-17**, are the absence halves — the ones that cannot report
their own failure:

- `Modules/Sync/Tests/Sync/FilingScanAbandonmentLogTests.swift:51`, `:81`, `:138` — three
  `#expect(await loggedLine(containing:) == nil, …)`. The helper `loggedLine(containing:)` writes
  `filing-abandon flush marker` **after** the call under test, never asserts it survived, and then
  searches the whole buffer with `entries.first { … }`.
- `Modules/Sync/Tests/Sync/UndoRedoLogLabelTests.swift:40` —
  `#expect(!(await loggerContains("User triggered Redo: Delete 1 Items")))`. Same shape, helper
  `loggerContains(_:)`. Its siblings in that same test are presence assertions, so a roll would fail
  *those* loudly while `:40` passed for free — the asymmetry inside one test.

`SyncCloudTests/ContentSignalExtractorTests.swift` used to head this list and no longer belongs on
it: `9da161d8` converted it, and `aScanThatOCRsCleanlyReportsNoOCRFailure` is now worth copying
instead. It is the clearest implementation of the corrected rule 1 — a unique marker written and
awaited *before* the call under test, its index `#require`d with a message naming the reading as
vacuous, **and** the trailing awaited flush kept, so the interval is both survived and visible. Its
doc comment also states why it needs no `.serialized`, which is rule 4 answered rather than ignored.

**Model implementations**, in the order worth copying. Cited by **symbol**, deliberately: two of the
line ranges this list used to carry were correct when written and silently wrong a commit or two
later, once a sibling inserted a helper above them. A file whose whole value is being checkable
cannot afford citations that rot without saying so — `grep -n` costs the reader nothing.

- `window(_:)` in `SyncCloudTests/ShortcutCommandsTests.swift` — the original two-marker helper,
  with the reasoning in its doc comment and both halves (presence and absence) read through it.
- `loggedWindow(_:)` in `Modules/Sync/Tests/Sync/PaneTabsTests.swift` — the Sync-package copy;
  returns `ArraySlice<LogEntry>` so the level can be asserted too, and computes each index *before*
  the `#require` so a failure prints an index rather than 152KB of dumped buffer.
- `aScanThatOCRsCleanlyReportsNoOCRFailure` in `SyncCloudTests/ContentSignalExtractorTests.swift` —
  the absence case with both of rule 1's guards, marker-then-`#require` *and* the trailing flush.
- `wideningAOnePaneRefreshSaysSo` in `Modules/Sync/Tests/Sync/LoggingGapTests.swift` — why to read
  at the decision rather than at completion, which is rule 3 and the one that is easy to talk
  yourself out of.
- `logLines(tag:during:)` in `Modules/Sync/Tests/Sync/TestSupport.swift` — the same two-marker
  window read off the uncapped on-disk log instead of `entries`, for assertions that cannot survive
  the cap; see the subsection above for what it does *not* close.

**This mechanism has a different number on each line, so cite it by name.** It is **12** here, 11 on
`v2.x` and 10 on `v3.x`, because the three registers accumulated different entries before it. Write
"the rolled log window" — a bare number goes stale the moment a text is cherry-picked between lines,
and a commit on `v2.x` already refers to that line's entry by this one's number.

**See.** `f87d9e11` — *Account for a rollback and a widening the log could not explain* (where it was
first measured); `flushPendingEntries()` in `Modules/Events/Sources/Events/Logger.swift` for the cap
itself.

### 13. The build failed before any test ran

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

---

### 14. A palette wait that has to outlast a 36-hop retry budget

**Symptom.** `CommandPalettePanelTests.aFieldThatGoesAwayTakesItsListOffTheScreen` fails at its
second `waitUntil` — *"the list came off the screen once its field was unmeasurable"* — and the two
`#expect`s after it cascade, because they read a panel that has not been hidden yet:

```
✘ … CommandPalettePanelTests.swift:1062: Expectation failed: condition()
✘ … panel.ignoresMouseEvents → false
✘ … controller.isPresented → false
```

**Mechanism.** The behaviour under test is `refreshAnchor` giving up: with the anchor answering nil
it re-tries `CommandPalettePanelController.anchorAttempts` (36) times, one display frame apart
(`anchorRetryInterval`, 1/60s), and only then calls `hide()`. So the test is waiting on roughly
**0.6 s of `DispatchQueue.main.asyncAfter` hops** before the thing it asserts can possibly happen —
and those hops are wall-clock scheduled, not main-actor turns.

That spacing is deliberate and must not be "optimised": `main.async` runs every retry inside one
runloop drain, which is the bug `6282ad7d` and `main-queue-async-is-not-a-retry` exist to record.
The budget is load-bearing, so the wait over it has to be generous instead.

**What makes it fire.** Anything competing for the machine while the app-target step runs — another
worktree's package suite, a concurrent `xcodebuild`, a local full-suite run. Observed 2026-08-20 at
load average 5.79 with a second session running `Modules/Dashboard` from another worktree; the same
test then passed **in isolation in 1.3 s** and passed again in a full 806-test run once that suite
finished. Mechanism 10's family, reached by a different route: there the gates park on a shared
pool, here a fixed frame budget stretches past the waiter's.

**Before blaming a commit.** Two questions, in this order:

1. **Did it fail alone?** `-only-testing:SyncCloudTests/CommandPalettePanelTests` runs in seconds. A
   pass there and a failure in the full run is this mechanism, not a defect.
2. **Was the machine busy?** `uptime` and `pgrep -fl swiftpm-testing` — a second worktree's suite is
   the usual answer, and it will not appear anywhere in the failing run's own log.

A change to the palette's anchor path is the one case where this deserves a real look; the fixture
drives `refreshAnchor` through a nil anchor, so a genuine regression there fails it every time
rather than under load.


### 15. A readiness window the fixture starts before the code it is timing — FIXED

**Symptom.** `CommandPalettePanelTests.theAnchorKeepsLookingAcrossRunloopTurnsRatherThanSpending
EveryRetryAtOnce` fails on its **first** expectation, the one that only sets the scene:

```
✘ … CommandPalettePanelTests.swift:1022: Expectation failed: (state.listWidth → 420.0) == (0 → 0.0)
```

Read quickly this looks like the anchor path misbehaving. It is the opposite: the anchor found the
field *immediately*, which is the one thing the test needs not to happen yet.

**Mechanism.** The fixture modelled "an anchor with nothing to give for the first 100 ms" as a
deadline computed **before** `present`:

```swift
let ready = Date().addingTimeInterval(0.1)
let state = present(controller, over: host, anchor: { Date() >= ready ? field : nil })
```

`present` consults the anchor synchronously, so the window is a race against `present`'s own
duration — and `present` raises a panel, parents it to the host and lays a SwiftUI list out. On a
loaded machine that costs more than 100 ms, the first call already answers the field,
`state.listWidth` is 420 before a single retry is scheduled, and the retry path under test is never
entered at all. The assertion that fires is the **non-vacuity guard**, doing its job.

**What makes it fire.** Load, same as mechanism 14 next door — but the failure is a fixture defect
rather than a wait that needs widening, so it is fixable rather than triageable. Observed on CI
2026-08-21 in a `workflow_dispatch` run on `main`'s tip while the same test passed **alone in
2.4 s**.

**Fixed** by starting the window at the **first consultation** instead of before `present`:

```swift
var firstAsked: Date?
let state = present(controller, over: host, anchor: {
    let now = Date()
    guard let first = firstAsked else { firstAsked = now; return nil }
    return now.timeIntervalSince(first) >= 0.1 ? field : nil
})
```

The first call is now deterministically nil whatever `present` costs, and the 100 ms is measured
across the retries — which is what the test was always trying to say.

**Both directions were measured**, by injecting `Thread.sleep(forTimeInterval: 0.3)` ahead of
`present` to stand in for the loaded machine. With the old clock that reproduces CI's message
character for character; with the new clock the suite passes. The guard still bites: reverting
`refreshAnchor`'s `asyncAfter` to `main.async` fails the test at its *second* expectation
(`(state.listWidth → 0.0) != (0 → 0.0)`), which is the shipped defect this test exists for.

**The general shape, worth more than this instance.** A fixture that computes a deadline and then
runs the code it is timing has made the code's own duration part of the threshold. Start the clock
from inside the thing being measured, or the test is timing the machine.

---

### 16. Text-field focus is arbitrated process-wide, so any suite can evict another's field editor — FIXED

**Symptom.** A full-package `swift test` in `Modules/FileExplorer` fails exactly one test, while
`--filter` on that suite alone passes:

```
✘ … LensHeaderReadoutTests.swift:240: Expectation failed: (moved → 4511) == 0
  ↳ the to-fix rows are still on screen under a query matching neither of them (4511 pixels differ)
```

The number is *identical* in every failing run, which reads as a deterministic product defect
rather than a flake — and the message names a cause that was never true.

**What the pixels actually were.** Not the to-fix rows. Both screens correctly drew "Nothing
matches. The current search hides all 2 renames." with neither risky name on them; the filter was
working in the red runs and the green ones alike. The diff bounding box is `x∈[49,193],
y∈[171,203]` — the **select-all highlight band behind the query text in the header's own search
field**. `ExpandingSearchField` claims focus on appear (`Modules/Design/Sources/Design/
ExpandingSearchField.swift`), and AppKit select-alls a field that becomes first responder, so a
capture taken *with* the field editor installed differs from one taken without it.

**Mechanism.** **SwiftUI arbitrates `_SystemTextField` focus process-wide, not per window.** None of
these offscreen windows is ever key, so the per-window first-responder isolation you would expect
never applies. Measured: a settled mount reads `fr=_SystemTextFieldFieldEditor`; a *foreign*
`window.makeFirstResponder(field)` in an unrelated suite flips it to `fr=NSWindow` and moves 4511
pixels **on the very next layout pass, with zero pumps of delay**. The failing test's own second
mount does it too — mounting window 2 evicts window 1's focus. The suite had been passing on the
order in which its own two mounts happened to steal focus from each other; adding *any* concurrent
focusing test elsewhere in the package re-rolls that order.

**What makes it fire.** Not load — verified: skipping two unrelated slow tests changed nothing,
while skipping the concurrent focusing tests went green. It is not a property of any particular
pair either; three tests in `FilingWalkthroughCardKeyTests` can do it, and so can the failing test
itself. `--skip` experiments shift the interleaving without removing the hazard, which is what makes
this one so easy to misattribute to whichever suite was added last.

**Fixed** by resigning first responder in the suite's single capture funnel, so every snapshot is
taken in the same, field-editor-free state:

```swift
m.window.makeFirstResponder(nil)   // in LensHeaderReadoutTests.snapshot(_:_:)
```

**Both directions measured.** Under the fix a settled mount is byte-identical across **400 further
layout passes** (it shed 4511 without it), and a foreign steal moves **0 pixels across 40 pumps**.

**That 400 is a fixed loop count, and the previous number was not.** This line read 311 while
`LensHeaderReadoutTests.snapshot`'s own comment read 300 for the same measurement. Neither was
wrong-as-typed: both came from a time-bounded `LayoutPumpWait.pump(upTo:)` whose pass count is
whatever the machine got through, so two runs disagree by construction and there is nothing to
reconcile between them. Re-derived 2026-08-21 as an explicit `for i in 1...400` comparing each
frame's `bitmapData` against the settled baseline — first drift: none. Both places now say 400,
and the number means something a rerun can reproduce. **A pass count taken from a deadline is a
reading about the machine; only a fixed count is a reading about the code.**
The assertion still bites: forcing `RenameBacklogSearch.matches(_:RiskyName)` to `true` — the
shipped defect the test exists for — fails it at **8478 px**, which is what the no-query control
measures for those two names. Full package: 1444 tests in 204 suites, green twice, same count as
the red runs.

**The general shape.** A rendering assertion is only as stable as the process-global UI state at
capture time, and focus is process-global here even when windows are not. If a snapshot can be
perturbed by what some *other* suite is doing to the responder chain, normalise that state in the
capture funnel rather than reasoning about who ran first. And when a failure message names a cause,
check that the cause is what actually moved the pixels — this one cost an entire investigation
aimed at the wrong subsystem.

### 17. The control that stops an absence being vacuous is itself load-dependent

**Symptom.** The test fails on its **control**, not on the thing it is testing. Every substantive
assertion passes; the one that fails is the one asserting the test was in a position to observe
anything. It fails at the boundary, and its message is *true*.

**Mechanism.** `noUndoGroupIsEverOpenWhileTheMergeIsSuspended` in
`Modules/Sync/Tests/Sync/MergeUndoGroupingAndGateTests.swift` samples `undo.groupingLevel` from the
main actor for as long as a merge runs, and then asserts the reading is meaningful before it asserts
the reading:

```swift
while !finished.withLock({ $0 }) && ContinuousClock.now < deadline {
    maxLevel = max(maxLevel, undo.groupingLevel)
    samples += 1
    try? await Task.sleep(nanoseconds: 2_000_000)
}
#expect(samples > 20, "only \(samples) samples were taken — too few to have observed …")
#expect(maxLevel == 0, "an undo group was open …")
```

`samples` is not a duration and not a count of anything the code does. It is
`merge_duration / actual_sleep_interval`, and **the denominator is the machine's**: `Task.sleep`
overshoots 2ms by however much the main actor is contended, so the *same* merge yields fewer samples
on a loaded box. The guard then fires on a run in which nothing whatsoever is wrong — the merge
completed, `ok == true`, the copied and trashed files are where they should be, and `maxLevel` is a
correct zero.

**Why it is filed apart from "Fixed pumps and fixed sleeps".** That mechanism is a wait too short
for the thing under test to have happened, and its fix is to poll a real observable instead of a
fixed window. This test already polls a real observable. What is fixed here is not the wait but the
**threshold on the evidence**, and the two need opposite repairs: nothing about polling harder makes
`samples` larger, because the sleep interval is what shrank the count.

**The trap is that the obvious fix restores a silent failure.** This guard is the good kind — it is
there precisely so `maxLevel == 0` cannot pass vacuously on a run that never looked, which is the
whole subject of [the silent half][silent-half] in the triage page. Lowering the threshold, or
deleting the guard, converts a noisy false failure into exactly the quiet false pass the guard was
written to prevent. **A vacuity control must not be relaxed to stop it
flaking**; it has to be re-expressed in a quantity the machine does not set.

**Measured, 2026-08-22.** CI run `32595371148` failed it at `samples → 20` against `> 20` — one
short, at the boundary — in 3.244s. Locally the same day, under a heavier local load (three package
suites and a build in flight, load average 16), the same test read `samples → 2`. It passed in run
`32597536957` with the whole package green at 2715 tests. The spread 2 → 20 → passing across one
day, on one machine, on unchanged code, is the mechanism.

**Fix pattern.** Express the control in something the code produces rather than something the
scheduler does: count the *suspensions the merge actually took* (the operation can report them), or
sample on the operation's own progress notifications so one sample is one step, not one sleep. If
the sample count has to stay, it is a floor on **turns observed while the operation was in flight**,
and the loop that produces it must be driven by the operation, not by a clock. Anything of the form
"N sleeps means enough looking" is the same throughput bet "Fixed pumps and fixed sleeps" names,
wearing the clothes of a correctness guard.

[silent-half]: flaky-triage.md#the-silent-half--read-before-writing-any-absence-assertion
