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
rest of [the silent half](flaky-triage.md#the-silent-half--read-before-writing-any-absence-assertion).

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

**A 5-second deadline that needs 21 milliseconds, 2026-09-08 — FIXED 2026-09-09.**
`UndoQuitGuardTests.testUndoHandlerCountsOperationBeforeItsTaskRuns` polls
`activeFileOperationsCount` — the right shape, per everything above — but behind a flat
`ContinuousClock.now + .seconds(5)`. In a full 3411-test parallel run at load average ~12 the
budget expired and the test failed on the FINAL `== 0` (line 34) reading `1`, **after 8.270 s**.
That last assertion is the tell: a failure there means the loop burned its whole deadline, which is
a statement about the machine, not about the counter. Alone on a quiet machine the same suite is
green in **21-25 ms across three consecutive runs** — a 200x margin — and the whole package goes
**14.2 s quiet against 33.6 s loaded**, which is the same 2.4x that turns 21 ms into more than five
seconds.

**Fixed by routing both drains through `waitUntil`**, which is bounded by POLLS as well as by
seconds — and the polls are the half that survives congestion, since what these wait for arrives on
main-actor turns and a congested run has fewer of them per second, not more. Widening the seconds
would have been guessing at a number; `waitPollFloor` guarantees 50 evaluations however slow the
machine is, which at the 223 ms/poll worst case in this file is ~11 s of real waiting against the
two polls the operation actually needs.

Mutation-tested by removing the decrement in `enqueueFileOperation`'s completion
(`FileSyncManager.swift`): both tests then fail at the wait, anchored at the CALL SITE rather than
inside the helper, reporting

```
the create-folder undo's decrement returns the counter to zero — still false after 417 polls
```

417 is the number that matters. A wait that gives up after hundreds was genuinely disproved; one
that gives up after a handful was starved and says nothing about the code — which is the
distinction the old hand-rolled loop could not draw, because it reported neither. Green costs
nothing: the suite still runs in 17-19 ms.

**The load reproduction did NOT work, and that is worth recording rather than hiding.** Ten `yes`
spinners on a ten-core machine took the package run from 13.5 s to 29.9 s (load 15.05) and the fixed
suite passed — but so did the ORIGINAL hand-rolled deadline under the same treatment, at load 26.24.
So that green says nothing: synthetic CPU load is not the thing that breaks this. What starves these
waits is contention for MAIN-ACTOR TURNS from several hundred sibling tests, and a spinner burning a
core does not queue work on the main actor. Anyone reaching for `yes` to reproduce a wait flake here
should expect the same non-result.

The case for the fix therefore rests on the mutation test above and on a structural argument, not on
a reproduction: a poll floor strictly dominates a wall-clock-only bound, because it cannot be
consumed by a machine that is slow. That is sound, and it is also weaker evidence than a reproduced
red would be — stated plainly so nobody later cites this entry as proof the failure was reproduced.

**The general lesson, since two spellings of this remain in the tree.** A seconds-only deadline in
a test is a bet that the machine will not be busy, and this repo's runner IS the developer's Mac.
`FileSyncManagerFilingTests` and `MergeUndoGroupingAndGateTests` still carry hand-rolled
`ContinuousClock` deadlines; they have not misfired, and they are not swept here on that basis, but
they are where to look first if either goes red under load. *The first one went red on 2026-10-25:*
`parkUntilReleased`, now bounded in scheduler turns — mechanism 40.

**A third spelling, in the app target — `EditorAutosaveDriverTests`, 2026-09-26 — FIXED, and
REPRODUCED.** Three CI runs on `main` in a row (638edd11, 08597a94, 3eabd911) went red on one
assertion with every package green: the suite's harness control,
`aDirtyDocumentIsWrittenByTheModifiersFirstTask`, `writes.count >= 1`, after 10.7, 15.0 and 20.6 s.
Its wait was a hand-rolled `Date()` deadline over the autosave modifier's first `.task`.

*The tell looks like **Leaked defaults suites** and is not.* Every app-target run on CI, green ones
included, has a stretch of roughly 6–12 s in which next to no test completes, then several hundred
finish within a second, and the app's own main-thread log lines stop for the same stretch — ~430
tests over 10 s in the GREEN runs, and 1,721 scratch plists under an hour old in
`~/Library/Preferences` that day. But `cfprefsd` measured fast (cold `defaults domains` 0.42 s at
2,259 plists), and `sample` of the test host inside the stretch finds the main thread **busy, not
blocked**: CPU in other suites' test bodies — pixel diffs, layout measurement, and until 6170108e
the scan lexer. Long main-actor tests share the FIFO main queue, so none finishes until all do.
**Sample the host before naming a freeze.**

*Why this wait lost.* The driver's `.task` must start, sleep and resume — two jobs at the back of that
queue — and the test must look once more. With the main thread held 7–12 s at a stretch, ten seconds
could run out with the `.task` still queued. 638edd11's lexer lengthened the stretches (6170108e took
that away); the green runs before it passed only because the test finished before the stretch began,
at 2.5 and 3.4 s, and the first green after 6170108e passed at 12.8 s — inside it, barely.

*Reproduced, with load of the right shape.* A scratch suite of four main-actor tests holding the
main thread in 2.5 s synchronous chunks, `await Task.yield()` between: beside it the seconds-only
wait failed at the same line after 10.03 s, with the driver untouched. Floored at `waitPollFloor`
turns it passed after 20.1 s, and alone the control still takes 0.05 s. A driver that never writes
still fails all three tests; one whose `.task` id ignores the text version fails both keystroke
tests and passes the control.

*The harness's own pump was part of the load.* Its turn ran `CFRunLoopRunInMode(.defaultMode, 0.005,
false)` inside a main-actor job, and GCD does not drain the main queue from inside its own callout —
measured: a main-actor job enqueued before a 50 ms nested loop runs only after it. So each turn held
all main-actor work for 5 ms, its own `.task` included; two sampled full runs caught the main thread
idle there 106 and 168 times at 5 ms intervals. Releasing the actor is enough: the app's run loop
lays the window out and starts the `.task`.

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

**…and that wait was still a race, because the precondition it waited for is TRANSIENT — CORRECTED
2026-09-26.** `isScanning` is true only while the first scan runs, and that scan was merely slowed
(`enumeratorDelay = 0.05`), so the wait had to catch a ~50ms window rather than read a state. On a
loaded CI run (36242263462) it gave up after 243 polls without once landing inside it; the second
request found the slot free and ran inline, and both assertions failed. The helpers read hundreds of
polls as "genuinely disproved"; that holds only for a state that stays true once reached, and a
transient one can be missed by any number of polls. **Hold a precondition you depend on; do not wait
to see it.** The first walk now parks at `MockFileManager.enumeratorGate` — whose own doc warns off
exactly this delay-and-wait pairing — the test asserts the held slot, and releases it after
queueing, so the never-queue mutation fails at its assertion in 4ms instead of only under load.
`ScanSupersedenceTests.testScanQueuedFromCancelledPredecessorStillPublishes` had the same shape and
missed its window in a local full-package run the same day. `ProgressiveLoadTests`' two
refresh-dedupe tests, which had not failed yet, went the same way on 2026-09-27; the one that
interleaves three refreshes needs a hold per refresh, which `enumeratorGate` (first listing only)
cannot give, so it arms a `ParkGate` per path through `onEnumerate` — taken out of a `LockedBox`
under its lock, parked outside it.

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

**A poll count is a diagnosis only if each poll spends a main-actor turn, 2026-10-19 — FIXED.**
`VolumeUnmountSourcesTests.unmountingACardRunsOneDiscoveryRatherThanOnePerSource` failed in 4 of
10 local full Settings runs at load 44–99, always at its first wait —
`Expectation failed: counter.count >= target`, after 25–48 s. That wait gave four add-time
discoveries 20 s to reach the lister. Nothing was lost: `discoverProviders()` reaches the lister
on every call, with no early return. Every pass starts as a main-actor `Task`; the wait polled from
a `nonisolated` helper on the cooperative pool. Instrumented beside ten main-actor tests holding
the main thread in 2.5 s chunks, it reached its deadline with **0 of 4 after 1,438 polls**, and
all four landed 5.0 s later. Unmodified, the test failed at the same line, 138:50.

1,438 polls reads as "genuinely disproved" by this section's own rule, and was nothing of the
kind. Off-main polls stay cheap while the main thread is held, so their count measures the pool,
not the turns the work is queued for — and a floor on them would have been met in under a second.
Fixed by making the helper `@MainActor`, so each poll waits its turn behind the passes, with the
usual 50-poll floor. Under the same hogs it passes at 143 s, once the hogs end. The four add-time
passes are gone too: the sources are seeded in defaults, so the first wait is for the work under
test. The quiet window after it had shared the 20 s deadline, so a starved first phase skipped it
and left the absence check vacuous. It is now counted in polls. Mutation-tested: a per-id removal
still fails "ran 4 provider discoveries", idle (3/3) and under the hogs; a removal that runs no
discovery fails at the wait after 1,380 polls; with the deadline set to zero the floor alone
passes, 3/3.

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


**Two instances on the PDFKit lane, both fixed 2026-10-17.** Each was red only in a full package
run and green under `--filter`, which the signature above predicts. **Before blaming load, rerun
the package with `--skip <the suite you just added>`.** That one run told them apart; "it passes
alone" did not.

- **A process-wide counter asserted UNCHANGED.** `PDFPreviewMountedTests.aReRenderDuringTheLoadDoesNotOpenTheDocumentAgain`
  expects `PDFOpenTicket.skippedOpens` not to move across a held lane. Edit's PDF reader counted
  its own withdrawn opens there too, and `EditorPDFDocumentTests` withdraws them on purpose, so the
  first CI run with the reader on `main` went red on that line. Fix: `EditorPDFDocument.skippedOpens`
  counts the reader's own. **A counter something asserts does not move belongs to one reader.**
- **A lane hold that waits on the main actor.** `EditorPDFRailTests` held `PDFKitSerialAccess`'s
  lane and then slept or polled on the main actor. A full run crowds the main actor, so each hold
  stretched to seconds, and other suites' 30 s `LaneHold.waitUntilHeld` budgets ran out:
  `PDFPreviewMountedTests` and `DocumentPrintingTests`, three reds per run. With `--skip
  EditorPDFRailTests` the run went green. **The first fix was not enough.** Releasing "the moment
  the queued turn is observable" still waited on the main actor, through `Task.yield`, and two
  more such holds added in `04d21b27` turned CI red twice, on the same SHA, in runs of about 800 s
  instead of 444. In both runs `DocumentPrintingTests`' 10 s budget after its own hold ran out.
  The real fix is in `EditorPDFThumbnails.Lane`: the pump's lane is injected, and those tests hold
  a private lane in front of the real one (`HeldLane`), so they block nobody else. The one test
  that must prove the real lane is used holds it from a detached task, with nothing on the main
  actor. **A test of a `@MainActor` object must not hold `PDFKitSerialAccess`; give the code a
  lane to inject.** The tell: in the CI log, unrelated tests "pass after" hundreds of seconds, all
  about the same number, and the run is far longer than the last green one.
### 4. Leaked defaults suites

**Symptom.** Accumulating `<SuiteName>-<UUID>.plist` files in `~/Library/Preferences`, and
occasionally a test reading a previous run's value. **At enough scale it stops being cosmetic and
starts failing tests** — see the stall below.

**Mechanism.** A defaults suite outlives the test that made it; `cfprefsd` rewrites the backing
plist after the process exits. It also keeps its own copy of every domain a process has written
and puts it back on disk on its own schedule — about every 10 s — so an unlinked plist returns,
as `{}` or with its old keys, whether the test process is still running or not.

**Fix.** Tear the suite down *and* delete its backing plist — after flushing `cfprefsd`'s cache
for it, or the delete does not hold; record every wiped suite in the ledger, and sweep by SHAPE as
well as by name (below).

**The delete alone had stopped holding — measured 2026-09-26.** Every suite a run wrote came back:
46 of 46 from one `-only-testing` run of four app-target suites, all within 24 ms, 3 s after the
last test finished; 68 from a full app-target run. `wipeDefaultsSuite` now calls
`_CFPreferencesFlushCachesForIdentifier` before the unlink — SPI, the call the `defaults` tool
makes, looked up with `dlsym` so an OS without it falls back to the ledger. The same two runs then
left 0, and 1: a suite `SettingsManager` wrote to after its test had wiped it, which the ledger
sweeps. **The tell:** 42-byte `{}` files whose mtimes share one instant, seconds after the tests
ended.

**What the flush left was written after its wipe, or never wiped — measured 2026-09-26.** A Settings
run left 42, twice over: 35 `TestDefaults` suites that a `SettingsManager` discovery pass (started
as a `Task` by `init` and by the methods that change a source) wrote `lastKnownAccountFolders` into
after the test's `defer` had wiped them, and 7 torn down with `removePersistentDomain`, which
empties a domain and leaves its file. Sync left 18 that never reached `wipeDefaultsSuite` at all,
and the app target 1 of the first kind. `TestDefaults` now wraps a `ScratchDefaults` and has no
`wipe()`, so the wipe waits for the last reference (the manager, and the task holding the manager),
and the other sites use `ScratchDefaults` directly: 0, 0 and 0. **The tell:** a plist that vanishes
at the wipe and is back within a second, holding only a key the code under test writes late. The
lifetime has a limit of its own: a suite still referenced when the process exits is never wiped.
Dashboard's one straggler is that, a `PaneBarOverflowMenuTests` `ScratchDefaults` never deallocated
before exit; `ScratchDefaults` records its name at creation, so the next run's sweep takes it.

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

**Not reproduced locally in 28 runs** (2026-08-04): 12 `--filter` idle, 8 `--filter` under eight
spinners, 8 full-package idle, 6 full-package under load (loadavg 10.7). So the CI runner's own
osx-x64-under-Rosetta environment is part of it, and a local green says little here.

**It DOES reproduce locally now — 2026-08-29, and that changes how to read a red here.** Nine
full-package `Modules/Sync` runs at loadavg ~5: **three red, six green**, with the same three
assertions falling together each time (`ScanSupersedenceTests.swift:41` `waitUntil` first, then
`:42` and `:48`). Measured on `main` at `39dc5fff` **and** on a branch above it, at the same rate —
which is what makes it the flake rather than either tree. `--filter ScanSupersedenceTests` alone
passed every time, in 0.3 s against the ~8 s the test takes inside a full run: the suite only misses
its 150 ms window when it is competing with the other 292 suites. So **the discriminator is not
`--filter` green vs full-package red** — that is the flake's own signature, not evidence about a
change. Run the full package at the BASE SHA, several times, and compare rates.

Left alone deliberately rather than half-fixed by widening the delay, which only moves the
boundary. The real fix is mechanism 5's: make the walk's progress a value the test controls — a
seam that lets it hold A inside the walk until the assertions have run — instead of racing 150ms of
wall clock. Worth doing when someone is next in this file; worth knowing about before blaming a
commit for it.

**Seen again at `ee66565e` (2026-09-02), and this one carries the cheapest discriminator yet.** Same
three assertions, same order. The commit touched `Modules/FileExplorer` and `MacApp` only — and the
decisive check is not that, but this: **`git rev-parse <base>:Modules/Sync` and
`git rev-parse <sha>:Modules/Sync` were the SAME TREE HASH.** The base had gone green an hour
earlier. Identical sources, green then red, so the change cannot be the cause and no local
reproduction is needed to say so:

```sh
[ "$(git rev-parse <base>:Modules/Sync)" = "$(git rev-parse <sha>:Modules/Sync)" ] \
  && echo "identical — this commit cannot have caused a Sync failure"
```

Use that first whenever a red lands in a package the commit does not touch: it is one command, it is
proof rather than inference, and it costs none of the reruns the paragraph above warns are the only
real evidence otherwise. A rerun of the same SHA then went green, with the machine quiet (loadavg
3.04, runner idle) — the fourth time this test has answered a rerun that way.

#### Seen: `ScanSupersedenceTests.testCancellingScanAbortsTheDiskWalkPromptly`, 2026-08-11

**FIXED 2026-10-25** (mechanism 40): the test now parks the walk inside entry 2 and counts the
entries handed out after the cancel, instead of timing the cancel against a 2 s budget.

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

**The cluster is wider than its gate users, and that matters for diagnosis.** The 2026-08-26
reproduction (22 runs, four red) also took down `ScanSupersedenceTests`, `FileSyncManagerFilingTests`
and `FilingBatchReentrancyTests`, none of which blocks a thread: the first misses a "cancel lands
within 2 s" budget, and the other two park on `parkUntilReleased`, a `Task.yield()` loop that holds
no thread at all and starves anyway because the pool it yields into is the one the gates have taken.
A member with no gate in it is collateral, not a second bug.

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

**Fix.** Applied 2026-08-26: a **park-thread budget** in
`Modules/Sync/Tests/Sync/TestSupport.swift`, and a `.parksAThread` / `.parksThreads(n)` trait that
every gated test declares. At most `activeProcessorCount / 4` threads' worth of parks are admitted
at once — 2 on this ten-core Mac — so the other eight pool threads are always there to carry the
releases. A reservation wider than the whole budget is admitted alone rather than deadlocking (the
six-wide hash window in `FileSyncManagerDuplicatesTests`, the four-worker rendezvous in
`BulkSyncCancellationAndReservationTests`), and the queue is FIFO so the widest reservation — the
one holding the most pool threads — cannot be overtaken by a stream of narrow ones and left to
reach its bound.

Measured on `main` at `b323ae94`, ten logical cores, no CI in flight — 22 full `Modules/Sync`
package runs before the change, 50 after:

| | Runs | Red | Wall clock | Load average |
|---|---|---|---|---|
| Before | 22 | **5** — four this mechanism (7, 9, 11 and 17 issues), one an unrelated `signal 11` | 12.21–12.91 s | 2.2–2.5 |
| After, quiet | 22 | **0** | 12.00–12.85 s | 2.2–2.5 |
| After, loaded | 28 | **0** | 12.36–24.69 s | 4.2–17.9 |

The loaded rows are worth more than the quiet ones, and were not planned: another session started
building in a second worktree partway through. Those 28 runs went green at up to **eight times the
load average the failing runs were measured at**, one of them taking 24.7 s to do it. This mechanism
is amplified by a busy machine without being caused by one — which is exactly why a red here has so
often been read as a bad commit.

The wall-clock column is why this is not `--no-parallel`: serialising the run cures this too, and
costs the parallel-execution coverage mechanism 3 depends on. Capping the parks costs nothing
measurable, because the budget only ever queues the two dozen tests that hold a thread.

**Why the budget, and not the three candidates this section used to list.**

- Raising the 10 s bound trades a false failure for a slower one and does not remove the starvation;
  it only moves the threshold, which is what the growing suite count will find again.
- `.serialized` on the gated suites bounds concurrency *within* each suite, not across them —
  twelve suites would still park together, already more than the pool has to spare. It also bills
  every test in those suites, and the gated ones are a minority: six of `AutoVerifyOnScanTests`,
  three of `VerifyAllWithChecksumTests`.
- **"Give the park a thread of its own outside the cooperative pool", which this section used to
  call the real fix, cannot be done** — and the reason is what forced the shape of what replaced
  it. The
  park's job is to hold a *synchronous* call in flight, so the thread it blocks is the one the seam
  was called **on**, and production calls those seams from `Task.detached`. Moving the *wait* onto a
  dedicated thread does not free the caller: it still has to not return. The same argument kills the
  obvious version of the budget — a seam call blocked queueing for a slot holds exactly the same
  pool thread as one blocked in the park. **The reservation has to be taken asynchronously, by the
  test, before the work that reaches the seam starts**, which is why it is a trait on the test
  rather than a change inside the gate.

**Nothing about `releasedByTimeout` changed, deliberately** — a gate that no longer engages and a
gate that engages and is released look identical from the outside, so "quietly stop the gates
engaging" is a change every suite would go green under. Mutation-tested rather than asserted:

| Mutation | What went red |
|---|---|
| `ParkGate.park` disabled outright | all 7 of its consumer tests, plus 2 in `ParkBudgetTests` |
| `FirstStatGate.gateIfFirst` disabled outright | all 9 of its consumer tests |
| the park signals `entered` but holds nothing | `aParkThatIsNeverReleasedRecordsItsTimeout` — **and only 1 of the 7 consumers** |
| the park stops recording its timeout | `aParkThatIsNeverReleasedRecordsItsTimeout` |
| a gated test drops its `.parksAThread` | `everyTestThatBuildsAThreadBlockingGateDeclaresIt` |
| a registered blocking sleep changes length | `everyThreadBlockingWaitInThisTargetIsAccountedFor`, both halves |
| the budget stops enforcing its width | 3 of the budget tests |
| the budget queue stops being FIFO | `aWideReservationIsNotOvertakenByNarrowOnesBehindIt` |
| the budget's give-up bound is removed | `aReservationThatCanNeverBeServedGivesUpAndSaysSo` |
| a give-up stops being reported as a test failure | `theGiveUpDefaultsToARealTestFailure` |

**Two of those rows are findings, not reassurance.**

- **A gate that engages but does not HOLD survives 6 of its 7 consumers.** `entered` is still
  signalled, so `awaitSignal` passes; `releasedByTimeout` is false, so the `#require` passes; only
  `testCancelDuringMoveCompletesInFlightItemAndSkipsRest` actually depends on the hold. That is
  pre-existing and was not introduced here, but it means the honesty this section credits to
  `releasedByTimeout` really comes from `awaitSignal(gate.entered)` catching a gate that never
  engages *at all*. `ParkBudgetTests` is what covers the weaker mutant now.
- **The FIFO and give-up mutants HUNG the run before they were made to fail it.** Both are fixed in
  the budget itself: the wait queue is an array of ids (a served-counter would strand everyone
  behind a reservation that gave up out of order), the wait is bounded and RECORDS its give-up, and
  it honours cancellation — `try? await Task.sleep` swallows the cancellation error, so without an
  explicit `Task.isCancelled` check the loop spins at full speed and a `.timeLimit` cannot stop it.

**Two ways this rots, both guarded by `ParkBudgetTests`.** A new gated test that forgets the trait,
and a new park primitive the trait's registry never hears about — the second scan is derived from
the source rather than from a list, so a new `DispatchSemaphore.wait`, a new blocking sleep, or a
longer `enumeratorDelay` anywhere in the target trips it. One hole is worth knowing: Swift itself
rejects `DispatchSemaphore.wait` in an async context, so the only place a new blocking park can
appear is inside a synchronous seam — which is exactly where the scan looks.

**See.** `Modules/Sync/Tests/Sync/TestSupport.swift` (`ParkGate.park`, `FirstStatGate`,
`awaitSignal`); mechanism 8 above for why the bound records its own expiry; mechanism 3 for the
other way suites-in-parallel decides a verdict.

