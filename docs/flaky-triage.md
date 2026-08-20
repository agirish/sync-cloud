# Flaky test triage card

**Start here when a suite goes red, or when an absence assertion goes suspiciously green.** One
page, in the order the questions are cheapest to answer. Every row links to
[flaky-tests.md](flaky-tests.md), which carries the mechanism, the measurements and the fix pattern
— this card carries only what tells one from another.

Steps 1–3 cost about a minute and have each been skipped, at least once, in favour of a wrong
conclusion.

---

## 0. Is there a verdict at all?

No output, log frozen mid-line — often right after `Build complete!` — no test named, one core
pegged near 100%? **Nothing below applies.** Go to
[mechanism 8](flaky-tests.md#8-the-wait-that-hangs-instead-of-failing); `sample <pid>` is the only
truth, because neither the log nor a live pid will say which test is stuck.

And the other half of the same question — **a verdict, but no test named**. Exit 65,
`** TEST FAILED **`, every package suite green, and **no `Test run with N tests` line anywhere in
the app-target step**? Then no test ran there either: the *build* failed, and only the reporting
makes it look like a test did. **Nothing below applies**, `gh run rerun --failed` will not clear
it, and the commit in front of you is almost certainly not the cause. Go to
[mechanism 13](flaky-tests.md#13-the-build-failed-before-any-test-ran).

```bash
gh run view <run-id> --log | grep 'Test run with' || echo 'NO TEST-COUNT LINE — nothing ran'
```

Use that form rather than `grep -c`, which **exits 1 when the count is zero** and so reads as a
failed command instead of an answer.

## 1. Match the signature

Read down until one fits. The first four are decided by the *shape* of the failure and need no
machine state at all.

| What you are looking at | Mechanism | First move |
|---|---|---|
| A **cluster** at one wall clock (~12.5 s), same expectation, every member a `ParkGate` / `FirstStatGate` user, membership **changes between runs** | [10](flaky-tests.md#10-every-gate-parks-at-once-on-the-pool-their-releases-need) | `--no-parallel`. If it clears, the commit in front of you is not the cause. A member that fails **every** time, serial included, is a real gate regression |
| Only the **app-target** step red, window assertions reading `nil` / `[]` in **under 0.1 s** | [11](flaky-tests.md#11-five-palette-tests-the-fixture-dismissed-out-from-under-itself--fixed) — **fixed 2026-08-16** | Treat a fresh instance as a real regression. The fixture now names every dismissal with the app's activation state; read that, do not rerun |
| An assertion on `Logger.shared.entries`, failing **only** in the full suite | [12](flaky-tests.md#12-a-log-assertion-reading-a-window-that-has-already-rolled) | Do not bisect the code that writes the line — check whether the test reads the buffer whole |
| A suite asserting a surface **ignored** something, newly failing since an unrelated suite gained a mounted-view test | [9](flaky-tests.md#9-a-mounted-view-is-a-live-subscriber-in-every-suite-at-once) | Give each mounted pane its own `NotificationCenter` |
| Whole deadline burned, **machine idle**, siblings waiting on the same thing pass | [7](flaky-tests.md#7-the-machine-decides-the-verdict--the-keyboard) | An ambient global read — `NSEvent.modifierFlags` is the keyboard, not the event |
| Whole deadline burned, **machine loaded**, the rest of the suite slow too | [2](flaky-tests.md#2-fixed-pumps-and-fixed-sleeps) | Was the budget denominated in seconds when the test needed *main-actor turns*? Add a pass floor |
| Passes under `--filter`, fails in the full suite; flake rate **drifts** between batches | [2](flaky-tests.md#2-fixed-pumps-and-fixed-sleeps) | Wait for the movement you expect, then drain turns — never wall time |
| Fails only when a **specific other suite** runs; two suites pass alone and fail together | [3](flaky-tests.md#3-process-wide-state-and-suites-running-in-parallel) | Check which line failed: an absence assertion, or the fixture? Only the first is this |
| An animated end state reported as its **start** state; pushes made overnight, nobody at the machine | [1](flaky-tests.md#1-the-machine-decides-the-verdict--throttled-coreanimation) | check `lowpowermode` in `pmset -g` (step 2) |
| A timing or **ratio** assertion, red busy and green idle | [6](flaky-tests.md#6-load-scaled-benchmarks) | Interleave the arms — never all of one then all of the other |
| Fails near a **time boundary** — a freshness cutoff, a recency window | [5](flaky-tests.md#5-tests-racing-a-real-time-window) | Inject the instant so the window is a value, not a race |
| **Many** tests at ≥10 s at once, and `~/Library/Preferences` is filling with `<Suite>-<UUID>.plist` | [4](flaky-tests.md#4-leaked-defaults-suites) | Read the *passing* durations, not just the failures — one global `cfprefsd` freeze looks selective |

## 2. Check what else is running

**The self-hosted runner IS this Mac.** A local build competes directly with CI, and there are
routinely many worktrees open at once. A CI red that coincides with your own full-suite run is very
likely yours, and not in the way you think.

```bash
uptime                          # load average — anything over ~8 on this Mac is contention
pmset -g | grep lowpowermode    # 1 = CoreAnimation throttled
pgrep -fl 'xcodebuild|swift-frontend' | grep -v actions-runner
git worktree list               # every one of these is a session that may be building
```

## 3. Run the OLD source under the SAME conditions

This is the step that settles it, and the one easiest to skip. On 2026-08-01 a suite failed 4/4 and
CI had been green on the previous commit, so the new commit looked guilty. It wasn't:

| Source | Machine | Result |
|---|---|---|
| new commit | idle | 573/573 pass, 10s |
| **previous commit** | **load ~10** | **4 failures, 52s** |

The second row is the whole argument. Without it you are comparing a commit against a *different
machine state* and calling the difference a regression.

---

## The silent half — read before writing any absence assertion

**Four mechanisms here can leave an assertion passing having examined nothing.** A false failure is
noisy and costs you a day; a vacuous pass is silent and permanent, so it costs you nothing to notice
and everything to miss.

- [2](flaky-tests.md#2-fixed-pumps-and-fixed-sleeps) — a fixed sleep before the absence. "Nothing
  happened" and "it hasn't happened yet" are indistinguishable.
- [8](flaky-tests.md#8-the-wait-that-hangs-instead-of-failing) — a bound whose **expiry is
  discarded**. Record the timeout and assert on it.
- [9](flaky-tests.md#9-a-mounted-view-is-a-live-subscriber-in-every-suite-at-once) — an absence with
  no paired control proving the signal could ever have arrived.
- [12](flaky-tests.md#12-a-log-assertion-reading-a-window-that-has-already-rolled) — a log window
  that rolled past the interval being read. Read 12 before **any** assertion about
  `Logger.shared.entries`.

The first three are visible in the test's own source. The fourth fires on the volume of unrelated
suites, so the same test is honest or vacuous depending on what else was scheduled beside it.

---

## Before you conclude

**Do not stop at `--filter`.** Passing in isolation proves almost nothing — most of these mechanisms
need the rest of the suite present to fire. Confirm against the full suite, ideally twice. The one
exception is [mechanism 10](flaky-tests.md#10-every-gate-parks-at-once-on-the-pool-their-releases-need),
where passing in isolation *is* evidence.

**Never judge `swift test` from piped output.** Under the x64 agent it exits 1 with everything
passing; `… | tail` masks the real exit code. See
[ci.md](ci.md#rosetta-corollary-swift-test-exit-code-lies-under-x86_64).

**Check whether the failure spent time.** A starved test *spends* its ceiling — 25 s or 32 s. A
missing object fails in under 0.1 s. A stall and an absence look nothing alike, and reaching for a
timing cause before checking which one you have is how mechanism 11 accumulated two dead hypotheses.

If steps 1–3 point at the environment, say so *with the evidence* and re-run. If they don't, it's
your commit — keep going.

---

## Reproducing a load-sensitive failure on purpose

Suspected flakes are worth confirming rather than assumed. Load the machine, run the suite, then
**verify the load generators actually died** — a leaked spinner poisons every later measurement on a
machine that also runs CI.

```bash
for i in $(seq 1 6); do (yes > /dev/null &); done
uptime
arch -arm64 swift test --filter <Suite>
pkill -x yes; pgrep -x yes || echo "clean"
```

Use CPU spin, not `sleep`, when validating that a timing test can actually fail — a sleeping process
contends for nothing and proves nothing.

---

## When you have the mechanism

Go to [flaky-tests.md](flaky-tests.md) for the fix pattern, then read
[**When you fix one**](flaky-tests.md#when-you-fix-one) — a test written against a flake is
especially prone to passing for the wrong reason, so mutation-test it *after* writing it.
