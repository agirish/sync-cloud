# Flaky tests

Tests here have failed for reasons that had nothing to do with the code under test — and each
time, the failure looked exactly like a real defect. `ColumnPreviewRevealTests` reported "the
deepest column is hidden behind the preview: column 420…630, visible 0…270", which is the precise
geometry of the bug it exists to catch. Nothing about that message says *the machine decided this*.

This file records the mechanisms that have actually produced false failures in this repo, how to
tell one from a regression before you start bisecting, and the fix pattern for each. See
[ci.md](ci.md) for what CI runs and the runner's own quirks.

---

## First: is it a flake or a regression?

Do these in order. Steps 1–3 cost about a minute and have each been skipped, at least once, in
favour of a wrong conclusion.

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

**See.** `6ecc245d` — *Decide the column reveal's tests by the code, not the machine's power state*;
`daa88130` — *Pin the reveal animation the app ships* (the default nothing was reading);
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

**See.** `c2584e6` — *Poll the drill tests' observables instead of pumping a fixed window*;
`3a4ee8a` — *Poll for the revealed search field's caret instead of a fixed pump*.

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

**See.** `d282ac6` — *Isolate DifferencesView test mounts in per-mount scratch defaults*;
`Modules/FileExplorer/Tests/FileExplorer/CloudOnlyBadgeCacheTests.swift` for the shape of the note.

### 4. Leaked defaults suites

**Symptom.** Not a failure — accumulating `<SuiteName>-<UUID>.plist` files in
`~/Library/Preferences`, and occasionally a test reading a previous run's value.

**Mechanism.** A defaults suite outlives the test that made it; `cfprefsd` rewrites the backing
plist after the process exits.

**Fix.** Tear the suite down *and* delete its backing plist; record every wiped suite in the
ledger. The residue is bounded and self-clearing — the count oscillates rather than growing — so
measure across several runs before concluding the mechanism is broken.

**See.** `8c46d65` — *Delete the backing plist when a test's scratch defaults suite is torn down*;
`5b495f7` — *Record every wiped defaults suite in the ledger, not just ScratchDefaults'*.

### 5. Tests racing a real-time window

**Symptom.** Fails near a boundary — a freshness cutoff, a recency window — and only sometimes.

**Mechanism.** The test races wall-clock time it does not control. Unwinnable by construction.

**Fix.** Inject the instant (`at:` / `now:`) so the window is a value, not a race.

### 6. Load-scaled benchmarks

**Symptom.** A timing assertion fails on a busy machine and passes on an idle one.

**Mechanism.** An absolute threshold encodes the machine it was written on.

**Fix.** Retune from the test's own printed measurement rather than guessing, and validate that the
assertion can fail using CPU spin — never `sleep`.

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
`DifferencesView`, `PaneBreadcrumb` and `ModifierTracker`; none is under a test that drives it
today, but the seam is the answer if one grows.

**See.** `Modules/FileExplorer/Tests/FileExplorer/ColumnDrillSourceTests.swift`;
`paneClickModifiers` in `PaneColumnsView.swift`.

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