#### Seen: `ProgressAccountingTests.testQueuedOperationDoesNotClobberRunningProgress`, 2026-08-25

Failed in a full `Modules/Sync` package run — **41.6 s, three issues in the one test** — and passed
in the next full run of the same commit, and in isolation. Three expiries at ~14 s apiece is this
mechanism's shape rather than a slow test: the bound is being reached, not approached.

`GatedFileManager` holds its in-flight copy and move on `DispatchSemaphore` (`copyGate`,
`moveGate`, parked in `park(_:)`), so each gated operation blocks a cooperative-pool thread while
the `waitUntil` that would release it needs a thread from that same pool. Under a package run the
pool is already spoken for, and this suite parks two at once.

**The remedy is already in the tree**, which is why this is worth recording rather than shrugging
at: `DuplicateBatchRedesignTests` parks an enqueued operation on a continuation-backed `Latch`
actor and cites this section in the comment above it. Nothing about `ProgressAccountingTests` needs
a semaphore — it needs the operation held, not a thread held.

**Settled 2026-08-26, and not by converting it.** The `Latch` shape does not apply here after all:
`ProgressAccountingTests` parks `copyItem`/`moveItem`, which `FileManaging` declares
non-`async`, so there is no await to hold the operation at — the reason the Fix section above gives
for why no gate here can stop blocking a thread. What it got instead is a declaration:
`testQueuedOperationDoesNotClobberRunningProgress` carries `.parksThreads(2)` (it is the suite that
parks two gates at once) and `testTrailingMoveOntoItselfSkipCompletesTransferProgress` carries
`.parksAThread`. The mutation test this paragraph asked for was written — see the table above.

**Where this is filed.** `v2.x` carries it too, written for that line — the suite is there unchanged,
but `DuplicateBatchRedesignTests` is not, so the remedy has to be written there rather than copied
from a neighbour. **`v3.x` does not have it, because `v3.x` has no section to file it under**: this
mechanism was never brought forward to that line, which that line's own register records as a
genuine gap, noting that `ParkGate` is used by six of its test files so the mechanism can fire there
exactly as it does here. So the entry is owed to `v3.x` only *behind* the section itself. Anyone
closing that gap should take this entry with it.

#### Seen: `DeepFolderIdentityTests.anUndoInvokedBeforeTheIdentityWalkResolvesWaitsForItInsteadOfNoOping`, 2026-08-25

Failed in `main`'s CI package run at `1aac1e18` (run 32905010113) — the one issue in a 2822-test,
256-suite Sync run, on a tip whose three new commits touch `Modules/Design` and docs only. The
test failed after **10.495 s** with `FirstAttributesGate.releasedByTimeout → true`: the 10 s bound
was reached, not approached, which is this mechanism's shape. A failed-jobs re-run of the same
commit passed clean the same day.

`FirstAttributesGate` is a new gate to this list but the same contract, and it says so in its own
doc comment: the mirror of `FirstStatGate`, gating the registration walk's first
`attributesOfItem` over the mock disk instead of `fileExists` over the real one. Its
`gateIfFirst()` parks `release.wait(timeout: .now() + 10)` on whichever thread the walk stat'd
from — a cooperative-pool thread under a package run — while the test's async side needs that same
pool to reach `fm.release.signal()`. Defined privately in
`Modules/Sync/Tests/Sync/DeepFolderIdentityTests.swift`, so a sweep of `TestSupport.swift`'s gates
will not see it.

The `#require(!fm.releasedByTimeout, …)` that failed is the honest-expiry check doing its job —
the held race silently un-held itself, and the test surfaced that instead of asserting against a
state it never held. Nothing about the test is wrong; it is one more semaphore-park added to the
same start-of-run thundering herd.

**Settled 2026-08-26** by the budget above: the test carries `.parksAThread`. The section's third
option — park on a thread outside the cooperative pool — turned out not to exist; see the Fix
section for why. The "a sweep of `TestSupport.swift`'s gates will not see it" hazard is now a
scan rather than a hope: `everyThreadBlockingWaitInThisTargetIsAccountedFor` reads every source
file in the target, so a gate defined privately in a suite is exactly as visible to it as
`ParkGate` is.

**Live instance, 2026-09-01 — `RestructureApplyGuardTests.theFlagIsHeldAcrossALiveLanding`.** The
same shape in a suite that owns its gate rather than borrowing `ParkGate`, which is why a search for
gate users would not have found it:

```swift
let arrived = await withCheckedContinuation { done in
    DispatchQueue.global().async {
        done.resume(returning: gate.entered.wait(timeout: .now() + 10) == .success)
    }
}
#expect(arrived, "the landing never reached its first disk probe")
```

A `DispatchSemaphore` with a 10 s bound, waited on from the global pool — the mechanism above,
exactly. The message is the honest half doing its job: it says the landing never arrived, which is
true, and says nothing about *why*, which is the machine.

**Measured across two arms on one afternoon, unchanged code at `ada033b7`:** 0/8 at loadavg 5–8,
and 1/5 under ten `yes` spinners with loadavg peaking at **70**. The same loaded batch also took
`ScanSupersedenceTests` twice (mechanism 5), `BulkOperationsTests`, `CopyMoveBehaviorPinTests` and
`DifferenceResolutionTests` once each, membership changing every run — the cluster signature this
section opens with, arriving in a package that has since grown well past the four suites named
above. **A member whose gate is private to its own suite is still this mechanism.**

**Settled 2026-09-06 — and the reason it had never been budgeted is a one-letter name.**
`GateFileManager` was not in `threadBlockingGates`; `GatedFileManager` was. The two differ by a `d`,
the list reads as though it already covers this one, and `everyTestThatBuildsAThreadBlockingGateDeclaresIt`
matches on those names — so it was passing while both of this suite's gated tests ran unbudgeted.
The fixture's own doc comment made the same mistake in prose, asserting the parked thread was
"never the pool: … the executor runs via `enqueueFileOperation`". That clause is the argument for
the opposite conclusion: `enqueueFileOperation` runs its operation in
`Task.detached(priority: .userInitiated)`, which **is** the cooperative pool. Both tests now declare
`.parksAThread`, the fixture is registered, and the test-side wait is `awaitSignal` rather than a
bespoke copy of it — which also anchors the expiry at the call site instead of at the helper.

Measured the way this section's own Fix section was, with the display held awake and `[ground-truth]`
reading `RAN` on all 52 runs, under ten `yes` spinners **and** a real `xcodebuild` on the same Mac:

| | Runs | `theFlagIsHeldAcrossALiveLanding` red | Load average |
|---|---|---|---|
| Before | 26 | **15** — every one at ~10 s, "the landing never reached its first disk probe" | 50–200 |
| After | 26 | **0** | 46–155 |

**The load recipe is the finding worth keeping.** Six package runs under ten spinners alone, at
loadavg up to 92, reproduced **nothing**; adding a real `xcodebuild` in a second worktree took it to
15 in 26. That is the same methodological point mechanism 17's correction makes from the other side:
spinners contend for CPU, a compiler contends for the queues and threads this process needs, and
only the second shape reaches a starvation this deep.

**A name is a weak key, which is the general lesson.** The derived scan
(`everyThreadBlockingWaitInThisTargetIsAccountedFor`) *did* see this gate's blocking waits and had
them registered as known — it just cannot know whether a registered line owes a reservation. The
list-based scan is the one that answers that, and a list matched by name is one typo from a hole
that reports itself as covered.

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

**A third shape, and it reddened `main`: a GROWING window.** A test that checks one entry, then two,
then three is asking its FIRST entry to outlive everything the rest of the run logs in between — so
the failure names the NEWEST assertion while the actual loss is at the oldest end, and reads as
though a line was never written. `BannerLogChokePointTests.everySeverityLogsAtItsOwnLevel` did
exactly this at `b96299f5`: it PASSED `[.info]` and then FAILED `[.info, .warning, .error]` three
lines later with `[.warning, .error]`, having lost only `.info` — the entry it had published itself.
Nothing was wrong with the choke point, and the message pointed at a log LEVEL rather than at the
logger. **Tell: the missing entries are the oldest, and an earlier assertion over the same marker
passed.** Fixed in `b895c3cd` (with `52242ad4` on `v2.x` and `c9c0beaf` on `v3.x`, where the suite
was byte-identical) by reading the window from the per-process file through `logLines(tag:during:)`
and checking levels **by name** — `INFO`/`WARN`/`ERROR` parsed out of the canonical line — rather
than by position in a window that can lose its front.

Two things worth copying from that fix. Asserting on the level NAME rather than on an index means a
lost line changes the sequence's contents instead of shifting everything left, so the next failure
of this kind says what went missing. And it was mutation-verified in three directions — flattening
every severity to `.info` fails all four tests, dropping the same-id dedup fails only
`reassigningTheSameBannerLogsOnce`, logging dismissals fails only `dismissalLogsNothing` — which is
what separates "the suite is green again" from "the suite still tests what it claimed to".

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

**Fix — read this before applying the four rules below.** They DIAGNOSE eviction; they do not
prevent it. Rule 1's marker is written *before* the lines it bounds, so it is the first thing the
buffer evicts: applying it turns "the line is missing" into "the window rolled", which is the honest
message and a **redder** test. Measured 2026-08-26 on `FilingRenamePassTests` — the full package
went from green to failing-with-a-better-message, and the change was reverted.

**Prefer `LogCapture` (`Modules/Events/Sources/EventsTestSupport/LogCapture.swift`).** It subscribes
to `Logger.shared.$entries` and accumulates at publish time, so a later trim cannot take an entry
away and there is no window to roll. A package test target depends on the `EventsTestSupport`
product and imports it; the app target's tests compile the file in instead, for the reason
`project.yml` gives. Construct it BEFORE the call under test — it is a window opening, not a query:

```swift
import EventsTestSupport

@Suite @MainActor struct MySuite {
    private let log = LogCapture()      // per test: Swift Testing builds a fresh instance for each
    @Test func theThingSaysSo() async {
        await manager.doTheThing()
        #expect(await log.holds(.warning, containing: "the thing went wrong"))
    }
}
```

`LogBufferReadScanTests` enforces this in every test tree — the app target's, each package's
`Tests`, and the `…TestSupport` libraries: a `Logger.shared.entries` read fails it unless an index
call bounds it within a few lines — a capture or a disk read elsewhere in the file no longer
excuses it, and neither does a comment. Sixteen suites predated `LogCapture` and sat on an
allow-list when the scan was written; a hand count had put them at nine, so do not estimate this
set, run the scan. The last fifteen were converted on 2026-09-27 and the list was deleted. It read
only the Sync tree until, the same day, `LogCapture` moved out of the Sync test target into
`EventsTestSupport` and the nineteen reads the app target, `Dashboard` and `FileExplorer` held
were converted with it.

The four rules below still apply where a capture is impossible (reading the disk log, or asserting
about lines written before your test began), and rule 1's *second* half — the awaited flush — is
needed by `LogCapture` too, for the visibility reason it gives.

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
   enqueued before it. **Enqueued** is the operative word: a line the code under test sends through
   `Task { @MainActor in Logger.shared… }` is not in the queue when the call returns, and the flush
   can finish without it — mechanism 26.

   **Measured 2026-08-17, as a pair, because this rule used to say only the first half.** A
   `@MainActor` probe applying the marker and the `#require` but no trailing flush **passed** an
   absence for a line its own call under test had just written. The identical probe with one awaited
   flush added **failed**, correctly seeing the line. A third — flush present, and 1100 filler lines
   rolling the window between the marker and the read — failed on the `#require` instead. The two
   guards are independent and both are load-bearing: the flush cannot see eviction, and the marker
   cannot see the queue. Every implementation in this repo already had the flush; it was the advice
   that had dropped it, which is why `loggedWindow(_:)` below keeps both.
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

#### The on-disk log — a better substrate, and why it is not a free win

**Measured 2026-08-22, in the order the mistakes were made, because the sequence is the lesson.**

Everything above operates inside `entries`, so every remedy is shaped by its 1000-line cap. There is
a second copy of the same stream with a far larger one: `Logger.shared.logFileURL`. It is the better
substrate for these assertions — the append is *ordered* at the call site, inside the `nonisolated
log(level:message:)` and before the flush task is returned, so the file preserves call order; and the
1000-line trim lives in `flushPendingEntries()` and touches `entries` alone, so nothing an
assertion's own window can outlive rolls it away at the sizes a test run reaches. Under a test runner
it is a per-process temp file (`sync-cloud-tests-<pid>.log`, see `defaultLogFileURL()`), so it is
scoped to the run and does not touch `~/sync-cloud.log`. A later test process sweeps it once its pid
is dead and it has gone an hour unwritten (`PerProcessTestFile`), so read a red run's log within
the hour.

**But you must DRAIN the writer before reading it, and this section used to say the opposite.**
It said the append happens "synchronously ... so the file ... needs no flush marker to become
visible". Only the *call* is synchronous. `LogFileWriter.append` is `queue.async` on a serial queue
declared **`qos: .background`** — so the write lands whenever the scheduler gets to it, and
background QoS is the first thing starved when the machine is busy (a parallel package run, or a
second session testing on the same Mac). `Logger.flushToDisk()` is `queue.sync {}`, which both
blocks until the queue drains and lifts it to the caller's QoS for the duration; its own doc already
said "blocks until the writer's queue drains, so a reader that needs to be sure". `logLines` and
`loggedLineOnDisk` now call it.

**Polling is not a substitute, and the measurement is the point.** The first cut waited for the
closing marker with `waitUntil` on the belief above. Measured over repeated full-package serial runs
of `Modules/Sync`: one run green, the next red on **two different tests**, each having polled
**250+ times** — five full seconds of genuine asking, so not a starved wait — with *both* markers
still absent. The pair moves from run to run because swift-testing randomizes order, so the victim
is whichever windowed test happens to sit behind the backlog. A poll cannot fix this because the
thing it waits on is priority-starved *by the waiting*; only `sync` donates the priority that clears
it. **Tell for this one: both markers missing and a high poll count.** Both markers missing with a
LOW poll count is the starved-wait mechanism instead, and both markers missing with the log near
5 MB is the trim, below.

**"The file never rolls" is what this said, and it is wrong** — corrected 2026-08-23, by reading
`LogFileWriter` rather than reasoning from `entries`' trim living elsewhere. The file has a cap of
its own: `LogFileWriter.defaultMaxFileSize` is **5 MB**, re-checked every `trimCheckInterval`
(= `min(1 MB, maxFileSize / 2)`) bytes appended, and `trimTailIfOversized` keeps the TAIL — it
discards the oldest lines, which is precisely where a `logLines(tag:)` window's OPENING marker sits.
The claim was asserted from the absence of a trim in the path being replaced, never grepped in the
writer; it is the exact failure the release-notes rule names, *a sentence about how the code is
structured needs the same grep as one about what it does*.

**Why it has not bitten, and what would make it.** Measured across this machine's test logs: the
largest full-package serial run writes **~583 KB**, an order of magnitude under the cap, so no trim
fires and the substrate behaves as the paragraph above describes. What would change that is volume,
not time — roughly a 9× growth in logged lines per run, or a suite that logs in a loop. If a
`logLines` assertion ever fails with **both** markers absent, check the log's size against 5 MB
before reaching for anything else, and remember the writer's own documented residual: an append that
lands on the orphaned inode during a trim's atomic rename is lost outright, so a trim can eat the
CLOSING marker too and leave the wait to expire.

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
  `#expect(!(await loggerContains("User triggered Redo: Delete 1 Item")))`. Same shape, helper
  `loggerContains(_:)`. Its siblings in that same test are presence assertions, so a roll would fail
  *those* loudly while `:40` passed for free — the asymmetry inside one test.

`SyncCloudTests/ContentSignalExtractorTests.swift` used to head this list: `9da161d8` gave it a
bounded window. All three now read a `LogCapture` instead — the two above since 2026-09-27, and
`ContentSignalExtractorTests` with the rest of the app target's log suites the same day.

**Model implementations** of the four rules, for where a capture will not do, in the order worth
copying. Cited by **symbol**, deliberately: two of the line ranges this list used to carry were
correct when written and silently wrong a commit or two later, once a sibling inserted a helper
above them. A file whose whole value is being checkable cannot afford citations that rot without
saying so — `grep -n` costs the reader nothing.

- `loggedWindow(_:)` in `Modules/Sync/Tests/Sync/PaneTabsTests.swift` — the two-marker helper,
  with both halves (presence and absence) read through it and both of rule 1's guards: the opening
  marker `#require`d, the closing one awaited as the flush. It returns `ArraySlice<LogEntry>` so the
  level can be asserted too, and computes each index *before* the `#require` so a failure prints an
  index rather than 152KB of dumped buffer.
- `wideningAOnePaneRefreshSaysSo` in `Modules/Sync/Tests/Sync/LoggingGapTests.swift` — why to read
  at the decision rather than at completion, which is rule 3 and the one that is easy to talk
  yourself out of.
- `logLines(tag:during:)` in `Modules/Sync/Tests/Sync/TestSupport.swift` — the same two-marker
  window read off the on-disk log instead of `entries`, for assertions that cannot survive the
  1000-line cap; see the subsection above for what it does *not* close, including the 5 MB cap the
  file has of its own (this line used to call it "uncapped").

**This mechanism has a different number on each line, so cite it by name.** It is **12** here, 11 on
`v2.x` and 10 on `v3.x`, because the three registers accumulated different entries before it. Write
"the rolled log window" — a bare number goes stale the moment a text is cherry-picked between lines,
and a commit on `v2.x` already refers to that line's entry by this one's number.

**See.** `f87d9e11` — *Account for a rollback and a widening the log could not explain* (where it was
first measured); `flushPendingEntries()` in `Modules/Events/Sources/Events/Logger.swift` for the cap
itself.

#### Seen: `DuplicateBatchRedesignTests.batchRefusalsAreLoggedPerGroupWithKeeperAndCopyPaths`, 2026-08-25

Red on CI (`main`, run 32869408710), green on the re-run, and green in isolation three times for
three. In two subsequent full local package runs it stayed green while each run failed a *different*
set of other tests, so the victim moves with the load rather than with the code. The commit it failed on changed nothing in
`Modules/Sync` or `Modules/Events`: `git diff <parent>..<sha> -- Modules/Sync Modules/Events` is
empty, and Sync's only package dependency is Events, so the failing binary was byte-identical to the
one that had just gone green.

The tell is the shape of the failure, not that it failed. The test makes **two** `#require`s on two
refusal lines written by the **same** call, and the first passed while the second returned nil.

**Four candidate mechanisms ruled out, so the next reader does not re-derive them:**

- **Not the 1000-entry cap.** The production code logs the drifted group's refusal before the
  no-baseline group's (`FileSyncManager+Duplicates.swift`, in that order), so the line that
  *survived* is the OLDER of the two and the trim drops oldest first. The cap predicts the exact
  opposite of what was observed.
- **Not the 5 MB file trim** described above: this suite's `loggedLine(containing:)` is a private
  copy that reads `Logger.shared.entries`, not the file.
- **Not the shared-fragment collision** of the leaked-suites mechanism: both fragments are scoped by
  a per-run `token`, so no other suite can write them.
- **Not the `minimumLevel` gate silently voiding the flush marker.** That was the promising one —
  `log()` returns a bare `Task {}` for a filtered level, which would make the helper's
  `await …debug(…).value` barrier a no-op and the read a straight race. It does not apply: under a
  test runner `persistedMinimumLevel` forces `.debug` regardless of the machine's stored setting,
  `MinimumLevelBox` defaults to `.debug`, and nothing in this target raises it (`UndoDriftIdentity-
  Tests` says so in a comment of its own).

**So the residual is unpinned and this entry says so** rather than picking the nearest story. What
is established is the substrate: six suites in this package carry a private `loggedLine(containing:)`
reading `entries`, while `loggedLineOnDisk(containing:)` and `logLines(tag:during:)` exist a few
hundred lines above precisely because the file is the better one and drains its writer first. Anyone
returning to this should start by converting this helper and seeing whether the failure survives —
that is a cheap experiment with a documented destination, and it is the one nobody has run.

**Main-only.** `DuplicateBatchRedesignTests` exists on neither maintenance line, so an entry naming
it is one a `v2.x` or `v3.x` reader cannot act on.

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

### 17. The control that stops an absence being vacuous is itself load-dependent — FIXED

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

**Fixed, 2026-08-23, after a third occurrence** (`samples → 19` in main run `32660175614`, again
one-to-two short of the floor with everything substantive green). The fix is a **rendezvous**: the
fixture's slow trash raises an `inTrash` flag around the trash call and does not return until the
sampler acknowledges having taken a sample while the flag was up (bounded by a deadline so a wedged
sampler fails the test rather than hanging the pool thread). The premise assertion is now "a sample
was taken while the merge was suspended inside its trash operation" — the very thing the count was
approximating — and no longer mentions a count at all. Two properties worth copying: the evidence
is produced by the code under observation, so **throughput** cannot shrink it below the floor; and
the suspension now lasts exactly as long as it needs to be observed, so the healthy case got
*faster* than the fixed 0.3 s sleep it replaced.

**Corrected 2026-09-01 — the fix traded a throughput bet for a LATENCY one, and the residual is its
own deadline.** This section said "no amount of load can shrink it below the floor". That is true of
the *count* and not of the rendezvous: the trash side gives up after a **10 s wall-clock deadline**
and returns unacknowledged, so `sampledDuringTrash` is false and the premise assertion fails exactly
as its predecessor did, with every substantive assertion still green.

```swift
let deadline = Date().addingTimeInterval(10)
while !sampledDuringTrash.withLock({ $0 }) && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.01)
}
```

The bound is not a mistake — without it a wedged sampler hangs a pool thread, which the comment says
and is right about. What is wrong is only the claim above it: **a bounded rendezvous still bets that
the other side gets scheduled inside the bound**, and the other side here is the *main actor*. Ten
seconds of main-actor starvation is not a normal machine, but it is a reachable one — this was
observed on 2026-08-31 in a full `Modules/Sync` run at loadavg 20–42, with another session's
`xcodebuild` compiling on the same Mac.

**Not reproduced under synthetic load, and that is a methodological point rather than a doubt.**
Five full-package runs under ten `yes` spinners (loadavg peaking at 70) did not reproduce it, while
the same batch did reproduce `theFlagIsHeldAcrossALiveLanding` — see mechanism 10. `yes` contends
for **CPU**; it does not contend for the **main actor**, and the main actor is what this sampler
needs a turn on. A compile does, because the toolchain's own work lands on queues this process's
main thread competes with. So when validating a main-actor-latency failure, load the machine with
*work of the same shape* — a real build or another test process — rather than with spinners, which
the triage card's recipe is otherwise right to prefer for CPU-bound timing.

**Repaired 2026-09-06, and the residual is gone rather than widened.** The trash no longer polls
and no longer waits on the sampling loop at all: it puts one main-actor observation on
`DispatchQueue.main` — the main actor's own executor, so a block running there reads exactly what
another main-actor task would — and waits on the semaphore *that observation* signals. The wait now
ends when the observation happens, and what it depends on is the main queue running one
already-runnable block, not a `Task.sleep` timer whose wake-up is delivered through the cooperative
pool.

**Two bounds were live, not one, and the section had only named the first.** Besides the trash's
10 s deadline, the sampling loop carries a **30 s** deadline of its own, and a loop that has exited
can acknowledge nothing — so a merge slow enough to outlast it failed the premise by a second route.
Measured 2026-09-06 under ten `yes` spinners **and** a real `xcodebuild`, 26 full package runs put
this test at **8–29 s**, once within **1.4 s** of that deadline. After the repair, 26 runs in the
same band: **15.6–20.5 s**, so the headroom went from 1.4 s to 9.5 s — and, more to the point, the
premise stopped depending on that deadline at all.

**Proved structurally rather than by the timings**, because the timings only narrow a window:
setting the sampling loop's deadline to **zero**, so it takes no sample whatever, is a pass in
0.235 s on the repaired code and a premise failure at **10.275 s** — the wall-clock bound, exactly
the documented shape — on the pre-repair code at `c2a16d04`.

**The vacuity control was strengthened, not relaxed, which is the constraint this section exists
to state.** The premise's evidence is now the *reading itself* (`levelDuringTrash`, an optional Int)
rather than a boolean set beside it: a rendezvous that still signals but has stopped reading
anything leaves nothing behind and goes red. The old flag survived that mutation, because the
sampling loop set it next to the sample rather than out of it. Mutation-tested, each restored after:

| Mutation | What went red |
|---|---|
| the observation is never enqueued | the expiry flag **and** the premise, at the 10 s bound |
| it is enqueued and signals, but reads nothing | the premise alone, in 0.24 s — the mutant the old flag survived |
| the undo group is held open across the trash suspension | the substantive assertion, `level → 1` |
| the sampling loop's deadline goes to zero | nothing — and that is the repair |

One more thing this uncovered: `SamplerObservedTrash` blocks a **cooperative-pool** thread for the
length of its rendezvous — the merge reaches that seam through `enqueueFileOperation`, which runs
its operation in `Task.detached` — and neither the fixture nor its test had ever said so. It carries
`.parksAThread` now, and the fixture is registered in `ParkBudgetTests.threadBlockingGates`; see
"Every gate parks at once, on the pool their releases need".

[silent-half]: flaky-triage.md#the-silent-half--read-before-writing-any-absence-assertion

### 18. A named NSPasteboard is machine-global, so two test PROCESSES share it

**Symptom.** A pasteboard assertion fails with a value from a fixture **this process never
created** — the diff's actual side names a temp path whose UUID belongs to no directory this run
made. Fails only when two test processes overlap on the machine: CI beside a local `swift test`,
or two worktree sessions. Measured once either way it is gone; re-running alone always passes.

**Mechanism.** `NSPasteboard(name:)` resolves in the **pasteboard server**, not in the process:
every process on the machine asking for `"SyncCloudTests.handoff.owned-theirs"` gets the *same*
board. The suites here already learned the in-process half of this — one board per test, because
parallel siblings interleave — but a fixed per-test name still collides with the same test running
in another process. This machine makes that overlap ordinary: it is the CI runner *and* the
development box, so "CI red while a local run was in flight" is the signature. First caught
2026-08-23 in main run `32660175614`
(`aCompletedCutDoesNotClearSomebodyElsesClipboard`): the board held `theirs.txt` from another
process's UUID-stamped temp directory.

**Fix.** Suffix the board name with `ProcessInfo.processInfo.processIdentifier` — per-test label
for the siblings, pid for the neighbours. All three test pasteboard helpers here carry it now
(`SystemClipboardTests` ×2, `FileActionHandlerOperationTests.scratchPasteboard`); any new one
must. `clearContents()` at the top of a test defends against nothing across processes: the other
process writes *after* you clear.

**The general rule** is mechanism 3 one ring out: defaults suites, pasteboards, Keychain items,
and anything else brokered by a system daemon is shared across every process on the machine, and
a per-process suffix is the only isolation that holds when this machine runs CI and a session at
once.

**The standard defaults domain is one of these — measured 2026-10-15.** Under `swift test`,
`UserDefaults.standard` is not the test's own: it is the domain named `swiftpm-testing-helper`
(`defaults find <key>` shows it), one plist brokered by `cfprefsd` for every helper process on the
machine. "Process-wide state, and suites running in parallel" says to prefer a scratch suite to the
standard domain; this is why that holds *across* processes too, where `.serialized` and a
save-and-restore `defer` do nothing. `EditorTextSettingsTests.theTextsFormatBarItemFlipsTheSettingAndSaysSo`
was 0/10 alone, 3/20 with a second process running `defaults write swiftpm-testing-helper
editorShowsFormatBar` in a loop, and **17/40 in each of two helper processes running its suite
at once**. `EditorReadableColumnTests.theEditorAppliesTheSwitch` went red the same way on CI.
**The tell:** a toggle fails twice, on the value *and* on the log line it writes, because the
sentence follows whatever the toggle read, so the log failure is a knock-on and not a second bug.
**Fix:** a `ScratchDefaults` per test, handed to the code through a seam
(`PlainTextEditor.Coordinator.defaults`) and to a hosted view through `.defaultAppStorage`. **A view
read outside any hierarchy ignores `.defaultAppStorage`:** `EditorHeaderDoorsTests` renders
`headerContent` off a bare `EditorWorkspaceView`, whose `@AppStorage` then falls back to the standard
domain, so the store goes in explicitly through `readingSettings(from:)`. After
the fix: 0/40 and 0/40, and with both suites in each process and a writer flipping all four keys
they use, 0/30 and 0/30. A mutant whose `validateMenuItem` read `.standard` again failed 59 of
those 60. To
reproduce, launch `swiftpm-testing-helper` directly (two `swift test` runs on one scratch path take
SwiftPM's lock and run one after the other), with the two library paths `swift test` would set,
after `swift build --build-tests`:

```sh
H=$(dirname $(xcrun --find swift))/../libexec/swift/pm/swiftpm-testing-helper
X=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
D=$PWD/Modules/Dashboard/.build/out/Products/Debug; BIN=$D/DashboardTests.xctest/Contents/MacOS/DashboardTests
DYLD_LIBRARY_PATH="$D:$X/usr/lib" DYLD_FRAMEWORK_PATH="$X/Library/Frameworks:$X/Library/PrivateFrameworks" \
  "$H" --test-bundle-path "$BIN" --filter FileActionHandlerTests "$BIN" --testing-library swift-testing
```

**The last four package suites that wrote it moved
the same way, also 2026-10-15:** Dashboard's `FileActionHandlerHelperTests` (the handler's own
`defaults`, through `PaneLinkPreference.isLinked(in:)`; its settings followed on 2026-10-16,
below), Events' `LoggerLevelGateTests` (a scratch suite named as the ambient store in
`persistedMinimumLevel(from:ambient:)`), and FileExplorer's
`FilingRefineControlTests` and `FilingRefineRouteCostTests` (one suite as the manager's
`filingContentDefaults` and the lens's `.defaultAppStorage`). Under two helper processes the old
tests failed 19 runs in 60 (Dashboard) and 18 in 40 (FileExplorer); after, 0 in 60 and 0 in 40.
`LoggerLevelGateTests` failed 0 in 60 either way: its read cannot lose the race, so it was a
writer reaching other processes rather than a victim.

**The last writes went 2026-10-16, through code the tests drive.** The shared plist is no
evidence of who writes it: every process on the machine adds to it, a worktree on an older base
included, and nothing ever removes a key. **Give the run a domain of its own instead.** The
standard domain is named after the process, so a copy of the helper under another name gets one:
`cp "$H" <dir>/probe-dashboard`, launch that copy in place of `$H`, and
`defaults read probe-dashboard` lists what that run wrote and nothing else. Every package's
swift-testing run went through it, as did Design's XCTest half (a copy of `xcrun --find xctest`)
and SyncCloudCLI's two bundles. Two writers were left:

- Dashboard's `FileActionHandlerTests` built a bare `SettingsManager()`, whose discovery pass
  wrote the real `~/Library/CloudStorage` accounts to `lastKnownAccountFolders`. Its settings now
  come from `autoDiscover: false` on a `ScratchDefaults`. Measured by mutation, either half alone
  stops the write; only `SettingsManager()` itself brings it back.
- FileExplorer's `aStyleChangeFromAppKitLeavesTheTextAlone` sends `changeColor` through the real
  text view, and `NSTextView` reads the colour from `NSColorPanel.shared` **whatever the sender**,
  so the door creates the panel and AppKit saves its geometry into the standard domain under three
  `NSColorPanel` keys. AppKit offers no store to inject, so the test removes every
  `NSColorPanel` key afterwards (`forgetTheColorPanelsGeometry`). Without that `defer`, or with
  the name match misspelt, all three keys come back.

`differencesGroupByFolder`, `listDensity`, `editorShowsFormatBar` and
`editorEditsInPreviewIntroSeen`, all still in the shared plist, were written by **no** test on
`main`: they predate the moves above, or come from a worktree on an older base. `spellMountProbeMarker`
was a probe that never landed. After the fix, every probe domain is empty or absent. Under two
helper processes sharing the real domain, `FileActionHandlerTests` passed 40 runs in 40 and
`PreviewEditorViewTests` 16 in 16.

**One reader was left, and moved 2026-10-16 too.** `FileActionHandlerHelperTests` gave the
handler a scratch suite on 2026-10-15 but still built its `SettingsManager` on the standard
domain. It wrote nothing, so the probes above could not see it, but its provider seed read
whatever `lastKnownAccountFolders` and root overrides other runs had left: six real accounts,
under a comment saying "seeded iCloud provider only". Its settings now come from a
`ScratchDefaults`, as `FileActionHandlerTests`' do. Measured with saved builds under renamed
helpers, 10 runs per cell: on an empty probe domain old and new both passed 10 in 10. With one
account (`/tmp/hostile/OneDrive-Hostile`) and a root override putting it at
`~/Library/Mobile Documents`, old failed 10 in 10 (`"\(root)Extra"` named the account instead of
"other pane") and new passed 10 in 10. The account list alone cannot do that: an account's root
ends in its own folder name, so it never sits above iCloud's. It takes the override beside it.

### 19. `Task.yield()` assumed to park a test inside an async window — a VACUOUS green, not a red

**Symptom.** There isn't one, which is the entry's point. A test that starts an async operation,
yields once "to land inside" it, then mutates state and asserts the operation reconciled — passes
whether or not it landed inside anything. Nothing goes red, in isolation or in a full package run,
because the assertions are also satisfied by the operation finishing FIRST and reaching the same
rows by a different route.

**Mechanism.** `Task.yield()` enqueues the test's continuation on its actor, and the operation
suspends on work that resumes at a **different priority** — in
`FileSyncManager.applyFilters()`, `Task.detached(priority: .userInitiated)`. Under a loaded suite
that continuation can overtake the yield's, so the whole pass runs to completion before the test's
next line. Caught 2026-08-26 only because P9 added `reconcilePassesRun`: the counter read **0** in
a full-package run for two tests written to exercise the reconcile pass, while both passed in
isolation and both passed on their row assertions in the same failing run.

**Tell.** A test whose whole subject is "what happens when X moves mid-flight" and whose assertions
would also hold if X moved *before* flight. If nothing in the test can distinguish the two, it is
not testing the window.

**Fix.** Verify the window instead of assuming it, using an observable that moves the instant the
operation commits — `lastPublishedFilterGeneration` here. Start the operation, yield, and check
that observable has not moved; if it has, the window was missed, so drain and start another. When
it has not moved the operation is still suspended, and it cannot proceed until the test suspends
again — so everything the test does before its next `await` is inside the window, deterministically.
`InFlightSyncStateTests.filterPassParkedInsideItsCompute` is the worked example; a bounded retry
that throws beats a comment claiming the yield was enough.

**The general rule:** a counter that makes the fast path observable is not bookkeeping. Two tests
here had been green and vacuous for as long as the reconcile pass existed, and the only thing that
ever saw it was a counter added for an unrelated reason.

### 20. The display fell asleep mid-batch, so a suite left the denominator — a VACUOUS green

**Symptom.** There isn't one, again — a run that was red goes green partway through a repeated
batch, on unchanged code, and the obvious reading is "the flake rate is low". What actually happened
is that a **gated suite stopped running**, so the thing that was failing is no longer being asked.

Measured here, 2026-09-01, while establishing a flake rate on `Modules/Sync`:

| Arm | Runs | `thePersonAndLifecycleAxesAgree` |
|---|---|---|
| idle, loadavg ~5–8 | 8 | failed **8/8**, identical value each time |
| under CPU spin, loadavg → 70 | 5 | failed run 1, then **absent from runs 2–5** |

Counted naively that is **9 failures in 13 runs**, and the natural conclusion is a failure that is
load-*sensitive* and clears about a third of the time. The true rate is **9 in 9** — the other four
runs never asked the question. The conclusion is the exact opposite of the truth: this failure is
entirely deterministic. What changed was the **display**: `FolderSurveyGroundTruthTests` is `.machinePinned` behind a gate that needs a live
profile *and* an awake display, because an iCloud walk makes no progress against a sleeping one. The
batch ran long enough for the screen to sleep, and from that moment the suite skipped.

```
[ground-truth] SKIPPED — the display is asleep; an iCloud walk makes no progress,
so the survey rules were not checked against a real tree
```

**Mechanism.** Any gate whose input is *ambient machine state* can change its answer between two
runs of a batch that is otherwise controlled. The display is the one that bites here because it
sleeps on a timer measured in minutes and every load experiment in this file is measured in
minutes. Nothing in the run output says a suite left: a skipped test is not a failure, and
"0 issues" is what a green run says too.

**Why it is filed beside the other vacuous-green entries rather than with the load mechanisms.** It
produces no red at all. It corrupts the *denominator* of the very comparisons
[flaky-triage.md](flaky-triage.md) prescribes — "run the old source under the same conditions",
"compare rates" — and it corrupts them in the direction of making a real, constant failure look
intermittent, which is the worst direction for this file's purpose.

**How to not be fooled.** Read the gate's verdict rather than the issue count, every time you
compare runs:

```bash
arch -arm64 swift test --package-path Modules/Sync 2>&1 | grep -oE '\[ground-truth\][^"]*'
# want RAN on every run of the batch, or the runs are not comparable
```

To hold a long batch open, wake the display and **keep** it awake — `caffeinate -u` alone only
prevents sleep and a short `-t` expires mid-batch, which is how this happened:
`nohup caffeinate -u -t 3600 &`, run the batch, then `pkill caffeinate`. The same discipline the
release checklist already asks for when it wants a `RAN` out of this suite; it applies to every
measured comparison, not just to a cut.

**The general rule, and it is the same one mechanism 19 states from the other side:** before
comparing two runs, establish that they asked the same questions. A suite that stops running is
indistinguishable from a suite that started passing, in every output this repo produces.

### 21. An OS upgrade repealed a framework convention a test had pinned — a red about no commit at all

**Symptom.** Two `FileExplorer` tests went red on 2026-09-16 and stayed red, on the commit in front
of you and on every commit behind it. They fail in **~2s under `--filter`**, on an idle machine, in
a fresh worktree with no local changes — none of the load tells in this file apply, and rerunning
changes nothing:

```
✘ PaneColumnsScrollTests.testTheMountedStackScrollsNatively — PaneColumnsScrollTests.swift:165
  (type(of: stack.contentView) → HostingClipView) == (NSClipView.self → NSClipView)
✘ PDFPreviewMountedTests.testTheWholeDocumentIsScrollable — PDFPreviewMountedTests.swift:221, :224
  (before → 0.0) > (visible → 792.0)
  (documentVisibleRect.origin.y → 0.0) < (before - 1 → -1.0)
```

**Mechanism.** This Mac moved to **macOS 27.0 (26A428)** on 2026-09-15, and two framework
conventions the assertions had pinned as facts moved with it. Neither is documented as a promise;
both had simply been true for as long as anyone had looked.

- SwiftUI now hands a `ScrollView`'s scroll view its own **`HostingClipView`** subclass, where it
  used to leave a plain `NSClipView`. The assertion read `type(of:) == NSClipView.self`, but the
  question it existed to ask was *"is OUR `BoundedElasticClipView` swap back?"* (`60fd18f` /
  `7021b28`). "Not exactly `NSClipView`" and "swapped by us" had been the same sentence only by
  coincidence, and the upgrade separated them.
- PDFKit now lays its pages out in a **flipped** document view. Measured on the mounted preview:
  `isFlipped=true`, content 4008pt, viewport 792pt, and the document **opens at originY 0.0**. The
  test assumed the old bottom-up layout, where the top of the document was the scroller's
  *maximum* and the way forward was toward zero — so on a preview working perfectly it asserted
  the viewport had not opened where it should, then scrolled the wrong way.

**Neither app behaviour actually changed.** The stack's elasticity is still configured as SwiftUI
sets it (horizontal `.allowed`, vertical `.none`) and no product file defines an `NSClipView`
subclass anywhere in the seven packages. The PDF preview still reaches the whole document:
`goToLastPage` lands at **originY 3211.03 of a 3216pt legal band** with page 5 under the viewport,
and driving the clip view to the measured far end does the same. Only the coordinate convention and
the class name moved.

**Tell — three checks, in this order, and all three are cheap.**

1. **Does it fail on a commit that was green?** Check out an older tag in a detached worktree and
   run the same `--filter`. Here both failed identically at `ed01247e`, which CI had passed on
   09-09. A red that predates the commit in front of you is not about that commit.
2. **When did CI last agree?** `gh run list` showed green through 09-09 and red from 09-16 —
   with the OS upgrade between them, and nothing else.
3. **Is the failing value a framework's class name, coordinate origin, or ordering?** Those are
   conventions, not contracts. An assertion that names one is pinning an observation.

**Fix — restate the claim in something the framework still answers, and never in its incidental
shape.** Ask *whose* the clip view is rather than *which class* it is: `Bundle(for:)` on it against
`Bundle(for:)` on a class this module defines says "ours" without caring which subclass the
framework picks next, and it does not move again on the next upgrade. **Measure** the far end of a
scroll off the laid-out views instead of assuming which numeric end it is
(`farEnd = abs(opensAt - span) > abs(opensAt) ? span : 0`), and assert what the reader can see —
"the LAST page is under the viewport" — rather than "the origin moved". Mutation-tested both ways:
with the preview forced to open at the last page the measured far end correctly flips to 0 and the
assertions still hold.

**Do not simply widen the assertion to accept both.** A `type(of:) == NSClipView.self ||
isKindOfClass` would have gone green and stopped detecting the swap it exists for — which is what
the provenance check was mutation-tested against (a faithful clone of `7021b28`'s clip view
reinstalled in `resolveAndObserve`; the provenance assertion fires on it).

**What the sharper assertion bought.** The old scroll check was `origin.y < before - 1` — *any*
movement. Under a paged-display-mode mutation the viewport travels **18.999pt**, which that
assertion accepts; `pageUnderViewport == pageCount` and `abs(travel) > visible` both catch it. The
OS forced the rewrite, and the rewrite closed a hole that had been open the whole time.

**Read the page under the viewport, not `PDFView.currentPage`.** Measured at the far end of the
fixture: `page(for:nearest:)` at the middle of the view reports **5**, `currentPage` still reports
**1**. It is maintained on PDFKit's own cadence, not the clip view's, and would have made either
assertion lie in whichever direction the stale value pointed.

### 22. A probe gated on a notification measures nothing unless it waits for delivery — a VACUOUS green

**Symptom.** None, which is the point — and it was found only by mutation-testing the fix for
mechanism 21. A probe that posts `NSScrollView.willStartLiveScrollNotification` and then
immediately asks the clip view to constrain an out-of-bounds rect passes against a **faithful
clone of the very swap it names**. Four live-phase assertions, zero of them fire.

**Mechanism.** The machinery being pinned gated its slack on an observer registered with
`queue: .main`. Those blocks are **enqueued**, not run inside `post`, so the synchronous probe
immediately after reads a clip view that has not yet been told a gesture started — it answers as if
at rest, which is exactly the phase that clamps cleanly. Measured against the clone: probing
immediately fires **0 of 4**; probing after delivery fires **4 of 4**, with the four resting probes
still passing, which is the gating the probe exists to detect.

**Tell.** A test that posts a notification (or sets state read by an observer, or an
`OperationQueue` hop) and asserts on the next line, with nothing between the post and the read that
could only happen after delivery. Same family as mechanism 19: the assertions hold whether or not
the window was ever entered.

**Fix — a positive control on delivery, not a sleep.** Register your own observer **last** on the
same notification and object; notification blocks are enqueued in registration order on the one
queue, so when yours has run any earlier one has too. Pump until it has, and **`#require` it** so a
delivery that never happens is a labelled failure rather than a silent measurement of nothing:

```swift
var delivered = false
let token = NotificationCenter.default.addObserver(
    forName: NSScrollView.willStartLiveScrollNotification, object: stack, queue: .main
) { _ in MainActor.assumeIsolated { delivered = true } }
defer { NotificationCenter.default.removeObserver(token) }
NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: stack)
// ...pump until `delivered`, then:
try #require(delivered, "the notification was never delivered — the probe below would be vacuous")
```

A fixed `pump(window, seconds: 0.2)` also works on an idle machine and is the wrong fix: it is
mechanism 2's shape, and when it is short the probe goes quietly inert again rather than red.

**The general rule:** if the phase under test is entered by someone else's callback, the test has to
observe that it was entered. Posting the notification is not entering the phase.

### 23. A snapshot mismatch that aborts the process instead of failing — a red with no verdict

**Symptom.** `swift test` on a package with a snapshot suite dies with `exited with unexpected
signal code 6` and **no Swift Testing summary at all** — no `Test run with N tests`, no `✘`, no
name. Every other suite in the package is lost with it. The last tests to report are whatever
happened to run before the snapshot suite, which points at the wrong place. Seen 2026-09-16 on
macOS 27.0 in `Modules/Design` and `Modules/Settings`, at `origin/main` in a clean worktree:

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException',
    reason: '-[NSConcreteValue CGRectValue]: unrecognized selector sent to instance …'
  5  CoreImage   -[CIReductionFilter offsetAndCrop]
  6  CoreImage   -[CIAreaAverage outputImage]
  8  DesignPackageTests  CIImage.applyingAreaAverage (SnapshotTesting)
  9  DesignPackageTests  SnapshotTesting.perceptuallyCompare(…)
```

**Mechanism.** Two things, layered, and only the second is SnapshotTesting's.

- **Any image that is not byte-identical takes the perceptual path.** Not only a real mismatch:
  ordinary anti-aliasing jitter — the thing `perceptualPrecision: 0.98` exists to absorb — goes
  there too. Measured: `DesignSnapshotTests.tokenChipsRowActive` and Settings' only snapshot both
  *pass* once the compare can run, and both aborted before it could.
- **On that path SnapshotTesting hands CoreImage a bare `CGRect`** for `CIAreaAverage` /
  `CIAreaMaximum`'s `inputExtent` (`UIImage.swift`, `applyingAreaAverage`). Swift bridges it to an
  `NSValue`. CoreImage documents the key as a `CIVector`, and on macOS 27 its reduction filters ask
  for `-CGRectValue`, which `CIVector` answers and a macOS `NSValue` does not — AppKit spells it
  `-rectValue`. An uncaught ObjC exception cannot be turned into a test issue, so the process goes.
  Still the code in 1.19.5 and on SnapshotTesting's `main` as of 2026-09-16; no upstream issue.

**Why CI did not see it.** Every snapshot suite is `.machinePinned(.referenceImages)` and CI skips
that reason. A green CI run says nothing about any of them.

**Tell.** Signal 6 with no summary line, and `CIAreaAverage` / `perceptuallyCompare` in the
crashing thread. Distinguish it from the Sync abort in the parallel-start window (no ObjC exception,
uniform ~4 s durations): this one names its exception on stderr, and it reproduces every run, idle,
under `--filter <Suite>SnapshotTests`.

**Fix.** `installPerceptualCompareShim()` in `SnapshotRendering.swift` — all four copies, called
from `assertViewSnapshot`, the one funnel every snapshot goes through — gives `NSValue` the missing
selector, answering with its `rectValue`. It is additive (`class_addMethod` never replaces) and
guarded, so it does nothing where the selector already resolves. Delete it once the pinned
SnapshotTesting passes a `CIVector`.

`SnapshotPerceptualCompareTests` (Modules/Design, **not** machine-pinned, so CI runs it) drives the
strategy on images whose difference is painted pixel by pixel and pins the numbers it reports, not
just the absence of a crash. Mutation-tested: shim disabled → the same abort; the shim answering a
half-width, half-height or offset extent → a named red. The first version painted whole rows and a
half-width extent **survived** it — rows spread the change evenly across x, so a wrong width still
averages to the right fraction. The changed pixels are a corner block now.

**What it had been hiding.** The same macOS 27.0 upgrade as "An OS upgrade repealed a framework
convention a test had pinned", reaching the pixels instead of a class name. Once the compare could run, four `DesignSnapshotTests` EmptyState
scenarios failed in both appearances at a perceptual precision of 0.46 — which, as the Dashboard
timezone red showed, reads like a colour regression and is not one. Established as OS drift before
re-recording, not after:

1. **The same code renders the same bytes.** At `dfced33d` (2026-09-08, on macOS 26.6.2 the day
   the Dashboard date reds were chased through all four snapshot packages) and at `a993174c`, all
   eight renders are byte-identical on this Mac, and both commits fail the same four tests.
   `EmptyStateView.swift` last changed 2026-08-12; the references were recorded 2026-07-16.
2. **The OS moved in between.** `system_profiler SPInstallHistoryDataType`: macOS 27.0 installed
   2026-09-15.
3. **Not the zone.** Still red under `TZ=America/Los_Angeles`, and the view formats no date.
4. **A band-by-band pixel diff names the change.** The symbol's *ink* is the same size in the same
   place; everything below it moved down as a rigid block — 2px (1pt) in the regular layout, 1px in
   compact — and matches once shifted. The SF Symbol's layout box grew under its ink. Nothing in the
   app lays that out.

Only then were the eight references re-recorded, and the recorded PNGs checked pixel-identical to
the renders the diff above was run on.

### 24. An NSCache emptied by memory pressure between a store and the next line — FIXED

**Symptom.** A test stores into an `NSCache`, reads the entry straight back — synchronously, on one
actor, nothing between the two lines — and finds nothing. Seen 2026-09-26 on CI (run 36212077493,
`424577cd`, a commit that touched no package code):

```
✘ Test aStoredPreviewIsFoundByTheSynchronousPeek() recorded an issue at DuplicateThumbnailCacheTests.swift:41:9: Expectation failed: DuplicateThumbnail.cached(path: path, side: 54, scale: 2, modified: stamp) != nil
✘ Test theTilePaintsFromTheCacheBeforeAnyTaskRuns() recorded an issue at DuplicateThumbnailCacheTests.swift:91:9: Expectation failed: tile.shownImage != nil
```

The first assertion's message blames the key — "the two spell the key differently" — which is the
regression that suite exists to catch, so the red reads as real. It was not:
`git diff dd1b24aa 424577cd -- Modules SyncCloudCLI` is empty and `dd1b24aa` was green; the suite
passes 5/5 in 0.001 s under `--filter` at the red SHA; and a `workflow_dispatch` re-run on the same
SHA (36213193763) went green with identical counts.

**Mechanism.** On macOS an `NSCache` keeps its entries in a libcache `cache_t` (its `_cache` ivar),
and libcache's `cache.h` is blunt about the contract: the cache "may remove keys at any time". *When*
is its memory-pressure policy, read out of `libcache.dylib` on macOS 27.0 (26A428) and then
reproduced below:

- Any system memory-pressure event other than *normal* sets a process-wide "under pressure" flag,
  and while it is set a cache's effective count limit **stops growing**.
- *Critical* sets every cache's limit to **0**. *Warn* freezes it at **however many entries the
  cache holds at that moment**.
- So a cache that is **empty when a warn arrives** is frozen at zero, and until the *normal* event
  every `setObject` is evicted before the next line can read it. A cache holding even one entry is
  frozen at one and evicts the *older* entry instead, so a fresh store survives — which is why this
  needs the cache to be empty, and why it is rare.

`DuplicateThumbnail.imageCache` was exactly that cache. Suites such as `DuplicateCardStabilityTests`
host duplicate cards for paths that do not exist (`/c0/…`); each tile's first body pass peeks the
cache, which creates it, and QuickLook renders none of those paths, so nothing is stored. A miss
under *warn* happens in that state only — a cache holding one entry, or created after the event,
keeps a fresh store — so the red itself says the cache was there, empty, when this Mac went to
*warn* at **08:13:52 IST** (`modelmanagerd`, 08:13:52: "Received dispatch memory pressure event:
warning"; `bluetoothd`, 08:14:23: "Memory pressure changed from 1 to 2"). It stayed there until
*normal* at 08:17:48–08:18:19. Both store→peek pairs ran at **08:15:22** — the "recorded an issue" timestamp,
02:45:22Z in the CI log, which stamps UTC where `log show` stamps local time — inside it. No pressure
event appears between the return to *normal* and the end of the re-run's suite at 08:33:38.

**Reproduced in-process, without loading the machine.** libcache exports
`cache_simulate_memory_warning_event(uint64_t)` — absent from `cache.h`, but
`dyld_info -exports /usr/lib/system/libcache.dylib` lists it — which delivers an event to the calling
process's caches and to no one else's:

```swift
typealias Simulate = @convention(c) (UInt64) -> Void
let simulate = unsafeBitCast(dlsym(dlopen("/usr/lib/system/libcache.dylib", RTLD_NOW),
                                   "cache_simulate_memory_warning_event")!, to: Simulate.self)
simulate(2); usleep(300_000)   // DISPATCH_MEMORYPRESSURE_WARN — applied on libcache's own queue
// ...store, then peek...
simulate(1)                    // DISPATCH_MEMORYPRESSURE_NORMAL
```

A throwaway test that primed the shared cache empty (one `cached(…)` call), simulated *warn* and ran
the suite's five bodies failed on exactly the two CI lines, with the CI messages, 3 runs of 3.
Standalone, 100 store→peek pairs per case, 3 runs each: a cache empty at the *warn* keeps **0**; one
already holding an entry keeps 100; one created after the event keeps 100; after *normal*, 100.
*Critical* evicts what the cache held within 0.3 s and then keeps **0**, whatever it held. Do not reach for `memory_pressure -S` instead: it needs
root, and it puts the whole Mac — the CI runner included — into the simulated state.

**Tell.**

1. The failing assertion reads back something the test **itself just stored** into an `NSCache` (or
   anything else built on libcache), and the miss assertions around it passed.
2. `--filter` is green in milliseconds, and so is a re-run on the same SHA.
3. The system was at *warn* or *critical* at the **"recorded an issue" timestamp**:

   ```bash
   /usr/bin/log show --style compact --start '<issue − 10 min>' --end '<issue + 5 min>' \
     --predicate 'eventMessage CONTAINS[c] "Received dispatch memory pressure event" OR eventMessage CONTAINS[c] "Memory pressure changed"'
   ```

   A *warning* before the issue with no *normal* between them is the state. **The duration is not
   the tell**: these tests reported 142 s in the red run, and 100.8 s (`dd1b24aa`) and 104.7 s (the
   re-run) when green — main-actor queueing in a ~400 s package, not the cache. Read the issue's own
   timestamp: in the red run the tests were *started* at 08:13:24, and the failing bodies ran two
   minutes later.

**The silent half.** The same state makes every *miss* assertion vacuous — "another key answers nil"
holds when every key answers nil — and in the red run the suite's three such tests passed having
examined nothing. Measured: with `cached` forced to answer nil, the old suite fails its two positive
tests and passes all three miss tests, the CI pattern exactly. That half is the more expensive one,
and a re-run cannot show it to you.

**Fix — keep the key production's, and take the shelf away from the OS.** A verdict must not depend
on retention by a cache the system is allowed to empty. `DuplicateThumbnail.store`, `cached` and
`image` now take the `DuplicateThumbnail.Storage` they use, and `DuplicateThumbnailView` takes one as
`previews`, defaulting to the shared `imageCache` — still an `NSCache` in the app, unchanged. The
tests hand in a dictionary-backed shelf of their own, so every store and peek still goes through
production's `key(path:side:scale:modified:)`; only *where* an entry is kept is the test's. Do not
fix it by inserting under a key the test spells itself: that proves only that the test agrees with
itself, the exact failure the suite exists to catch.

The injection opens two gaps, and both are closed. A tile handed its own shelf would pass every test
and flash the icon again in the app, so `aTileLooksOnTheSharedShelfUnlessHandedAnother` pins the
default by identity. And every miss now follows a `#require`d hit on the same shelf, so a peek that
finds nothing fails instead of passing. Under the harness above, the rewritten suite is green 3 runs
of 3 while a control in the same test shows the app's shelf still losing a fresh store. Mutation-tested,
each killed by a named test: `store` or `cached` spelling the key their own way; the tile peeking at
another scale, or on the shared shelf instead of `previews`; the peek moved ahead of the
`loadsPreview` guard; `key` dropping `side`; `imageCache` turned into a fresh shelf per access; and
`cached` answering nil for everything.

**Nothing else is exposed today.** `NSCache` appears nowhere else in the repo — not in the seven
packages, `MacApp/` or `SyncCloudTests/`. A new test that stores into one and reads it back has this
failure available to it from its first run; inject the storage from the start.

**See.** `Modules/FileExplorer/Sources/FileExplorer/DuplicateThumbnail.swift` (`DuplicateThumbnail.Storage`);
`Modules/FileExplorer/Tests/FileExplorer/DuplicateThumbnailCacheTests.swift`.

### 25. An `ImageRenderer` render with nothing to draw hands back an earlier render's pixels — a VACUOUS green, FIXED

**Symptom.** None, and under mutation only sometimes. Found 2026-09-26 by mutation-testing
`SetupArtworkRenderTests`: with Browse's art replaced by `Color.clear`, so the page drew nothing,
three runs of the render suites put `testEveryTourPagePaintsItsIllustration(art: .browse)` red in 2
of 3, while `testTheBrowseIllustrationPaintsColumnsAndASelection` (painted > 500, tinted > 40) and
`testTheBrowseIllustrationDrawsThreeSeparateColumns` (exactly three runs of ink) each **passed** in
1 of 3 — on a blank page. A probe that rendered every page in tour order six times read the `.browse`
bitmap as `[18351, 0, 0, 0, 0, 0]` painted pixels, and 18,351 is `.duplicates`' count exactly.
Re-measured at `6794379d`, five runs each: with that mutation `…PaintsColumnsAndASelection` passed
blank 4 of 5 and the `.browse` case 3 of 5; with the realistic regression instead — Browse's `onAppear` never
revealing, its columns left at `opacity(0)` — 3 of 5 and 2 of 5, and in two of those runs the column
test was the only red in three suites.

**Mechanism.** `ImageRenderer`'s `nsImage` and `cgImage` come back in a pixel buffer the renderer
recycles between renders of the same pixel size, and a render with **nothing visible to draw does
not clear it**. It returns whatever the last same-sized render painted, provided that render's image
has already been freed. Measured on macOS 27.0 (26A428), a painted render and then a second one:

| Second render | What it reads |
|---|---|
| `Color.clear` | the first render, whole: 124,800 of 124,800 pixels |
| a view at `opacity(0)` — art whose reveal never ran | the same |
| an invisible `drawingGroup()`, `blur`, `shadow` or blend-mode group | the same |
| `Color.clear`, the first render's `NSImage` or `ImageRenderer` still alive | clean |
| `Color.clear`, the first render 1pt wider, or 1pt taller | clean |
| anything visible: a 1pt dot, `opacity(0.001)`, a half-width fill | clean — the whole buffer is cleared first |

In the app's test host, `.duplicates` and then `Color.clear` at the page's size read **18,351
painted, 9,599 tinted** — `.duplicates`' own counts — 6 runs of 6. The two renders' pixels sit at
the same address, and it is not the allocator recycling them: under `MallocScribble` the stale
pixels keep the first render's colour rather than the fill freed memory gets. The pool is the
renderer's.

**Why it comes and goes.** A buffer is only handed out again once the image holding it is freed, and
`nsImage` returns an image that lives until its autorelease pool drains. The same pair in the host:
with no pool around each render, stale **0 of 6**; with one, **6 of 6**. A full run drains between
main-actor jobs, so whether a blank page reads blank depends on which test ran before it and when
its pool emptied — which is why one mutation let a different set of Browse tests through from run to
run, and why nothing in any green run shows it at all.

**Never partly stale.** Content that paints anything clears the whole buffer first (the dot and
half-width rows above). Five of the seven setup art pages rendered byte-identically after three
different predecessors. The two that did not, Welcome and Transfer, run `repeatForever` animations,
and Transfer differs between two renders after the **same** predecessor; none of its 3,539 differing
pixels carries the predecessor's value. The buffer leaks through whole or not at all — which is why
a blank that reads as another page's exact count is the tell.

**Tell.** A pixel suite that stays green under a mutation that blanks its subject, in some runs and
not others. A "blank" whose ink count equals another page's exactly. Mutation-test a render suite
more than once, and read the counts, not the verdict.

**Fix — own the buffer, and prove a blank reads as blank.**
`ImageRenderer.render(rasterizationScale:renderer:)` draws the same view — same renderer, `onAppear`
included — into a `CGContext` the test allocates and clears, so a page that paints nothing reads as
nothing: 0 in every row of the table above that went stale, `drawingGroup` and `blur` included.
`SetupArtworkRenderTests.render(_:named:)` does that now. Its pixels are drawn by Core Graphics
rather than rasterised on the GPU, so they are not byte-identical to the old harness's: Browse's,
Compare's and Edit's painted counts are unchanged, the other four pages move by at most 36 pixels,
and every floor keeps its margin. Do not reach for the other harness in this repo, an unattached
`NSHostingView` read through `cacheDisplay`: it drew Browse and Welcome as nothing at all, captured
before their `onAppear` reveals showed.

The blank control is the mirror of the positive one every pixel suite here already has: a floor that
says "this is not blank" is only evidence if a blank reads as blank **in the same harness, straight
after a painted render whose image has been freed**. `testABlankPageReadsAsBlankRightAfterAPaintedOne`
renders both blanks a broken page produces — an empty body, and art at `opacity(0)` — after
`.duplicates`. Against the old harness it failed 5 runs of 5, both blanks reading 18,351 painted
pixels. Against the new one, both mutations above put all three Browse tests red in 5 runs of 5,
reading 0 painted pixels and 0 runs of ink, and the unmutated suites stay green 5 of 5.

**Nothing else is exposed today.** `SetupArtworkRenderTests` was the only suite reading pixels from
`ImageRenderer`'s own image. The four `SnapshotRendering.swift` copies render through `NSWindow` +
`NSHostingView`, and `DocumentPDF` and `DocumentPrinting` already draw through `render(...)` into
PDF contexts of their own — the path that stays clean.

**The general rule:** a render harness that does not own its output buffer can answer with someone
else's pixels, and the only way to see it is to ask it for a blank.

**See.** `SyncCloudTests/SetupArtworkRenderTests.swift` (`render(_:named:)`,
`testABlankPageReadsAsBlankRightAfterAPaintedOne`).

### 26. A log line hopped to the main actor, so the capture's flush marker finishes without it — FIXED

**Symptom.** A `LogCapture` presence assertion fails for a line the code under test really writes,
in the full package only, and a same-SHA rerun is green. Seen 2026-09-27 on CI (run 36326849137,
attempt 1, `3880861c` — the v5.4 re-bump, which changed only version strings):

```
✘ Test anUnreadableKeychainIsLogged() recorded an issue at AnthropicKeychainTests.swift:167:9: Expectation failed: await log.holds(.warning, containing: "a stored key may exist but cannot be read right now")
```

Attempt 2 went green on the same SHA, and so had `28ade2a6`, twice. The silent half is the same
mechanism read the other way: an **absence** assertion about such a line passes having seen nothing.

**Mechanism.** `LogCapture.entries` awaits one more entry's flush, which drains everything already
in `Logger`'s pending queue — rule 1's visibility half of mechanism 12. `AnthropicKeychain.log` did
not put its line in that queue; it wrote `Task { @MainActor in Logger.shared.warning(message) }`, so
the line was only *scheduled* to be enqueued when `read` returned. That is safe until a flush is
already queued on the main actor when the test calls in — routine in a full package run, where
other suites log from other threads. `PendingLogEntryQueue.enqueue` returns that already-scheduled
flush instead of making a new one, so the main actor runs:

1. the queued flush F1, carrying the capture's marker — the test's await completes, and its
   resumption R is queued **behind** the keychain's task W;
2. W, which enqueues the warning and, F1 having cleared, schedules a new flush F2 — behind R;
3. R, which reads the capture before F2 has published the line.

A probe printed the order directly: the marker joined F1 (`true`), then `W`, then `R`, with the line
unpublished at R. Nothing else in `Logger` hops. `warning`, `error`, `info`, `debug` and `shared`
are all `nonisolated` and enqueue before they return. The hop was a leftover from before they were.

**Tell:** the missing line is written through `Task { @MainActor in … }` (or reaches the logger
through a helper that does). The test is red **every time** under `--filter` once a flush is queued
ahead of it, but the full package can mask it: there, siblings' own main-actor jobs land between R
and the read often enough to pass. On this suite, six full-suite runs were green, and three
`--filter` runs of the two tests were red.

**Fix — log synchronously.** Twenty-one hops across eight files in `Sync` and the app target, every
one a pure wrapper around a `Logger.shared` call, now call the logger directly. The one hop left,
in `ContentView+DocumentSurvey.swift`, does real main-actor work and logs as its first line, so its
caller is not waiting on that line. Both keychain log tests now log one line before the call under
test, which queues F1 deterministically, and they fail under `--filter` when only the keychain's
hop is restored (2 runs of 2) and pass without it (5 of 5).

**The general rule:** a flush barrier proves visibility only for what was enqueued before it, and a
line the code under test schedules for later is not enqueued yet. Never put a log call behind an
actor hop the caller cannot await.

**See.** `Modules/Sync/Tests/Sync/AnthropicKeychainTests.swift`
(`anUnreadableKeychainIsLogged`, `aRefusedDeleteIsLogged`); `PendingLogEntryQueue` in
`Modules/Events/Sources/Events/Logger.swift`.

### 27. An unlocked read of the mock's disk lands inside the write the test is waiting for — FIXED

**Symptom.** The test process dies mid-run, with no `✘` for the test that died:

```
error: Process '…/swiftpm-testing-helper --test-bundle-path …' exited with unexpected signal code 11
```

`swift test` prints that line on stderr, so it can come before the test output rather than at the
end. The log lists every test in flight as `◇ Test … started.` — hundreds, in a full run — but only
the crash report, `~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-*.ips`, names the one
that died:

```
EXC_BAD_ACCESS (SIGSEGV) at 0x0000000000000010               x0 = 0x8000000000000000
0  libobjcMsgSend2.dylib  objc_msgSend +32
1  libswiftCore.dylib     Dictionary._Variant.lookup(_:) +76
2  SyncTests              freestanding macro expansion #4 of expect … FileSyncManagerTests.swift line 92
3  SyncTests              FileSyncManagerTests.testUndoRegisterTrashItems() +296
```

Seen 2026-10-02 19:01 in a local full `swift test` of `Modules/Sync` (reported: load average 6–7,
and three later full runs passed); the report redacts the bundle's path, so it does not say which
commit. The same race can die as signal 6 instead, and then the log names both the cause and the
test — the frame under `Dictionary._Variant.lookup` (mangled `$sSD8_VariantV6lookupyq_SgxF`) in the
first-throw call stack, which `swift demangle` reads:

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '-[__NSCFNumber objectForKey:]: unrecognized selector sent to instance 0x8000000000000000'
```

**Mechanism.** `MockFileManager` serialised its methods with a recursive lock, but `virtualDisk`
was a plain stored property, so a test's own reads took no lock. `testUndoRegisterTrashItems` calls
`undo()`, whose restore runs on the file-operation queue's detached task, then polls
`mockFM.virtualDisk[…]` from the main actor until the file is back, and reads it once more in the
`#expect` after. The restore's `moveItem` copies and then removes under one hold of the lock, and
an unlocked poll can see the copy land and return before the remove has run — so the line after
the wait reads while the remove is mutating the dictionary.

In the 19:01 crash that sequence is deduced, not guessed. `waitUntil` returns when its condition
holds or after 5 s, and the helper process lived 4.6 s in all (launched 19:01:26.37, crashed
19:01:31.00), so the poll returned because the restored file was there. The copy had landed, then,
and the remove was the only write to that disk left: the identity snapshot the restore takes next
only reads, and `movedInto` is a separate set.

What the read loads is specific. For the length of an in-place insert or remove, the standard
library parks a placeholder in the variable that holds the dictionary —
`Dictionary._Variant(dummy:)`, `0x8000000000000000` on arm64, a tagged pointer — so that the
mutation holds the only reference to its storage. A read that loads the variable in that window
takes the tagged pointer for a bridged `NSDictionary` and sends it a message: `objectForKey:` for a
subscript, which is the frame above. The runtime's per-launch shuffling of tagged-pointer classes
decides what happens next: a pattern that decodes to no class faults at `0x10`; one that decodes
to a real tagged class (`__NSCFNumber`, `__NSTaggedDate` and `NSIndirectTaggedPointerString` all
seen) throws the unrecognized selector.

A read that survives is wrong more quietly: it can see half of a compound mock operation — a move's
destination present while its source still is — which no same-volume rename shows.

Evidence, on arm64, macOS 27.0.1 and Swift 6.4:

- Measured: a key whose `hash(into:)` reads the variable's raw bits sees `0x8000000000000000` on
  every hash an insert makes, and during a remove's delete step when it rehashes the keys after the
  removed one (forced here with colliding keys); the remove's lookup, before the delete, and the
  variable at rest both show the storage pointer.
- Measured: a subscript on `unsafeBitCast(UInt64(0x8000000000000000), to: [String: Int].self)`
  crashes frame for frame like the report — `objc_msgSend +32` under
  `Dictionary._Variant.lookup(_:) +76`, `x0 = 0x8000000000000000`, fault at `0x10`.
- Deduced from those two: the 19:01 read overlapped a write to that same disk, since the
  placeholder is in the variable at no other time — and at that line the undo's restore was the
  only work running against that mock.

**Tell:** a crash, not a failure, whose receiver is `0x8000000000000000` — `x0` in the `.ips` for
signal 11, `sent to instance 0x8000000000000000` in the log for signal 6. A subscript shows
`objectForKey:` under `Dictionary._Variant.lookup(_:)`; `.keys`, `.isEmpty` or iteration would send a
different selector from a different frame, but the address would be the same. The frame under the
dictionary code is the unlocked read: look for what that test reads, without the lock, while an
operation it started is still running.

**Fix — the collections take the lock.** `virtualDisk` is now computed over private storage: `get`
returns a snapshot under the lock and `_modify` mutates in place under it, so every access a test
makes waits out whole mock operations, and no call site changed. There are many: 71 `waitUntil`
closures in 18 files of `Modules/Sync`'s tests poll the disk while an operation runs. Every other
collection the mock shares with a test — `trashedPaths`, `attemptedRemovePaths`, `movedInto`,
`danglingSymlinks`, `unlistableDirectories` and the two fail-once sets — locks the same way, because
the same race waits there for the first `waitUntil { mockFM.trashedPaths.count == 2 }`. Flags,
injected errors and hooks stay plain properties, protected by order instead: a test arms them before
the operation starts. A racing `Bool` would merely be stale; a hook or an error is a reference, and
racing one could crash like a collection.

Two rules follow, both now in the mock's doc. A callback that runs under the lock must never block,
because every test-side access waits for it now — and `beforeCopyItem` runs under it whenever its
copy is nested in a move, a trash or a folder copy. And a locked property must never be passed
`inout` across an `await`: an access that ends on another thread cannot release an
`NSRecursiveLock` — measured: the lock stays held, and every later call into the mock would hang —
so the mock stops the process instead.

`MockFileManagerLockTests` holds a real `moveItem` inside the lock and requires a read from another
thread to wait it out and see it finished, and a read and a write of every locked collection to
wait. What the fix was measured against:

- The mechanism at a high rate: a thread reading `virtualDisk` in a loop while a real delete and
  undo ran crashed in its **first iteration** in 3 runs of 3 (two SIGABRT, one SIGSEGV). Under
  Thread Sanitizer it reported a Swift access race between the delete's `trashItem` → `copyItem`,
  holding the mock's lock, and the read — then crashed the same way. Against the final mock:
  6,000 iterations and about 230 million reads with no crash; under TSan, 20 iterations of it plus
  both `MockFileManagerLockTests` and `FileSyncManagerTests`, with no report.
- The test: unlocking `virtualDisk`'s getter fails it on the read and on the snapshot, which saw
  `/dst/project` beside `/src/project` — the move half done; unlocking its `_modify`, `trashedPaths`'
  getter or `unlistableDirectories`' `_modify` fails it naming exactly that access. Dropping
  `moveItem`'s own hold of the lock, so that its copy and its remove are held separately, SURVIVES
  (5 runs of 5): the move re-takes the lock before a waiting reader is woken. That atomicity
  predates this fix, and nothing pins it.
- The guard: a probe holding `&mock.virtualDisk` across an `await` that resumed on another thread
  stopped at once, naming the cause, instead of leaving the lock held.
- The test's own body, looped 320,000 times across 8 concurrent processes (load average rising from
  3 to 9), never crashed: the placeholder is in the variable for one insert or remove at a time,
  and a read has to land inside it.
- Whole suites are where it happens. These runs, and the cost below, measured the first version
  of the fix, which locked `virtualDisk` alone. Six full runs of the package at a time, beside four
  spinners and a looping clean build: the unchanged mock crashed once in 109 runs — inside
  `DeleteRedoOccupantTests.deleteUndoRestoredThenRedoReTrashes()`'s own poll, SIGABRT on
  `-[__NSTaggedDate objectForKey:]` — and the locked one not at all in 108. One crash per hundred
  loaded runs is too rare for that comparison to prove the fix; the looping reader is what does.
- Run back to back, those two arms also differed in timing reds, 77 against 131, not counting three
  source-scan tests that fail in every run of that scratch copy. Run interleaved, three of each at
  once for 45 runs apiece, they had 69 each and no crash either side. The difference came from when
  the arms ran, not from the lock.
- The cost: instrumented, a full run's own disk accesses take the lock on the main thread about
  9,800 times. Across six loaded runs two of those waited over a millisecond (34 ms and 5 ms); in
  the four runs with none, no wait reached 0.14 ms.

Fixed on `main`; `v4.x`, `v3.x` and `v2.x` keep the unlocked mock. Possibly seen before: the 22-run
reproduction in "Every gate parks at once, on the pool their releases need" recorded one unrelated
`signal 11` in a full Sync run. This race fits it, but no crash report from before 2026-10-02
survives to check.

**The general rule:** a lock protects nothing from a reader that does not take it, and a test is a
reader. Lock a test double's shared collections at the property, not at their call sites — and
expect a polled condition to be the worst case: a poll can return the moment the first half of a
write lands, which puts the line after it on top of the second half.

**See.** `MockFileManager` and `MockFileManagerLockTests` in `Modules/Sync/Tests/Sync/`;
`FileSyncManagerTests.testUndoRegisterTrashItems`.

---

### 28. A privacy prompt nobody answered wedges `sandboxd`, so a move into the real Trash outlasts the wait

**Symptom.** One app-target test red on every run, on a commit that passed an hour earlier:
`DuplicateReviewCoordinatorTests.confirmingTrashesTheRightCopyAndReturnsToDuplicates()`, red in all
5 result bundles from 13:21 to 13:27 on 2026-10-03, green at 12:26 and again from 15:13 with nothing
changed. Six expectations fail, and only the first one matters:

```
the right copy leaves the disk — still false after 417 polls
the review is torn down — still false after 423 polls
harness.workspace → .compare   ·   harness.organizeLens → .toFile   ·   duplicateGroups not empty
```

Hundreds of polls means the main actor was free — not "Fixed pumps and fixed sleeps". And nothing
refused: the test-host log (`$TMPDIR/sync-cloud-tests-<pid>.log`) names the test's
`dup-review-<UUID>` path in **no** line at all — no drift refusal, no "review changed", no
`Delete:` gate line, no "Moved 1 item(s) to Trash". A refusal at any step logs; a step that is
still running does not.

**Mechanism.** `FileManager.trashItem` into `~/.Trash` is gated by the kernel sandbox, which asks
`sandboxd`, which asks `tccd` (`kTCCServiceSystemPolicyAllFiles`) before the rename lands. Healthy,
that round trip is milliseconds — the check, then the rename 4–26 ms later, three times over:
13:19:18.737 → `Docs 13-19-18-756`, and 15:11:44.970 and 15:13:54.956 the same way.

At 13:20:31 an **ad-hoc** Debug build of SyncCloud (pid 85649, the `SyncCloud-open-text` worktree's
`.dd`) touched `~/Documents`. Its signature matched no existing grant (`tccd`: "Failed to match
existing code requirement … kTCCServiceSystemPolicyDocumentsFolder", `authValue=1`, undecided), and
at 13:20:31.891 `sandboxd` sent one more authorization request — after which **its request path
stopped**. Its `tccd` message ids run 408.5629 at 13:20:31.785, then 408.5630 at **15:10:42.001**:
nothing in between, for 1 h 50 min, on behalf of any process. It logged one more `request approval`
at 13:20:38.635 and then nothing at all until 15:10:42.001 — 19 ms after a button click in
`UserNotificationCenter`, which draws the Files & Folders consent dialogs (the display had woken at
15:10:39). Then it flushed the backlog, about 1,545 requests in 3 s, for
`com.apple.AddressBook.abd`, `IMTransferAgent`, `spotlightknowledged`, `swiftpm-testing-helper`, the
installed SyncCloud and more. The wedge is machine-wide.

Inside the wedge the trash still lands, late. **The Trash itself records when:** a collision is
renamed `Docs HH-MM-SS-mmm`, and the failing runs' copies sit there at **+5.04 s, +5.04 s and
+5.25 s** after their suites started (`Docs 13-22-15-676`, `13-22-40-407`, `13-23-04-436`) — just
after the test's 5 s wait had given up. `trashItem` then still did not return: no run logged "Moved
1 item(s) to Trash" in the 5 s it had left. That the kernel abandons each unanswered check after
about 5 s is inferred from those offsets, not documented anywhere. Another session measured a whole
`trashItem` at 62.8 s during the same window — relayed, not re-measured here.

Measured healthy for comparison (temporary per-step logging, 15:27): confirm → drift gate →
identity guard → removal gate takes **3 ms**; `trashItem` takes **95 ms**, and it is the only step
that touches a TCC-protected location — the fixture lives under `$TMPDIR`.

**Tell:** the test's own copy is in `~/.Trash` with a timestamp **about 5 s after** the suite's first
log line, and `log show --predicate 'process == "tccd" AND eventMessage CONTAINS "sender_pid=408"'`
has a gap of minutes or more in its `msgID=408.N` sequence that covers the red. Cheaper and live:
time one `trashItem` from a plain Swift script — tens of milliseconds healthy, seconds wedged.
"It worked from a script" does not clear the machine; under this wedge it *works*, slowly.

**What it is not.** Not a regression, not load, and not the Trash's size: the test passed at 13:19,
70 s before the prompt, with its rename 19 ms after the check. Launch Services re-registrations and
an `/Applications` swap fell in the same window, but nothing else lines up: `sandboxd` went quiet
on the prompt's request and resumed 19 ms after the dialog's click.

**Fix — for every test that trashed, in every package CI runs, 2026-10-16.** Answer the prompt
and the machine recovers at once (rerunning while it is up only adds to the backlog).
`confirmingTrashesTheRightCopyAndReturnsToDuplicates()` no longer uses the real Trash: its harness
gets a `ScratchTrash`, a `FileManager` whose `trashItem` moves the item into a folder the test owns
and reports where it went, as the real Trash does. Every other call is the real disk, so the drift
gate this test exists for still stats and re-walks real folders, while `sandboxd`, `tccd` and
`~/.Trash` are out of its verdict. The test also checks that the copy arrived in that folder, so a
stand-in that reached for the real Trash again fails by name. It ends the pollution from this
test, which had left 263 `Docs <time>` in his Trash by 2026-10-16.

Every `Modules/Sync` suite that moved something into the real Trash now uses one shared
`ScratchTrash`, in `Tests/Sync/ScratchTrash.swift`. They were found by tracing, not by fixture
names: each suite run alone, with `~/.Trash` listed before and after and watched while it ran,
which also catches a suite that trashes and then deletes. Nine left items behind, per run:
`FolderMergeTests` 7 (`a.txt`, `b.txt`, `Reports`, `sub`, `deep`, two `.rollback_<UUID>` replace
backups), `MergeUndoGroupingAndGateTests` 4 (`bystander.txt`, three `unique<N>.txt`),
`RestructureApplyTests` 2 (`Payment`, `State Tax`), `RestructureScaffoldApplyTests` 2
(`Statements`, `Claims`), `OrphanSweeperTests` 2 and `AutoVerifyOnScanTests` 1 (`.tmp_<UUID>`),
`RestructureApplyGuardTests` 1 (`Emptied`), and `CopyWalkCaseVariantRestartTests` and
`VerifyAllWithChecksumTests` 1 each (`.rollback_<UUID>`). Four more deleted what they trashed, so
no count saw them: `AtomicReplaceTests`, `FileSyncManagerDuplicatesTests`, `MergeUndoPromiseTests`
and `DeleteHandbackRunPairingTests` — 6, 4, 3 and 2 moves a run, each waiting on the same check.
After the change none of them moves anything into the Trash, and each checks that its trash
arrived in its own folder, so a stand-in pointed back at the real Trash fails by name.

`RestructureScaffoldApplyTests` needed an app change. `applyScaffold` registered its ⌘Z through
`registerCreateFolderUndo(url:)` with no file manager, so the undo trashed through
`FileManager.default` whatever the manager held; it now passes the one that created the folders,
and so does `applyPlan`'s matching call. In the app that is `FileManager.default` either way —
`MacApp/SyncCloudApp.swift` builds the manager with `FileSyncManager()` — so nothing changes
there. `applyPlan` still registers its rename and move undo without one; neither ever trashes.

**A correction, and the other packages.** The first trace put `silent.txt` and `trash-me.txt` on
`DocumentSurveyRunTests`. They came from Dashboard's `FileActionHandlerOperationTests`, run by
another session at the same moment: a trace on a shared machine counts everyone's trashes, so
match each item to a fixture the suite really writes. That suite's two delete tests trashed for
real and put the file back by ⌘Z, best-effort, leaving it behind whenever the restore missed —
`FileActionHandler.confirmDelete` called `deleteItems` with no file manager, so no test could hand
it another. It now passes the manager's own, which in the app is `FileManager.default` (the one
handler is built from the `SyncCloudApp` manager), and the tests trash into a Dashboard copy of
`ScratchTrash`. The handler's seven other calls into the manager — copy and move from a pane, a
drop, cut and copy paste, rename and new folder — skipped it the same way and pass it now too. No
test trashed through them, so each is pinned instead by a recording file manager that notes the
move or new folder the operation ends in.

Every other package was then run whole under the same watch, on 2026-10-16 at `03abc1ad`:
Design, Events, FileExplorer, Settings and the app's own `SyncCloudTests` moved nothing into the
Trash. The one test left was `SyncCloudCLI`'s `EnvironmentDefaultsTests`, which left a
`.rollback_<UUID>` every run: its cleanup looked for its own file's name, but the replaced file
reaches the Trash as a backup under another. Its copy seam already takes a file manager, so it now
passes a CLI copy of `ScratchTrash` and checks the backup arrived there. That was the last known
real-Trash user across every package CI runs — Sync, Events, Settings, Design, Dashboard,
FileExplorer, `SyncCloudCLI` and `SyncCloudTests`. A new one shows up as a name in `~/.Trash`; trace
it the same way, by suite and with the watch running.

Traced again on 2026-10-26 at `4f6054fdf`, every package and the app target, from an empty Trash:
nothing reached it. The Trash folder's own modification time is the quickest check — it did not
move during any of those runs, so nothing was even trashed and deleted again.

The Trash on this Mac held 11,806 items before that tracing; a count by name during it found
about 545 of each fixture name above, 2,279 `.rollback_<UUID>` and 1,634 `.tmp_<UUID>`. The source
of the prompt is the other half: an ad-hoc build that reads `~/Documents` while nobody is at the
machine raises a dialog no one will answer for hours.

**See.** `trashRightCopy(_:)` in `MacApp/DuplicateReviewCoordinator.swift`; `deleteItems` in
`Modules/Sync/Sources/Sync/FileOperations.swift`; CLAUDE.md, **Trying an app change**, on why every
ad-hoc install is a new app to TCC.

### 29. A find indicator's redraw outlives the text view it was asked for — FIXED

**Symptom.** `swift test` in `Modules/FileExplorer` dies with `exited with unexpected signal code 6`
(or 11) and no `✘` for any test. The crash report,
`~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-*.ips`, has the main thread in a run-loop
timer:

```
objc_exception_throw
-[NSObject(NSObject) doesNotRecognizeSelector:]    ← SIGABRT; for SIGSEGV, objc_msgSend here instead
___forwarding___
-[NSTextFinderIndicatorManager _delayedUpdate]
__NSFireDelayedPerform
__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__
```

The selector is `__retain_OA` (`lastExceptionBacktrace`). Below the timer is whichever test happened
to be turning the run loop — `LineEndingPathsTests.spin()` inside `aPastedCRLFIsWrittenAsLF` in one
report, the main executor's own `CFRunLoopRun` in the rest — which names the wrong test. Six reports
2026-10-09 to 10-12, local runs under load.

**Mechanism.** AppKit's find indicator asks to redraw itself a little later —
`-[NSTextFinderIndicatorManager _scheduleDelayedUpdate]`, a `performSelector:afterDelay:` that fires
14–30 ms on, later under load. The perform retains the indicator manager but not the finder it
reports to (`_NSBarTextFinder`), and the text view frees that finder in its own `dealloc`
(`-[NSTextFinder _clearClientIfMatchingClient:]`) without cancelling the request. A text view freed
inside that window leaves the timer to message a freed finder. Two things ask for the redraw:

- **Find Next** — `pulse`, synchronously. `EditorMenuChordTests.findNextReachesTheDocumentFromTheFindBarsField`
  returns straight after it.
- **An incremental search's first match** — `_updateIncrementalMatches`, from an `NSOperationQueue`
  search that the bar starts when it opens, for whatever the **Find pasteboard** holds. Its timing
  belongs to the queue, not the test: under load, measured landing 1.0 s and 1.6 s after
  `EditorFindBarTests.theFindOnlyActionIsWhatHidesTheReplaceRow` started it — a test that returns
  straight after opening the bar. In 24 instrumented runs it was the only test whose bar searched.

The Find pasteboard is machine-wide — the ring of "A named NSPasteboard is machine-global, so two
test PROCESSES share it" — and `LineEndingPathsTests`'
`findingInAFileChangesNothing` writes `"one"` to it through Use Selection for Find — a word every
find-bar fixture's text contains. So that test is the reason the others' bars find something; it
never asked for a redraw itself in any run measured. What usually saves the process is another
suite's `spin()` servicing the timer before the view goes: a dropped text view here is freed by a
deferred run-loop block half a second or more later, not when the test returns.

Measured, with an injected logger on the manager's methods and `NSZombieEnabled=YES`: 2 of 22 runs of
`--filter 'Editor|LineEndingPaths'`, two processes at once, died on
`-[_NSBarTextFinder retain]: message sent to deallocated instance`; in both, the finder was freed
21 ms and 88 ms after an incremental search's match had asked for a redraw, the search having been
started by `theFindOnlyActionIsWhatHidesTheReplaceRow`.

**Tell:** `-[NSTextFinderIndicatorManager _delayedUpdate]` under `__NSFireDelayedPerform` in the
crashing thread. A load flake: a same-SHA rerun passes, and so does `--filter` on any one suite.

**Fix — retire the bar before the view goes.** `PlainTextEditor.retireFindBar(of:)` does two things,
measured separately because neither covers the other:

1. **Hide the bar** (`NSTextFinder.Action.hideFindInterface`). That retires a search still in flight,
   so no match lands afterwards. It does **not** cancel a redraw already asked for: hidden straight
   after Find Next, the redraw still fires on time.
2. **Hold the view on a one-second run-loop `Timer`.** Nothing public cancels the redraw, so the
   view outlives it instead. Timers in one run-loop mode fire in date order, so the hold ends after
   the redraw even when the main thread was too busy for either to be on time.

Every test that opens a find bar calls it in a `defer` — `EditorFindBarTests`,
`EditorMenuChordTests`, `LineEndingPathsTests`. Measured against unfixed `main`, the two run side by side
under the same load, `NSZombieEnabled=YES`, `--filter 'Editor|LineEndingPaths'`: **3 crashes in 34
runs unfixed, 0 in 34 fixed**. In 15 of those rounds the logger ran in both: unfixed, all 15
searches landed and asked for a redraw, and a finder was freed with one pending twice (both
crashed); fixed, none of the 15 searches landed, and no finder was freed with a redraw pending.

**The app had the same exposure, and is fixed with the same call.** Both editors' `dismantleNSView`
— `PlainTextEditor` and `PreviewEditorView` — retire their bar. Measured on the real `PlainTextEditor`
in a window that stays, as the app's does: a Find Next redraw pending at close is not cancelled when
the editor leaves the window, and an incremental search started before close lands after it (6 of
6), asking for a redraw on a text view no longer on screen. With the retire, 0 of 6 land. No
SyncCloud crash report on this Mac carries the frame; the window in the app is the time between
close and the text view's release, which undo actions can stretch. `closingTheDocumentRetiresItsFindBar`
pins the call in both editors by the bar it takes down; removing either call fails its own case.

**See.** `PlainTextEditor.retireFindBar(of:)` and both `dismantleNSView`s;
`EditorFindBarTests.closingTheDocumentRetiresItsFindBar`.

### 30. A spell check and a defaults change from another process deadlock a SwiftUI focus move — FIXED

**Symptom.** No verdict, and no core pegged: the run stops making progress at **0% CPU** with
dozens of tests in flight. That is the difference from "The wait that hangs instead of failing",
whose spin keeps one core busy. Seen locally on 2026-10-15 at 09:15: `swift test --filter
'Editor|LineEndingPaths'` in `Modules/FileExplorer` at `8d559a26`, with `NSZombieEnabled=YES` and a
second test process running, sat at 0% for 4+ minutes with ~25 tests in flight, among them
`LineEndingPathsTests.aMixedFileIsConvertedToo` and
`EditorFindBarTests.theFindOnlyActionIsWhatHidesTheReplaceRow`. Probably also CI run 38483524002
(`0cfe5460`): FileExplorer's output stops at 23:41:03 with
`LineEndingPathsTests.carriageReturnsMapAndNormalise` and 37 suites, most of them Editor and
layout, started and not finished, and the job was cancelled 21 minutes later. That run was never sampled,
so the match is by shape only. `swift test` buffers its output in blocks, so a frozen log's
in-flight list is a superset of what was really running.

**Mechanism — two threads, two locks.** The 09:15 sample:

```
main     CFRunLoop observers → NSRunLoop.flushObservers → UpdateGroup.end → dispatchActions
           → FocusBridge.moveFocus → -[NSWindow _realMakeFirstResponder:]
           → -[NSTextView resignFirstResponder] → _performPendingTextChecking
           → checkTextInRange → … → NSSpellCheckerCheckString + 600
           → _pthread_mutex_firstfit_lock_wait                      (wants the spell checker's lock)
checker  -[NSTextCheckingOperation main] → NSSpellCheckerCheckString + 2656   (holds that lock)
           → scoreParagraph → NLTokenizerCreate → CFLocaleCopyPreferredLanguages
           → _CFXPreferences withSearchListForIdentifier → _deliverPendingKVONotifications
           → UserDefaultObserver.observeValue → UpdateGroup.enqueueAction   (wants SwiftUI's update)
```

CFPreferences does not deliver a change made by **another process** when it arrives. It parks the
change and hands it to observers on whichever thread next reads preferences through that search
list. The spell checker reads the preferred languages while it holds its own lock, so it can be
that thread. The observer it then runs is `@AppStorage`'s, and that needs SwiftUI's update group,
which the main thread holds while it moves focus. The main thread is waiting for the spell
checker's lock so it can finish the resigning text view's pending check. Three conditions, all
needed:

1. a text view that **resigns with a check pending that reaches the spell checker**;
2. a **change from another process** to a key that an `@AppStorage` in the process observes, in
   the **standard** domain (the app's search list, which is the one the checker reads);
3. a **SwiftUI-driven focus move** off that text view.

**Condition 1 is any check that reaches the spell checker, and no setting stops one.**
`scoreParagraph` is the checker's language guess, not spelling, and `NSSpellCheckerCheckString`
runs it whatever it was asked to check: in a probe, `checkString:` with types `0`, `0x1`, `0x2`,
`0x100`, `0x200`, `0x2000` and `0x2001` ran it once each. An lldb breakpoint on `-[NSTextView
checkTextInRange:types:options:]` read what text views ask for:

| Text view | Asks for | Reached the checker |
|---|---|---|
| a SwiftUI `TextField`'s field editor | `0x2301`: spelling, replacement, **correction**, private bit 13. Correction because the system's "Correct spelling automatically" is on | yes: on main when it resigns (`EditorGoToLineWiringTests`' Go to Line field, `PaneHeaderSearchTests`' search field), and in background checks, which carry no view |
| the same, correction and replacement off | `0x2001` | **still yes**: `PaneHeaderSearchTests` resigned one on main, 2026-10-16 |
| an editor's text view, Check Spelling **off** | `0x2001` | not on 2026-10-15: 0 hits across 123 tests in five suites that mount editors and type into them. The types are the field editor's, so that is not what kept it out |

So every SwiftUI text field a test types into meets condition 1 on its own. **No defaults key
stops it** — tried 2026-10-16, each in the process's argument domain (which outranks every other),
against a `PaneHeaderSearch|PaneSearch` rig that checks twice.
`NSAutomaticSpellingCorrectionEnabled` and `NSUserDictionaryReplacementItemsEnabled` (text
replacement's key, read off `+[NSSpellChecker isAutomaticTextReplacementEnabled]`) took the field
editor from `0x2301` to `0x2001` and left both checks, and across all of Dashboard the count did not fall: 62 before, 110 with them.
`NSAutomaticSpellCheckingDisabled`, `NSAllowContinuousSpellChecking` and `NSTextCheckingTypes = 0`
changed nothing, and with `NSSpellCheckerAutomaticallyIdentifiesLanguages = NO` the checker still
guessed. The 09:15 sample does not say which text view resigned. `FocusBridge.moveFocus` is SwiftUI
moving focus, which fits a field as well as an editor, and `EditorFindBarTests`' bar fields were in
flight.

**Why editors met condition 1 at all.** Check Spelling While Typing defaults to off. But
`PlainTextEditor` and `PreviewEditorView` read it through `@AppStorage`, and nine FileExplorer
suites mounted them on `UserDefaults.standard`. Under `swift test` that is the
`swiftpm-testing-helper` domain, **one domain shared by every local run, every worktree and the CI
runner**, which runs as the same user. On 2026-10-15 it held `editorChecksSpelling = 1`, so every
one of those mounts spell-checked, in every run on the machine. No test leaves that value on
purpose. The one test that wrote `true` there, `EditorTextSettingsTests`'
`theTicksFollowTheStoredSetting`, put the old value back in a `defer`, which a killed run never
reaches. That is the same shape as "Leaked defaults suites". The value was gone again by 17:45;
who removed it is not known.

Condition 2 comes from the same domain, and "A named NSPasteboard is machine-global, so two test
PROCESSES share it" has the measurements: until 2026-10-15 several package suites wrote it
directly, and in every **other** test process alive at the time each write was a change from
outside. They all write scratch suites now, and since 2026-10-16 no test on `main` writes it
through the code it drives either (the same section, "The last writes went 2026-10-16"). What can
still reach it is a run from a worktree on an older base, and anything run by hand: a `defaults
write swiftpm-testing-helper …` loop ran on 2026-10-15 from about 09:09 to past 15:48 PDT, writing
`editorWrapsLines` and `editorShowsFormatBar`, for every FileExplorer process on the machine, CI
included. That is why condition 1 is the one this fix removes: condition 2 is other processes'
behaviour, which no test can rule out.

**Measured, and not.**

- **A suite does not search the app's domain.** With a key written to a binary's own domain by
  `defaults write`, `UserDefaults.standard` read `1` and `UserDefaults(suiteName:)` read `nil`. So
  a mount on its own suite sees neither the leaked value nor anyone else's writes.
- **The cycle was not reproduced, and the synthetic attempt does not count against it.** A rig
  with an editor set to spell-check, focus moved by a `@FocusState`, and a second process flipping
  an observed standard-domain key ran thousands of rounds without the cycle. But the same lldb
  breakpoint, on `NSSpellCheckerCheckString`, **never fired in that rig**: `insertText` into a
  window that is never key apparently schedules no check, so the rig never met condition 1. Two
  concurrent copies of the 09:15 filter (one with `NSZombieEnabled`) also finished green, once.
  **The cycle rests on the 09:15 sample.**
- **Several of those runs stalled, and none of the stalls was the cycle.** Each sample showed main
  busy, not blocked: contending CFPreferences' locks under a write every few milliseconds, or
  committing to the window server at a load average of 20–80. A `defaults write` loop against an
  observed key costs every mounted process that much even without a deadlock.

**Fix, first half — editors off the shared domain, 2026-10-15.** Every FileExplorer fixture that
mounts `PlainTextEditor` or `PreviewEditorView` does so on a `ScratchDefaults` of its own, through
`editorTestDefaults` in `Modules/FileExplorer/Tests/FileExplorer/EditorMountDefaults.swift`. That
gives spelling its coded
default (off), gives Wrap Lines and Readable Line Length what a clean machine has, and puts the
editors' `@AppStorage` on a domain no other process writes. A test about a setting writes it to
that suite, as `EditorReadableColumnTests` and `EditorHeaderDoorsTests` already did once they
stopped writing the shared domain. To measure coverage, `makeNSView` temporarily logged every
editor whose `@AppStorage` saw a marker key set only in `swiftpm-testing-helper`. Across the full
package that was 29 mounts in 9 suites before either change, and 0 after both. Dashboard's one
editor-mounting suite already mounted on scratch.

That left text fields: `--filter 'Editor|LineEndingPaths'` still reached `NSSpellCheckerCheckString`
at least 25 times, and every main-thread hit was a field editor resigning.

**Fix, second half — no test process reaches the spell checker, 2026-10-16.** Condition 1 is the
one a test process can remove outright, because the checker has two doors and both are public. The
four test targets that mount UI (Design, Settings, FileExplorer, Dashboard) link
`TestProcessTextChecking`, a test-only Objective-C target in the Design package. A constructor in
it runs when the bundle loads, before any test, and replaces `NSSpellChecker`'s
`checkString:range:types:options:inSpellDocumentWithTag:orthography:wordCount:` (the synchronous
check a resigning text view runs on main) and
`requestCheckingOfString:range:types:options:inSpellDocumentWithTag:completionHandler:` (which
queues each `NSTextCheckingOperation`) with versions that find nothing and take no lock. Those two
were every way in: in a full Dashboard run, all 34 `NSSpellCheckerCheckString` calls came through
them, 33 requests (one per operation) and 1 check. Text views still ask, as often as before
(`-[NSTextView checkTextInRange:types:options:]`, FileExplorer 185 → 182, Dashboard 22 → 38); the
answer is just empty. No test reads it. The editors and
the three typing fixtures turn every substitution off, and the spelling tests read the setting, not
underlines. `TestProcessTextCheckingTests`, in each of the four targets, asks the checker about a
misspelt sentence both ways and fails if it finds anything. With the replacement skipped, it failed
both.

Measured with breakpoints on `scoreParagraph` and `NSSpellCheckerCheckString`, each package's whole
suite launched under lldb from its first test (`swiftpm-testing-helper` run directly, with
`swift test`'s two `DYLD_` paths):

| Test target | Tests | `scoreParagraph` before → after | `NSSpellCheckerCheckString` before → after |
|---|---|---|---|
| FileExplorer | 3424 | 718 → 0 | 181 → 0 |
| Dashboard | 765 | 62 → 0 | 22 → 0 |
| Design | 573 | 0 → 0 | 0 → 0 |
| Settings | 372 | 0 → 0 | 0 → 0 |
| Sync, Events | 3592, 79 | 0, not linked | 0, not linked |
| app target (`SyncCloudTests`) | 1560 | 0, not linked | 0, not linked |

Sync links no UI framework and Events mounts nothing, so neither links the target. The app target
is not linked either, and its 0 is not vacuous: the attached run saw 18 first-responder changes but
0 `insertText` and 0 `checkTextInRange`. Its tests focus fields and type into none. **If one ever
does, link it:** a `- package: Design` / `product: TestProcessTextChecking` dependency on
`SyncCloudTests` in `project.yml` (and `Design` under `packages:`), and a copy of the guard test.
That host is the likeliest place for condition 2, because it shares
`com.abhishekgirish.SyncCloud` with the installed app, which writes that domain as it is used.

**Still exposed: the shipped app.** Its Go to Line, rename and filter fields check like any
field editor; turning correction off would not change that, since a field editor with correction
off still checks (above); and the replacement here is not an option for an app whose editor offers
Check Spelling. Condition 2
needs another process writing `com.abhishekgirish.SyncCloud`: a `defaults write`, or an app-target
test run. Each window is milliseconds wide and it has not been seen in the app. The tell below
applies there unchanged.

**Tell.** 0% CPU and many tests in flight. `sample <pid>` shows `_pthread_mutex_firstfit_lock_wait`
under `NSSpellCheckerCheckString` on the main thread, and `UpdateGroup.enqueueAction` under
`UserDefaultObserver` on an `NSTextCheckingOperation` thread. **In a package test process that stack
means the target does not link `TestProcessTextChecking`**, and its `TestProcessTextCheckingTests`
will be red or missing. In the app, or to find who supplied condition 2, look for the outside
writer, the half you can see: another test process alive at the time, or
`pgrep -fl 'defaults write'`. `defaults read swiftpm-testing-helper` shows what the shared domain
is feeding mounts that still read it.

**See.** `Modules/Design/Sources/TestProcessTextChecking`, whose header says what it replaces and
why; `editorTestDefaults` in `Modules/FileExplorer/Tests/FileExplorer/EditorMountDefaults.swift`;
`PlainTextEditor.makeNSView` and `PreviewEditorView.update` for where the setting reaches the text
view; "Process-wide state, and suites running in parallel" for the in-process half of the same
sharing; "A named NSPasteboard is machine-global, so two test PROCESSES share it" for the same
shape on another shared resource.

### 31. An attribute dictionary freed under a projection's own run — cause not found

*Was "Four projections at once, and a shared attribute dictionary freed under one of them" until
2026-10-26, when it came back with one projection building and the lock below held.*

**Symptom.** FileExplorer's test process exits with `signal code 6`. There is no `✘` and no
`Test run with` line. A rerun passes. Seen twice, both times in the first seconds of a full run:

| When | Where | Seconds after launch | Test on the faulting thread |
|---|---|---|---|
| 2026-10-17 | CI run 39081784223, attempt 1, at `23e62ed1`, load about 15 | under 1 | `MarkdownProjectionTests.indentedCodeHtmlAndRulesAreNotText` |
| 2026-10-26 07:58 | a local full run (`swiftpm-testing-helper-2026-10-26-075845.ips`) | 2.1 | `MarkdownProjectionOneAtATimeTests.aProjectionWaitsWhileAnotherIsBuilding`, projecting its `previous` note before it takes the lock itself |

Both reports have the same faulting stack:

```
cooperative  MarkdownProjection.project → oneAtATime (2026-10-26 only) → Builder.run → append
               → readOnlyBlock → endBlock
               → -[NSMutableAttributedString addAttributes:range:]
               → -[NSAttributeDictionary mutableCopyWithZone:]
               → -[__NSPlaceholderDictionary initWithObjects:forKeys:count:]
             NSInvalidArgumentException: attempt to insert nil object from objects[0]
```

Both notes are short, with an HTML block and then indented code: two read-only blocks, each built
by `readOnlyBlock`. In the 10-17 note the HTML block comes first; in the 10-26 note it comes after
a heading.

**What the 2026-10-26 report rules out.** The lock below was in, and the faulting thread held it:
`MarkdownProjection.oneAtATime` is on its stack. The only other projection, another case of the
same test, was parked in `-[NSRecursiveLock lock]` under `oneAtATime`. The main thread was in
`FoldAllToggleBindingTests.mount`, making a kind of `NSHostingView` for the first time
(`-[NSResponder init]` → `_NSDPClassInfoForClass`), with no preview mounted. Seven threads were parked on
`EditorFileStore.WriteOrder`, and one was listing a folder for `Logger.shared`'s first use. No thread
but the faulting one was in attributed-string or text code. So:

- **Other projections building are not needed.** None could build while the faulting thread held
  the lock, and none was. The 10-17 reading, that another projection freed a dictionary the run
  shared, does not fit. Another test dropping a finished projection's strings is still possible,
  but see the uniquing below.
- **A mounted preview's TextKit work on main is not needed.**
- **The dictionary went bad before the copy began.** The run got it microseconds earlier, from
  `appendText`'s `addAttribute(.previewReadOnly, …)` over text set in `{font: monospaced 12}`, on
  the same thread.

**What the frames say** (10-17, unchanged by 10-26). The run being copied holds
`{font: monospaced 12, previewReadOnly: true}`, both non-nil. `mutableCopyWithZone:` reads the
dictionary's count at offset 8 and each entry's key and value from offset 16 on (disassembled,
macOS 27.0.1). It then hands them to `initWithObjects:forKeys:count:`. The call that threw is the
one for a count between 1 and 40, so the object read as a small count with a nil first value. That
is a freed dictionary whose memory now holds something else, and `out` still pointing at it. This
is a use after free in the framework. Nothing we passed was nil.

**The uniquing reads as safe** (disassembled 2026-10-26, macOS 27.0.1). AppKit uniques attribute
dictionaries across the process: `+[NSAttributeDictionary newWithDictionary:]` looks an equal one
up in one `NSHashTable` of weak references, under `attributeDictionaryLock`, and hands back the one
it finds (measured: two threads that each made `{font: monospaced 12}` got one pointer). The lookup,
`-[NSConcreteHashTable getItem:]` → `hashProbe`, reads each slot with Foundation's
`startReadARCWeakAutoreleasingWithSentinelAt`, an autoreleasing weak load, which returns nil for a
dictionary already deallocating. A found dictionary is retained before the lock is let go.
`NSAttributeDictionary` overrides neither `retain` nor `release`, and its `dealloc` releases its keys
and values and leaves the table to weak zeroing. So a release racing a lookup cannot hand out a
dying dictionary, which fits every rig below staying up. The path that frees it early was not found.

**Ruled out: nothing in the walk is shared.** Each call has its own `Builder`. Paragraph styles,
text lists and attachments are made per block. Fonts come from the system's cache and never
change. The one static that changes, the entity cache, is behind its own lock. No attribute value
is changed after it is set: every `NSMutableParagraphStyle` in the package is configured before it
goes into a string. No code in FileExplorer, Design or Sync calls `CFRelease` or
`takeRetainedValue()`; the one `CFAttributedStringGetAttributes` call
(`MarkdownProjection.attributes(of:at:_:)`, in `MarkdownProjectionReuse.swift`) is imported as
managed and only reads.

**Not reproduced.** None of these aborted:

| Rig | Volume |
|---|---|
| Standalone, 8 threads building the HTML block's runs as `endBlock` does | 4.8 M blocks, 3 runs |
| Standalone, 2, 3 and 4 threads making and dropping strings with **equal** attributes, so one thread frees what another looks up | 10.5 M rounds, 45 s |
| Standalone, half the threads measuring `size()` beside half building, 2, 4 and 8 threads | 45 s |
| 300 cold processes, 16 threads released at once into their first fonts and strings, as at a run's start | 4,800 thread starts |
| In the test bundle, 10 threads projecting the corpus and the crashing note | ≈ 440 k projections, 3 runs |
| Standalone, one thread, the HTML block's three steps (`append`, `addAttribute(previewReadOnly)`, `endBlock`'s `addAttributes`) under `NSZombieEnabled`, to catch an over-release in the sequence itself (2026-10-26) | 300 k blocks |

What no rig has had is a full FileExplorer run's first seconds, when about three thousand tests
start at once, and both sightings were there.

**One projection at a time, 2026-10-17 — not the fix.** `MarkdownProjection.oneAtATime` takes one
`NSRecursiveLock` around `project(_:style:)`, `projectSlice` and `reread`, the only places that
build or splice a projection's runs, and `MarkdownProjectionOneAtATimeTests` checks each door.
It removed the one kind of concurrency the 10-17 report pointed at, and the 10-26 abort happened
inside it. It stays: the app projects on the main actor and nowhere else, so its lock is never
contended there.

**Tell.** Signal 6 with no `✘`. The `.ips` shows `NSInvalidArgumentException`,
`attempt to insert nil object from objects[0]`, thrown by `initWithObjects:forKeys:count:` under
`-[NSAttributeDictionary mutableCopyWithZone:]` under `Builder.endBlock`. The test on the faulting
thread is a bystander. A green rerun proves nothing.

**If it comes back,** copy the `.ips` somewhere kept before reading it: `DiagnosticReports` had
already dropped the 10-17 one by 10-26. Note the seconds from `procLaunch` to `captureTime`, the
faulting thread's note, and every other thread's test frames, and add a row above. A third sighting
outside a run's first seconds would break the one pattern there is.

**See.** `MarkdownProjection.oneAtATime` and its doc comment; "Process-wide state, and suites
running in parallel" for the same shape on Swift statics.

### 32. A threshold measured with its padding in sits inside the jitter it was set against — FIXED

**Symptom.** `SettingsLayoutTests.aVersionTooWideForTheRailReallyDoesWrapIt` red in the full
Settings run, green on a same-SHA rerun and under `--filter`:

```
✘ … SettingsLayoutTests.swift:1003: Expectation failed: extra >= oneLine / 2
  ↳ A version far too wide for the rail adds only 11.0pt to it against a 25.0pt line
```

Seen twice, with the same numbers both times: CI run 39084509812 at `4f9b7ddb` (2026-10-18) and run
39303416880 at `0964ce60` (2026-10-19). No commit near either touched Settings or its dependencies.

**Mechanism — two halves, and only together do they fail.**

- **The rail's height jitters by 1–2pt.** The rail holds the search field, a `TextField` that AppKit
  measures. In a busy full-package run that field now and then reads 26pt instead of 25pt: 3 of 600
  samples across ten runs at load 21–99. It never moved in 2,000 samples with nothing else in the
  process, nor in 12,000 across three quieter full runs, and a test that kept stealing text-field
  focus in another window did not move it either. What sets it off was not found. CI's two reds are
  the one-character baseline rail measuring 2pt over a nil→overlong span that matched this machine
  exactly (36pt both ways). The same 2pt is what `237ee1d6` (2026-08-02) met on the same rail.
- **The threshold left 0.5–3pt for that jitter, where its comment promised half a line.** "One
  line" was `rail("1") − rail(nil)`, which is the line plus the 10pt of padding the rail puts around
  it: 21 / 23 / 25 / 26pt at Small / Default / Large / Largest. A wrap adds only the line, 11 / 13 /
  15 / 16pt. Half the padded figure sat 0.5 / 1.5 / 2.5 / 3pt under a real wrap, so 2pt on the
  baseline was enough to make `13 − 2 = 11` fall short of `(23 + 2) / 2 = 12.5`.

**Ruled out as the trigger, 2026-10-19: none of these moves the search field.** Each was laid out
in the test process at the default size: Increased Contrast, Reduce Transparency, the dark scheme,
`dynamicTypeSize` xSmall and xxxLarge, `controlActiveState` inactive and key, the Frosted lens,
legacy scrollers (`preferredScrollerStyle` swapped in), and `AppleShowScrollBars`,
`AppleKeyboardUIMode` and `AppleInterfaceStyle` in the argument domain. Two do move the rail, but
through the tab list and on every rail at once: `displayScale` 2 or 3 makes the tab list 1pt
shorter (the offscreen host lays out as 1× by default), and `legibilityWeight` `.bold` makes it 2pt
taller. The CI launch itself, an x86_64 runner spawning `arch -arm64 swift test`, was not tried: a
sandboxed session could not run the x86_64 shell.

**Fix.** Both version-line tests take "a line" from the bare `.caption2` line
(`SettingsLayoutTests.versionLineHeight`), not from a difference of two rails. The threshold is now
5.5–8pt, and both sides of it keep 5.5–8pt over the 2pt seen. **Proved:** adding 2pt to the
baseline rail reproduces CI's exact message ("11.0pt against a 25.0pt line") on the old code and
stays green on the new code. Each test still catches what it is there for: `.lineLimit(1)` on the
version line fails the probe ("0.0pt against a 13.0pt line"), and an overlong `versionMarker`
fails the fit test's height half at all four sizes.

**The general shape.** A threshold taken as "half of X" is only as safe as X is the thing the
failure adds. Measure the quantity a defect costs, not that quantity plus whatever is fixed around
it, and work out the headroom on **both** sides from the worst jitter seen, at every argument a
parameterised test runs.

**Tell.** A wrap/no-wrap or present/absent test that measures a difference of two `fittingSize`
readings fails by about 2pt with the numbers repeating. Check what the threshold is half of before
blaming the layout.

### 33. A wedge guard that counts time spent waiting for the main thread — FIXED

**Symptom.** `SaveAsPDFRenderTests` red in the full FileExplorer run on CI, green under `--filter`
and on the next two pushes. CI run 39359165278 at `ce8edee1` (2026-10-20, load average ~35):

```
✘ aOnePageMemoIsOnePageOfText() … Caught error: SaveAsPDFFailure(reason: "macOS couldn’t read it")
✘ aOnePageMemoIsOnePageOfText() failed after 77.614 seconds with 1 issue.
✘ aDeckOfPicturesOfWordsIsSearchable() … pageText(document, 0) → ""
✘ aDeckOfPicturesOfWordsIsSearchable() failed after 11.120 seconds with 2 issues.
```

**Mechanism.** The suite is `@MainActor`, and in the full package run it shares the one main
thread with every other main-actor suite. Each `await` in a render queues behind them. Even on
**green** CI runs `plainTextKeepsItsCharacters` (no Quick Look, no WebKit; 0.002 s alone) took
101 s, the memo took 37–42 s and the ten `qlmanage` calls 150 s, against 8 s for the whole suite
alone. The render had two wall-clock guards that count that waiting:

- **`WebPDFView.load` gave up at 30 s.** Its timer and WebKit's `didFinish` both need the main
  thread; whichever gets it first decides. Reproduced 2026-10-19 (full package run, 20 `yes`
  spinners, load 70–80): `qlmanage` took 1.0 s, then the load of the memo's one small local page
  returned `false` after **45 s** and the test failed with CI's exact error after 90 s. `qlmanage`
  itself stayed at 0.4–1.6 s throughout, so Quick Look is not the slow part.
- **`picturesDecoded` capped the wait at 10 s**, and a cap that fires draws the pictures still
  decoding blank. On a deck of picture slides that leaves no words for Vision to read. Setting the
  cap to 0 reproduces CI's message exactly (`pageText(document, 0) → ""`), and the red's 11.1 s is
  10 s plus the test's usual 1.5–2.3 s on green CI runs. That fits, but it was not caught in the
  act: no run here logged the cap firing. *Correction, 2026-10-21:* this cap is not a main-thread
  guard at all — its `setTimeout` runs in the web process, which the app's busy main thread does not
  slow — and the blanks it was blamed for turned out to be the background decodes below.

**Fix.** Both guards are there for a wedge, not a slow load, so they cost nothing when the load
succeeds: `load` now waits 120 s and ends at once if the web process dies
(`webViewWebContentProcessDidTerminate`, which nothing handled before); `picturesDecoded` waits
60 s and logs a warning when it gives up, rather than drawing blanks silently. **Proved** on the
full package run with 20 spinners: the memo, red at 45 s before the fix, passed after 145 s in the
first run after it, and a second run at load up to 145 went fully green (3,927 tests).

**The picture blanks: a snapshot that lands on WebKit's own background decode — FIXED
2026-10-20.** In two full runs after the guard fix, picture tests failed with no cap warning, so
`decode()` had resolved:

- `aDeckOfPicturesOfWordsIsSearchable`: one slide's page empty, after 2.3 s once and 9.4 s once (a
  different slide each time).
- `everyPictureIsDrawnWhole("FourPictures.xlsx")`: `picture 3 of [824776, 824776, 442769, 821632]
  is blank or cut`. Picture 3 spans two of the sheet's bands, and one band drew it blank: 54%.

*Mechanism.* `createPDF` paints with `PaintBehavior::Snapshotting`, which decodes synchronously,
but WebKit never decodes one frame on two threads: when a background decode of the picture is
already queued, the snapshot draws **nothing** for it
(`BitmapImageSource::nativeImageAtIndexCacheIfNeeded`, "Never decode the same frame from two
different threads"). The queued decode comes from the hidden view's own paint: WebKit lets go of a
decoded picture soon after it last drew it, and an `<img>` left at `decoding = auto` that is large
is then asked for again in the background, at the size it is drawn. A loaded machine leaves seconds
between the decode and the snapshot, and that is enough.

*Caught in the act.* A probe logging each captured page's image XObjects and dark pixels showed it
(2026-10-20):

- In a loaded full run (load up to 64, green), the sheet's pictures 3 and 4 went into the PDF at
  864 × 648 rather than their own 1920 × 1440: re-decoded at the drawn size between the decode and
  the snapshot, in time that run.
- Alone, at no load, a 3 s pause between the decode and the capture made it happen: the deck's
  first slide came out with no image and no dark pixels, Vision read 0 lines, and the test failed
  with CI's exact message; the second slide went in at 1440 × 1080. Only the first capture after
  the decode is exposed: in four rounds of captures from one view, every later one drew the
  re-decoded picture.

*The same queue behind a resolved `decode()`.* With `decoding = 'sync'` set in `picturesDecoded`,
after the load, pictures still came out blank under load with `decode()` resolved and every
picture `sync`: `FourPictures.docx`'s first picture as on CI, the sheet's four at once, and in a
full run `recognisedTextDrawsNothing`'s first slide. The load's own paints had already queued
background decodes at the drawn size, and `decode()` does not wait for its own: WebKit settles
every waiting `decode()` when *any* decode of the picture finishes
(`BitmapImageSource::imageFrameAtIndexAvailable` → `callDecodeCallbacks`). So it settled on the
paint's decode while its own, full size, was still queued, and a queued full-size decode blanks a
snapshot of any size. This is also how Word's print lost picture 1 on CI (runs 39519472205 and
39525805411, `[0, 526892, 528570, 526892]`), by the same rule as far as the source shows: it is
the first picture below the view's 1000 px, alone on printed page 2.

*Fix.* A document-start user script in the app's world, `WebPDFView.syncPictures`, sets
`decoding = 'sync'` on every `<img>` as the parser adds it, before anything is painted, so no
paint ever queues a background decode; `picturesDecoded`'s own decode is then the only one, and
`pagePDF` waits for it before printing too. Tests: `everyPictureIsSyncOnceLoaded`, and
`aPictureSlideDrawnLateIsStillDrawn`, which renders the deck five times with a 3 s pause before
drawing. **Mutation-checked:** without `decoding = 'sync'`, 19 of 20 paused renders across four
runs drew a blank slide, and with the script removed both tests fail (five of five renders
blank); with it, none of 15. `aMixedDeckReadsOnlyItsPictureSlides`, red on CI at `8a3b503a` (run
39535439483) with its picture slide unread, is the same route.

Measured on the four picture tests (`everyPictureIsDrawnWhole` for Word and the sheet, and three
picture-deck tests) under 30 `yes` spinners, with other sessions' builds pushing load to 80–310
(2026-10-20):

| Build | Word: picture 1 blank | Sheet: all four blank | Deck slide unread |
|---|---|---|---|
| `sync` set after the load, no wait before Word's print | 1–2 of 16 (CI's exact numbers once) | 2 of 16 | not run |
| `sync` set after the load, Word waits | 1 of 42 | 0 of 42 | not run |
| `sync` from document start (shipped), load 63–180 | 0 of 30 | 0 of 30 | 0 of 90 (three tests × 30) |

Not two `requestAnimationFrame`s: a paint after the decode is what queues the background decode,
so waiting for one does not help, and a window that is never shown throttles its frames.

**Also seen, explained 2026-10-21.** One loaded full run (load 60–110, on battery) wedged: four
tests, `everyPictureIsDrawnWhole` among them, started and never ended, the process idle at 0% CPU
with every thread parked, for 50 minutes until killed. WebKit's log showed the Word print it was in
had finished and its page closed. That fits "A hidden web view's process drops to the background
band, so load starves its draws": a later draw or script call sent to a web process WebKit had
moved to the background band, starved by the load, with no deadline on the wait. It was not caught
in the act; the same shape was, in `createPDF`, and reproduced. The same run failed
`aOnePageMemoIsOnePageOfText` and `anOldWordFileIsText` with "macOS couldn't read it" after
241–292 s: the load guard's 120 s, at a load above the 145 it was proved at. Since that fix the
load's guard is a `WedgeGuard` too, which does not count time `didFinish` spends queued for the
main thread.

**Tell.** A Save as PDF test failing with "macOS couldn't read it" or a picture page's empty text,
in a full run only. Before blaming Quick Look, compare the suite's duration with a
`--filter` run: a gap of 50× or more means it is waiting for the main thread. A picture blank or
cut with no cap warning means a picture was drawn with a background decode queued: one not set
`sync` by `syncPictures` — a picture drawn as a CSS background, which the attribute does not
cover — or a view made without it.

**Red again 2026-10-25, and not this mechanism.** The picture-deck tests failed fast (0.4–4 s) with
no words read, under `--filter` too: Vision had thrown, see "Vision's Neural Engine refuses text
requests for hours". A picture-deck red that is fast and has `e5rt` in the output is that one.

### 34. A pixel probe that calls `colorAt` per pixel, so load stretches it into a hang — FIXED

**Symptom.** A full FileExplorer `swift test` stops making progress: one core at 100%, no test
output for 45–70 minutes and more, at load averages of 60–145 (twice, 2026-10-19 and 10-20). It
looks like [mechanism 8](#8-the-wait-that-hangs-instead-of-failing), but `sample` shows the main
thread inside `OverviewCardConsistencyTests.assertVerbsLineUp(width:scale:)`, in its
`isButtonFill` / `trailingEdge` walk and `-[NSBitmapImageRep colorAtX:y:]` below it, not in a
wait. In other loaded runs the same test finished.

**Mechanism.** Not a hang: the walk is two bounded loops with no wait in them. It was simply a
lot of work for a Debug build. Each of its five renders walked every row (2,660–3,290 at 2×) from
the card's trailing edge to x = 0, calling `colorAt` on each pixel: 2.0–2.8 million calls a
render, 11.7 million for the two tests, about 13 s of CPU alone at load 30. Under 20 `yes`
spinners (load ~65) the two tests took 104 s. That stretch is ~5×; the 45-minute stalls needed
far more, and they were not reproduced here. A live `sample` of a loaded full run caught the test
inside `colorAt`, partly in `@synchronized` (`id2data`) and `CFString` hashing, so its per-call
cost likely grows in a full run's process. It left the test within about 4 minutes in that run.

**Fix.** Ask `colorAt` once per distinct colour and stop walking a row once it is past the
gutter. The walk reads each pixel as one 32-bit word and caches the verdict per word (a render
has 26–137 colours); a row with no button under way past `width - 140` ends there, since any
edge further left was discarded anyway. That is 0.6–0.76 million cheap reads a render instead of
2–2.8 million `colorAt` calls: 0.06–0.17 s a render instead of 2.1–4.5 s, and 1.1 s for both
tests under 20 spinners instead of 104 s. **Proved** behaviour-preserving: the old walk and the
new one were run on the same five renders and gave identical rows (214 action rows each). A
12pt mutation of the hosted `Set up…` fails old and new alike, at the same values.

**Tell.** No output, one core pegged, and `sample` names a test's own pixel loop rather than a
`Task.yield` or a lock. Count the calls before blaming the machine: a probe that calls
`colorAt` per pixel over a full render costs 1–2 µs a call in Debug, before load.

### 35. A main-queue defaults observer parks every scratch-suite wipe on the main thread — FIXED

**Symptom.** Only the app-target step red, one test, at its 5 s hold:

```
✘ aDefaultsWriteOffTheMainThreadNeverWaitsForIt() … Expectation failed: written.wait(timeout: .now() + 5) == .success
✘ aDefaultsWriteOffTheMainThreadNeverWaitsForIt() failed after 7.775 seconds with 1 issue.
```

CI runs 39515171126 (`d82ea67b`) and 39543590981 (`8956ef9f`), 2026-10-20. Green alone in 0.04 s.
It starts 0.07 s into the run, with ~1,680 tests, and the main-actor tests around it "pass after
7–8 s" because they waited out its hold.

**Mechanism — two of them, one real.**

1. **Real, and deadlock-shaped.** 9d170742 made the PDF reader's layout (`EditorPDFViewState`) and
   its saved signatures (`EditorPDFSignatureStore`) follow their defaults with `queue: .main`. A
   queue-based observer makes the poster wait until main has run it. Some observe `.standard` in
   the app host: `PDFFillSignCommand.idle`, a static that lives for the run once built, and the
   default-argument instances `ShortcutCommandsTests` and `PDFMenuBarTests` make. `wipeDefaultsSuite` calls
   `UserDefaults.standard.removePersistentDomain(forName:)`, which posts the change with `.standard`
   as its object. So every scratch-suite wipe off the main thread waited for main. A `sample` at
   the 5 s mark (load ~170) found 11 stacks `wipeDefaultsSuite → postNotificationName →
   -[NSOperation waitUntilFinished]`, holding all ten user-initiated threads of the cooperative
   pool. It was not the test's own write: a write to a fresh suite posts with that suite as the
   object, and an observer filtered on another instance never sees it (measured in a probe).
2. **Load timing, in the harness.** The test wrote from a `DispatchQueue.global()` block, a
   default-QoS pool thread. Its timestamps showed the block **never started** in 5 s in all three
   red runs, and with (1) fixed it still waited 0–3.9 s for a thread, once more than 5 s. Samples
   1 s in found the ten user-initiated threads CPU-busy with the opening burst's source scans, and
   GCD admits no default-QoS block while higher QoS fills every core. The write itself took 5–20 ms.

**Fix.** (1) Both observers go through `observeDefaultsChanges(of:_:)` in FileExplorer, which
observes on the posting thread: a post on main rereads on the spot, as before, so Settings ▸ Reset
All Settings still reaches an open reader at once; a post from any other thread schedules the
reread and returns. `aWriteOffTheMainThreadNeverWaitsForTheReader` and `…ForTheSignatures` hold main
while another thread writes. Put back on `queue: .main`, both fail at 5 s; with the off-main branch
dropped, both fail at 15 s waiting for the reread. `noDefaultsObserverMakesItsWriterWait` (app
target) fails on any `addObserver` that names `UserDefaults.didChangeNotification` and is not
registered `queue: nil`, anywhere in `MacApp` or a package's `Sources`. It reads only that argument
list: a name held in a constant, a Combine `publisher(for:)`, KVO on `UserDefaults`, or a `queue:
nil` block that waits on main inside slip past it (none exist today, checked 2026-10-21). (2) The test's writer is a `Thread` of its own. With the
`[glass]` line's observer put back on `queue: .main` it still fails at 5 s, the thread having
started at 0 ms.

**Proved.** Before: 3 of 3 full app-target runs red at load 90–170. With (1) only: 6 of 7 green
at load 30–135, the block starting 0–3.9 s late, and 1 red (a run that also `sample`d the host 1 s in). With both: 5 of 5 green at load
34–124, three of them under 20 `yes` spinners; the writer started at 0 ms every time and its write
took 8–28 ms. Not run on an idle machine: other sessions kept the load above 30 throughout.

**Tell.** A test that holds the main thread fails, and `sample` shows pool threads in
`_CFXNotificationPost → -[NSOperation waitUntilFinished]`: something observes a notification with
`queue: .main` that is posted off main. Find the observer by the notification name in the frames
above the post. A block on a global queue that never starts is the pool, not the code under test;
timestamp the block's first line before blaming what it calls.

### 36. A Quick Look run that waits for ever on its own reply — FIXED

**Symptom.** `SaveAsPDFRenderTests.quickLookStillWritesHTML(_:)` red for one argument, in a full
FileExplorer run with other sessions' builds beside it, green on rerun:

```
✘ Test quickLookStillWritesHTML(_:) recorded an issue with 1 argument name → "FourPictures.xlsx" at SaveAsPDFRenderTests.swift:104:24: Expectation failed: await QuickLookHTML.preview(of: …, into: scratch)
✘ Test quickLookStillWritesHTML(_:) with 10 test cases failed after 252.543 seconds with 1 issue.
```

Twice on 2026-10-21: that run (load ~35, another session's FileExplorer suite in the other slot), and
one in which `"Memo.doc"` failed and the ten cases took **64.3 s**. The suite is serialized, and
`QuickLookHTML.preview` gave `qlmanage` 60 s: one case used all of that, and the nine others took
about 4 s between them.

**Mechanism.** Not load, and not a guard counting queued time. Now and then `qlmanage` stops for
good. Its main thread idles in the run loop, and its file-coordination thread
(`-[QLPreview retrieveDisplayBundleIDForAdvancedUsage:completionHander:]`) waits in
`-[QLPreview synchronousGetData]` on a semaphore for a reply from its own in-process Quick Look
server, which never sends it. Nothing is running, so waiting longer does not help, and the guard
kills it with no preview. Caught three times in 8,503 runs, eight at a time, under 15 `yes` spinners
(load 16–85, other sessions' builds included; 2026-10-21): `FourPictures.xlsx`, `Memo.doc` and
`Memo.docx`, each `sample`d 15 s in with the same stack. That is about one run in 2,800. A full
`SaveAsPDFRenderTests` run calls `qlmanage` a few dozen times (22 before the deck tests), so roughly
one suite run in a hundred meets a wedge. The next run of the same file worked every time. Not measured on an idle machine: other sessions kept the load above 15.

Load alone does not slow `qlmanage` much. Twenty at once under 30 spinners (load 32–66) took 6 s
median and 8.3 s at most, 100 of 100 with a preview; in the 8,499 runs that finished, the slowest
took 4.4 s. One more run in that batch died of SIGKILL after 1.1 s with no preview, from something
not found. The probe did not send it.

**Fix.** `QuickLookHTML.preview` treats a run its guard had to kill as wedged and runs it once more,
in an emptied folder (`attempts = 2`). It gives each run 30 s, not 60, which is still 3.6× the
slowest normal run seen; a slow run killed by mistake costs only a second run. The guard records that
it fired, because `qlmanage` handles SIGTERM and exits 0: its status cannot tell a killed run from a
clean one. It sends SIGKILL 5 s after a SIGTERM that is ignored. A run that finishes with no
preview is not retried. In the app, the wedge cost a workbook or deck its PDF ("macOS couldn't read
it") and a Word file its pictures (the text-system fallback), after 60 s.

`QuickLookHTMLTests` puts a stand-in for the tool in place: it wedges (idle, `exec sleep 600`) on
the runs it is told to and writes a bundle on the others. **Mutation-checked:** with
`attempts = 1`, `aWedgedRunIsKilledAndRunAgain` and `aWedgedRunThatIgnoresSIGTERMIsKilledAnyway`
fail. Without the folder emptied, both fail too: the dead run's half-made bundle is taken for the
second run's, and it has no `Preview.html`. Without the SIGKILL, the second waits until the
stand-in's `sleep` ends and fails its 120 s bound. **Proved** on
the real tool: 7,402 runs of `QuickLookHTML.preview` eight at a time, under 15 spinners at load
72–111, all made a preview. Two wedged (`Memo.doc`, `FourPictures.xlsx`) and came back on the
second run, 31–33 s in. The slowest of the rest took 6.5 s.

**Tell.** One argument of `quickLookStillWritesHTML`, or a Save as PDF render, failing at the
guard's bound, with its siblings fast. Here the case took 60 s while the other nine took 4 s between
them. `sample` a `qlmanage` that has run past 15 s: an idle process with a thread in
`-[QLPreview synchronousGetData]` is this. Since the fix, a recurrence logs "Quick Look didn’t finish
in 30 s (try 1 of 2)" and passes; a red needs two wedges in a row.

### 37. A hidden web view's process drops to the background band, so load starves its draws — FIXED

**Symptom.** A loaded `SaveAsPDFRenderTests` run stops making progress and never fails: the test
process idle at ~0.1% CPU, its main thread idle in the run loop, and `swift-inspect
dump-concurrency` showing the one live test task in `WebPDFView.pdf(of:)` ←
`SaveAsPDFRender.slidesPDF(_:pause:)` ← `aPictureSlideDrawnLateIsStillDrawn`, resumed from inside
WebKit. 2026-10-21, 30 `yes` spinners, load 70–113: 14 minutes, until killed. No
`webViewWebContentProcessDidTerminate`, no error, nothing in the log.

**Mechanism.** Not a dead or wedged web process: a starved one. A `WKWebView` in a window that is
never shown is a hidden page, and WebKit holds a foreground RunningBoard assertion on its web
process only while it has foreground work for it: a client navigation (the load), or a script call
until it answers (`WebPageProxy::runJavaScriptInFrameInScriptWorld`). About a second after the last
of these ends, RunningBoard gives the process `role: Background`. `createPDF`
(`WebPage::drawToPDF`) and the print take no foreground activity of their own, so a draw sent after
that runs in the background band, and a machine whose cores are busy at normal priority gives it
next to nothing. WebKit has no deadline of its own on `createPDF`, so the wait has none either.

- *Reproduced* (2026-10-21, `scripts/build-slot --exclusive`, 30 spinners, load ~85), first round,
  at the same test: RunningBoard logged the slide's web process `running-active (role: Background)`
  1.1 s after its load, the test's 3 s pause sent `createPDF` 2 s after that, and it answered after
  **231.5 s**. Throughout, the process was alive and its main thread runnable at priority 4 inside
  `WebPage::drawToPDF` → `PDFImageEmitData`, writing the slide's picture: 0.21 s of processor in
  4.5 minutes. Every earlier draw in the run was sent within that second and took 0.00–0.04 s.
- *Measured at no load:* the process's task priority 4 s after a load is 20, against 31 while a
  script call is open.
- *Why nothing reports it:* with the web process stopped outright (`SIGSTOP`), `createPDF` answered
  62 s later, the moment it was let go, and WebKit said nothing in between. Alive but not running
  looks the same as working.

**Fix.** Two parts, in `SaveAsPDFRender.swift`:

- *The cause.* After a load, `WebPDFView.holdForeground()` opens a call of the app's own script
  whose promise settles only at `close()`, so WebKit keeps its foreground activity for the view's
  whole life and every draw and print runs at a foreground priority. Test:
  `aViewsWebProcessKeepsAForegroundPriorityAfterItsLoad`, which fails without the hold (20 against
  31).
- *The guard.* Every wait on WebKit — the load, each script call, `picturesDecoded`, `createPDF`,
  the print — goes through `WedgeGuard`, which counts only time the main thread was free: it ticks
  on the main run loop and counts each gap between ticks only up to two ticks, so time an answer
  spends queued behind other main-thread work is not counted against it (see "A wedge guard that
  counts time spent waiting for the main thread"). After 120 s counted, the call fails with
  "macOS stopped answering while drawing it" and a warning naming the step. Tests:
  `aWebProcessThatNeverAnswersFailsEachCallInWords` (the process stopped; a backstop lets it go at
  120 s, so a guard that never fires fails the test rather than hanging it) and
  `aWedgeGuardDoesNotCountTimeTheMainThreadWasHeld`. **Mutation-checked:** with `createPDF`
  unguarded the first fails at its backstop with the 9,204-byte page WebKit drew once let go; with
  the gap uncapped the second fails, the guard running out the moment the main thread is free.

One trap found on the way: the print's `didRun` selector is called on AppKit's own print thread
(`-[NSConcretePrintOperation _continueModalOperationToTheEnd:]`), not the main one.

**Proved** under the same load (2026-10-21, `--exclusive`, 30 spinners, load 61–88): six
`SaveAsPDFRenderTests` runs, all green, `aPictureSlideDrawnLateIsStillDrawn` in 18.2–18.8 s each
(15 s of it its own pauses). Their 216 `createPDF` calls and 30 prints took at most 2.84 s; the
guard never fired. Before, the first such run sat in one `createPDF` for 231.5 s.

**Tell.** A Save as PDF test that stops with no verdict, the process idle and its task in
`pdf(of:)`, `print` or a script call: `ps -M -p <web process>` shows priority 4. Since the fix it
reads "macOS stopped answering while drawing it" after 120 s, and a warning names the step.

**`aWebProcessThatNeverAnswersFailsEachCallInWords` red 2026-10-25, and not this mechanism.** The
three guards fired as they should; the test compared every warning its `LogCapture` heard, and
heard two `[preview] PDF … could not be opened` lines from `PDFPreviewMountedTests` running
beside it (CI run 40218901987). It now compares only lines starting "Save as PDF:" — rule 4 of
"A log assertion reading a window that has already rolled".

### 38. Vision's Neural Engine refuses text requests for hours — a red about the machine, not the display — FIXED

**Symptom.** `SaveAsPDFRenderTests`' text-recognition cases red together — `aDeckOfPicturesOfWordsIsSearchable`,
`aPictureSlideDrawnLateIsStillDrawn`, `aMixedDeckReadsOnlyItsPictureSlides`, `recognisedTextDrawsNothing`
("Vision read no words in the fixture") — **fast**, in 0.4–4 s, with `output.isRecognised` false. Red
under `--filter` too, and on code without the commit under test; a `--filter` run passed and the
same binary failed four seconds later. CI runs 40216946771 and 40218901987, 2026-10-25.

**Mechanism.** Vision threw, and the render read the throw as a deck with no words. The test
process's stderr carries the error, once per request:

```
[VNImageRequestHandler performRequests:] failed. Error: TextRecognition.CRImageReaderError.e5rtError(
  "e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)
```

It is machine-wide. `log show --predicate 'eventMessage CONTAINS "e5rt"'` for that day has **851**
of these, from **09:27 to 12:04**, in every process that asked for text recognition, macOS's own
`mediaanalysisd` first. Over the same window `ANECompilerService` ran almost without a break
(09:20–12:05), logging compile failures (`RasterizeWorkUnit failed`, `temp file allocation failed`),
while `dasd` ran `mediaanalysisd`'s photo analysis and `spotlightknowledged`'s embedding pipelines,
the work macOS saves for when nobody is at the Mac. The two red runs logged the error 34 and 72
times; the green run at 12:00 logged none.

**It is not the display.** The display was off from 10:57:17 to 12:40:55 (`pmset -g log`), and CI
run 40223927503 (12:00–12:24) went fully green inside that window, while the run before it, with
the display just as asleep, went red. The display's state did not change between them; the Neural
Engine's did. Its errors began at 09:27, between the display going off at 09:24 and back on at
09:33. That the reds came while the owner was away fits macOS's idle-time work keeping the Neural
Engine's compiler busy; it was not caught in the act. *Measured at 12:50, after the window:* the
first request from a freshly built probe took **37.5 s** on Vision's own choice of processor and
then 0.09–0.29 s; on the CPU it took 0.10–0.37 s.

**Fix.** `PictureText.recognise` reads a page on Vision's own choice and, when that throws, reads
it again on the CPU (`setComputeDevice` to the request's `MLCPUComputeDevice`), saying so in a
warning. This is a product fix as much as a test one: a reader's Save as PDF in the same window
came out unsearchable in exactly the same way. Test: `aRefusedRecognitionIsReadAgainOnTheCPU`, which
refuses the first read and expects the CPU's to find the fixture's words. **Mutation-checked:**
with the CPU read removed it fails.

Not proved against the live fault, which had ended before the fix was built: the claim is that
a CPU request does not create the Neural Engine's precompiled operation, the call that failed.

**Tell.** Several OCR tests red at once, fast, with `e5rt` in the test output. Count
`log show --last 2h --predicate 'eventMessage CONTAINS "e5rt"'` by process: if `mediaanalysisd` has
them too, it is the machine. Since the fix, look for "text recognition failed … reading on the CPU"
in `~/sync-cloud.log`; "failed on the CPU too" is a new failure.

### 39. A mounted PDF's wait counted seconds while its document waited in the PDFKit lane — FIXED

**Symptom.** `ComparePairViewingTests.anUntouchedPairReportsNoZoomAndKeepsFitting` red with "the
pair never loaded (51 pumps)" after **616 s** (CI run 40214697085, 2026-10-25), and
`EditorContentOpenMountedTests.aPDFResultOpensWithItsFindSearchingForTheWord` red with "found 1
matches" of two (run 40216946771). Both green under `--filter` and on most full runs, but the slow
part is on the green runs too: the Compare test passed after 503–646 s on the other three runs that
day, and the find test after 115–179 s.

**Mechanism.** Both wait for work queued in `PDFKitSerialAccess`'s one lane: `PDFPairView`'s two
opens, and the find's search, one lane turn per page. In a full package run that lane serves every
PDF suite in turn, and some suites hold it on purpose (`LaneHold`, whose own patience was raised
past 30 s for the same reason). The waits were `LayoutPumpWait.pump` bounds, which count seconds
and main-actor turns: neither moves the lane. `db2981980` raised the Compare wait from 5 s to 30 s
on the reasoning that the load itself was slow; the next red ran 616 s and still found the opens
queued. The find's 15 s spin ran out with page two's turn still in the lane, and its result was
discarded, so the test counted the one match page one had landed. `e1a982477` raised that spin to a
90 s bound the same day, on the same reasoning as `db2981980`; the lane wait replaces it.

**Fix.** `LaneWait.pump`: each pass lays the window out, checks, takes a lane turn of its own and
then sleeps for a main-actor turn. The lane is serial and first come, first served, so a pass ends
only after everything queued before it, and the pass floor counts lane passes and main-actor turns
together. All five Compare-pair load waits use it, and so does the find wait, which now
`#require`s its result and reports the matches so far. The existing lane-paced loops in
`EditorPDFReaderChromeTests` and `EditorPDFFillSignTests` already had this shape.

**Tell.** A mounted-PDF test red at a seconds bound, waiting for a document or a search, and slow
on green runs too. Ask what the condition waits for: if it is a lane turn, pace the wait on the lane.

### 40. A park's bound counted seconds while its release waited for scheduler turns — FIXED

**Symptom.** Three Sync tests red together in CI run 40218901987 (2026-10-25), on code no commit
touched, with the whole package taking 46 s instead of its usual 15: most suites finished at ~31 s.

- `FilingBatchReentrancyTests.aSecondFileAllWhileTheFirstIsRunningIsRefused`, `!gateTimedOut.value`,
  after 25 s.
- `UnansweredFolderTests.aSupersededWalkStopsWaitingForTheFolder`, `awaitSignal`'s `result ==
  .success` and then `gate.isParked`, after 24 s.
- `ScanSupersedenceTests.testCancellingScanAbortsTheDiskWalkPromptly`, 3.3 s against a 2 s
  budget, in run 40214697085 that day.

**Mechanism.** Each bound was in seconds and each release was made of turns, the case "Fixed pumps
and fixed sleeps" warns about, in shapes `waitUntil`'s poll floor could not reach:

- `parkUntilReleased` runs on the cooperative pool, inside the operation `enqueueFileOperation`
  runs detached, or inside a classifier. Its `Task.yield()` loop counted pool turns, and its bound
  was 10 s. The FilingBatch release came after the test's
  `for _ in 0..<100 { await Task.yield() }`, a hundred main-actor turns.
- `awaitSignal` and `ParkGate.park` block a thread on a semaphore for 10 s. What they wait for, the
  walk reaching its seam or the test reaching its release, gets there on main-actor and pool turns.
- Two `UnansweredFolderTests` cases asserted "unwound in under 10 s", against a dataless-read
  deadline of 60 s.
- The scan-cancel test raced a 4 s walk with a 2 s budget ("Tests racing a real-time window").

**Reproduced, with load of each shape** — a scratch suite beside the three, `--filter`, never
committed. Main-actor load is four main-actor tests that hold the main thread in 0.25 s chunks
for 40 s, yielding between. Pool load is nine pool tests doing the same.

| Load | Before (`b20505319`) | After |
|---|---|---|
| main actor | **4 of 4 red**: FilingBatch's `!gateTimedOut.value` all 4 (41–44 s), the scan's 2 s budget 2, the superseded walk's 10 s budget 2 | 3 of 3 green |
| pool | **2 of 2 red**: FilingBatch's park; `testScanQueuedFromCancelledPredecessorStillPublishes`' `!gate.releasedByTimeout` | 2 of 2 green |

And across the **whole** `Modules/Sync` package (3,822 tests), arms interleaved in one
`build-slot --exclusive` hold:

| Load | Before | After |
|---|---|---|
| none | — | 2 of 2 green, 26 s |
| main actor | **2 of 2 red**, FilingBatch's park, 54–58 s | 2 of 2 green, 57–65 s |
| pool | **1 of 1 red**, the same, 51 s | 1 of 1 green, 49 s |

**Fix.** Two units, chosen by what the release is made of.

- **Scheduler turns, for the parks.** `SchedulerTurns` in `TestSupport.swift` is a process-wide
  probe: sleep 10 ms on the pool, hop to the main actor, count one. It has the shape of a
  `waitUntil` poll, so it runs at a poll's pace, and it needs both executors, so starving either
  one slows it. `TurnDeadline` passes only when its seconds AND its turns are spent. That is
  `waitUntil`'s rule, for waits that cannot count their own polls. An idle run is held to the
  seconds, as before; a loaded one to the turns. `awaitSignal` (100 turns), `ParkGate.park` and
  `FirstStatGate` (500), and `parkUntilReleased` (500) all use it. So do the two "unwound in under
  10 s" budgets: 100 turns, where sitting out the 60 s deadline costs about 4,700. `parkUntilReleased`
  also sleeps 1 ms instead of yielding, so a held park no longer keeps a pool thread spinning.
- **The release's own signal, for the pump.** FilingBatch now waits for both batches to have
  entered and one to have queued its first move (`activeFileOperationsCount >= 2`), instead of
  pumping a hundred yields.
- **Entries, for the scan.** The walk parks inside entry 2 of 100. The test cancels, releases the
  park, and expects exactly 2 entries handed out: the walk checks for cancellation once per entry,
  so that is the unit its claim is made in.

One wall-clock bound remains, at thirty times the seconds (300 s for the default 10). It is
reached only if the turns stop, which means a wedged main thread, and there it turns a hang into
a verdict. The probe costs one main-actor job per 10 ms; idle, a turn measured 21 ms (466 in 10 s).

**Mutation-checked**, idle unless noted:

| Mutation | Verdict |
|---|---|
| FilingBatch never releases its park | `!gateTimedOut.value` at 10.8 s; **46.5 s under main-actor load** — held through the 40 s load, then 500 turns |
| the File-all latch removed (production) | `currentError == nil` and `banner.severity == .success` red, 0.9 s |
| the scan's cancel not forwarded to its walks (production) | "the walk read 100 of 100 entries", 1.9 s |
| the unanswered folder never parks | "the walk never reached the folder … gave up after 10.0 s and 466 scheduler turns" |
| a superseded pane walk ignores the cancel; the deadline still answers (production) | "gave up after 60.0 s and 4702 scheduler turns" |
| a cancelled comparison ignores the cancel (production) | "gave up after 60.0 s and 4943 scheduler turns" |

**A mutation that hangs is a finding about the mutation, not the bound.** The first attempt at the
pane-walk row dropped the cancel handler's waiter without resuming it, so the deadline had nobody
left to answer. The cancelled walk then awaited a continuation that could never resume, with no
thread blocked and only the probe running (`swift-inspect dump-concurrency`: the task parked in
`closure #2 in FileSyncManager.loadTree`). The test's `await first.value` has no bound and never had
one. That run sat for three hours holding a build slot. A mutation should break the behaviour,
not the continuation contract.

**Tell.** A Sync test red at a 10 s park or signal bound, its failure message giving the turns
spent. "Gave up after 10.0 s and 400+ turns" was disproved. A count far below its floor means the
300 s ceiling ended it, so something stopped the main actor.

**Still seconds-only, and not swept here:** the gates private to their suites —
`FirstAttributesGate` (`DeepFolderIdentityTests`), `ProgressAccountingTests`' and
`MergeUndoPromiseTests`' semaphores, `MergeUndoGroupingAndGateTests`' rendezvous,
`BulkSyncCancellationAndReservationTests`' barrier — and the park budget's own give-up. Each one is a
one-line change to `wait(until: TurnDeadline(…))` if it goes red the same way.

### 41. A move returned before its undo had read the Trash, so the fixture's stranger was recorded as the original — FIXED

**Symptom.** `UndoTrashIdentityTests.aMergeMoveUndoLeavesAnEmptyStrangerFolderAtTheSourceFoldersTrashPathInTheTrash`
red once, 2026-10-26, in a full local `Modules/Sync` run at `4f6054fdf`, with 11 builds queued
for slots. Two expectations: `markOn(trashed) == "stranger"` and `markOn(src) == nil`. ⌘Z had
pulled the stranger out of the Trash as the source folder. Green 3 of 3 under `--filter`, and in
the next full run.

**Not file-number reuse.** The undo tells the merge's emptied source folder from another empty
folder by its own `st_ino` (`.directoryTreeAndFileNumber`), and the fixture deletes the folder
and makes the stranger at once. APFS gave a new number every time: 0 repeats in 20,000
`rmdir`/`mkdir` cycles of one path, on this Mac's data volume.

**Mechanism.** `registerMoveUndo(items:)` registers the undo at once, then reads the Trash items'
identities in a `Task.detached`, the walk kept off the main actor. `moveItems` dropped the task it
returns, so it reported done before the read had run. The copy branch next to it awaits the same
kind of task, "the drift tests tamper the moment it does". The move branch did not. The test swaps in the
stranger the moment `moveItems` returns. On an idle machine the detached read gets there first. Under
load the swap does, and the read records the stranger's number. ⌘Z then finds the stranger it recorded,
unchanged, and restores it. This is the
race "Fixed pumps and fixed sleeps" warns about, with the fixture's next line playing the pump.

**Reproduced** by holding the detached read 300 ms (a scratch `Task.sleep` at its start, never
committed): `--filter UndoTrashIdentityTests`, idle, red on exactly those two expectations, the
other 19 green.

**Fix.** `moveItems` awaits the registration, as the copy branch does, so a move is done only once
its ⌘Z knows what it put in the Trash. The gap was real in the app too, if narrow: it is as long
as the read takes to be scheduled, and a person would have to empty the Trash and trash another
`Reports` within it.

**Mutation-checked**, with the 300 ms hold kept in:

| Mutation | Verdict |
|---|---|
| none: the fix and the hold together | 20 of 20 green, 1.6 s |
| the await removed (the code before the fix) | `markOn(trashed) == "stranger"` and `markOn(src) == nil` red, 1.7 s |

**Tell.** A Trash-identity test, its stranger or tampering done on the line right after the
operation returns, red only under load with ⌘Z having restored what it should refuse. Check that
the operation awaits its undo's identity reads.

**Not swept here:** every other `registerMoveUndo(items:)` caller (bulk sync, filing, automations,
rename, normalize, restructure) still returns before its backups' identities are read. Each
records only overwritten backups late, not a merge's emptied folder. Await the returned task if
one goes red this way.

### 42. A table row's teardown runs SwiftUI's display-link update, which takes a weak reference to the dying row — FIXED

**Symptom.** FileExplorer's test process exits with `signal code 6`. There is no `✘` and no
`Test run with` line. Seen twice in full local runs, minutes in: 2026-10-25 10:26
(`swiftpm-testing-helper-2026-10-25-102631.ips`, 3 minutes after launch, at a load average reported
as 70–90) and 2026-10-26 10:01 (`…-2026-10-26-100156.ips`, 3.5 minutes in). The report has no
exception and no message, only `"termination": {"namespace": "OBJC", "code": 1}`: the runtime's
own fatal error. Both reports have the same two stacks, callers first:

```
main  objc_autoreleasePoolPop, after a main-actor job
        → -[NSTableRowView dealloc] → -[NSView dealloc] → _finalize → removeFromSuperview
        → _setSuperview: → NSHostingView._invalidateEffectiveVibrantBlendingStyle
        → ViewGraphRootValueUpdater.invalidateProperties → _MovableLockLock → wait_for_lock
        → run_moved_callback → UpdateGroup.syncMain's block → updateGraph
        → NSHostingView.updateEnvironment → FocusBridge.isHostContainedInFocusedItem
        → +[UIFocusSystem focusSystemForEnvironment:] → -[NSViewFocusProxy parentFocusEnvironment]
        → -[NSView _focusProxy] → -[NSViewFocusProxy initWithView:] → objc_storeWeak
        → weak_register_no_lock → _objc_fatal
com.apple.SwiftUI.DisplayLink
        CoreDisplayLink → NSHostingView.startAsyncRendering's handler
        → renderFromAsyncDisplayLink → renderAsync → ViewGraph.updateOutputsAsync
        → GraphHost.runTransaction → updateGraph → _MovableLockSyncMain, waiting
```

**Mechanism.** A hosting view draws its animations from SwiftUI's display-link thread. When such a
render meets work that has to run on main, that thread holds SwiftUI's update lock and waits in
`_MovableLockSyncMain` for main to run it. Main meanwhile drains an autorelease pool after a
main-actor job and deallocates an `NSTableRowView` with a hosting view still inside it.
FileExplorer's own code builds no table rows with hosting views in them, so it is a SwiftUI
`List`'s or `Table`'s. `-[NSView dealloc]` removes the row's subviews. Removing the hosting view
invalidates its content style, which asks for the update lock. The holder is waiting on main,
so main runs the waiting update on the spot (`run_moved_callback`), inside the row's `dealloc`. The
update asks whether the focused item is inside its host and walks up the focus parents to find the
focus system. The hosting view's parent is still the row. AppKit makes a focus proxy for the row,
which keeps a weak reference to it, and `weak_register_no_lock` aborts on a weak reference to an
object being deallocated. Its message names the object; the report does not keep the message.

**Not the projection abort** ("An attribute dictionary freed under a projection's own run — cause
not found"): that one is an `NSInvalidArgumentException` on a cooperative thread in a run's first
seconds, with no SwiftUI thread involved.

**Which test tore the row down is not known.** The job whose pool was draining is gone from the
stack. Both reports have the same two long tests in flight elsewhere, a PDFKit lane hold and
`EditorDiskWatchTests.aStuckDownloadHoldsOneReadOnItsOwnQueue` on its download queue, so both aborts
came at about the same point in a run.

**Not reproduced.** A scratch rig, not committed: a window ordered in behind everything, hosting a
SwiftUI `List` with animations in its rows, beside it, on the `List` itself, or `TimelineView`s in
its rows, then dropped inside an autorelease pool. 40 to 600 rounds per shape idle, and 1,500 rounds
of the rows-and-beside shape with 40 `yes` spinners running (load 31). No abort. Breakpoints show why:
a host rendered async only with SwiftUI content alone (`startAsyncRendering` ran for a stack of
animated shapes, never for a `List` or its rows), and no rig render ever waited on main
(`_MovableLockSyncMain` never ran). The view that renders async inside a row was not found.

**Fix: no async rendering in FileExplorer's test process, 2026-10-26.** SwiftUI has a switch for
it, `com.apple.SwiftUI.DisableAsyncRendering`, read from the standard defaults once per process
(`UserDefaultKeyedFeature`, in SwiftUICore). `TestProcessRendering`, a test-only Objective-C target
in the Design package, registers it YES from a constructor that runs when the bundle loads, in the
registration domain: no defaults file is written. Measured in the rig: registered,
`NSHostingView.startAsyncRendering()` never ran; without it, it ran at the first layout. With no
display-link render, no thread holds the update lock waiting on main, so a row's teardown has no
update to run inside it. `TestProcessRenderingTests` checks the switch reads YES in the process.
That holds the wiring, not the abort.

**Not covered.** The other packages' test processes and the app target do not link it; link it the
same way if one aborts like this. The app renders async as shipped. The abort has not been seen
there, and turning it off there would be a decision about the app, not a test fix.

**Tell.** Signal 6 with no `✘`, minutes into a full run. The `.ips` has an `OBJC` termination, the
main thread in `weak_register_no_lock` under `-[NSViewFocusProxy initWithView:]`, under
`run_moved_callback`, under `-[NSTableRowView dealloc]`, and a `com.apple.SwiftUI.DisplayLink`
thread in `_MovableLockSyncMain` under `renderFromAsyncDisplayLink`. In FileExplorer, check
`TestProcessRenderingTests` first: red or missing means the target no longer links
`TestProcessRendering`. If it is green and a `renderFromAsyncDisplayLink` frame is in the report
anyway, SwiftUI no longer reads the key.

**See.** `Modules/Design/Sources/TestProcessRendering` and its header; "A spell check and a defaults
change from another process deadlock a SwiftUI focus move" for the same kind of fix.

### 43. A scratch-defaults ledger line that failed to write raised an Objective-C exception — FIXED

**Symptom.** FileExplorer's test process exits with `signal code 6`, no `✘` and no `Test run with`
line. Seen once, 2026-10-25 11:51 (`swiftpm-testing-helper-2026-10-25-115103.ips`). The crashing
stack ends in `ScratchDefaultsLedger.record` → `FileHandle.write(_:)` → `-[NSConcreteFileHandle
writeData:]` → `NSFileHandleOperationException`.

**Mechanism.** Every test that makes a scratch `UserDefaults` suite records its name in a ledger
file, so the next run can sweep what a crash left behind. The ledger appended with
`seekToEndOfFile()` and `write(_:)`, the pre-Swift forms that raise an Objective-C exception when
the write fails. No Swift `catch` or `try?` stops one, so a failed append (the reason is not in the
report) ended the whole process.

**Fix, 2026-10-26.** All seven copies of the ledger (Dashboard, Design, Events, FileExplorer,
Settings, Sync, the app's `SyncCloudTests`) append with `seekToEnd()` and `write(contentsOf:)` under
`try?`. A line that can't be written only costs the next run's sweep that one name.
