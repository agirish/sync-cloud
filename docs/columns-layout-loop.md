# The Columns display-cycle crash

A hard crash — `EXC_BREAKPOINT` in `+[NSApplication _crashOnException:]` — taken four times by one
user on 2026-07-27 and 2026-08-02, plus five more driven deliberately while investigating. **The
symptom is suppressed; the underlying layout loop is not fixed.** This file is the standing record so
the next attempt does not re-run the three investigations that came before it.

## Which line has actually crashed

**Every crash report that names a version names this line, v3.** Checked 2026-08-03 against
`~/Library/Logs/DiagnosticReports` rather than against recollection, because the mitigation commit
claimed "a 2.8 user with both panes in Columns has the same crash surface" — which was an inference
from code shape, never a measurement.

Fifteen `SyncCloud-*.ips` reports exist. Thirteen are from 2026-08-02 and **all thirteen report
`3.0-dev` / build `300`** — this line, post-split — and all carry the
`_postWindowNeedsUpdateConstraints` frame. Of the two older ones, 2026-07-28 is a *different* crash
(`EXC_BAD_ACCESS`, no display-cycle frame anywhere in it) and 2026-07-27 is this crash but on a
`1.0` / build `1` binary, i.e. before the version fix and before the v2.x split on 2026-08-01 — so
it was the then-single line, four days before v2.8 was tagged.

**No display-cycle crash has ever been recorded on a 2.x build.** That does not prove v2.x is
immune — the same file already explains why survival counts have almost no power, and the split is
recent — but it does mean the crash surface on v2.x is unmeasured rather than demonstrated. The
mitigation stays on both lines because it is free and overridable; what it must not do is appear in
v2.9's release notes as a fix, because nothing a 2.8 user was hitting is being repaired.

Read together with the reproduction section below, this is also the strongest hint about *where* to
look: whatever spends the pass budget is either unique to this line or far likelier here.

## What AppKit is complaining about

`-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]` raises `NSGenericException` when a
window "has been marked as needing another update constraints pass, but it has already had more
update constraints passes than there are views in the window". It is a runaway-layout guard: AppKit
re-runs update-constraints until the tree stops dirtying itself, and gives up once the pass count
exceeds the window's view count.

**The frame in the crash report is where the budget ran out, not what spent it.**

## The mechanism

Reports differ in how much they give away — compare `lastExceptionBacktrace` across several before
theorising. The useful one:

```
OutlineListCoordinator.listTableCellView(_:didUpdateIdealHeight:)
  ← ListTableCellView.hostingView(_:didUpdateIdealHeight:)
  ← NSHostingView.SizeConstraints.update(from:)
  ← NSHostingView._willUpdateConstraintsForSubtree()      ← inside the pass
AppKitPlatformViewHost.enqueueLayoutInvalidation()         ← …which schedules another pass
  → NSHostingView.setNeedsUpdate() → -[NSView setNeedsUpdateConstraints:]
  → -[NSWindow _postWindowNeedsUpdateConstraints]          → raise
```

A list row reports a **new ideal height from inside the update-constraints pass**, so the list
enqueues another pass, in which the row reports a new height again. This is *not* the
two-writers-on-one-anchor bug that `96cfbb2` fixed, which is why that fix did not hold.

## Reproducing it

Both panes in **Columns** (`paneViewModeLeft`/`Right = columns`); switch a pane's provider. The
`.onChange(of: rightProviderId)` handler calls `resetNavigation()`, which drops both pane trees
synchronously and reloads from the new roots; the crash lands while the replacements paint.

Reproduces by hand, every time: open the app, change the right provider between two cloud accounts.

`selectedRightProviderId` is an `@AppStorage` key, so a script can drive the same code path without
UI automation:

```sh
defaults write com.abhishekgirish.SyncCloud selectedRightProviderId -string "Dropbox"
```

**But the scripted route is far less reliable than clicking** — it fired 5/5 early in one session and
then 0/12 later the same night with nothing changed but elapsed time. The picker click also opens and
dismisses a popover and moves first responder; that difference has not been closed. **Trust the
manual repro; treat the scripted one as a convenience that may silently stop firing.**

## Measuring a candidate fix

Do not evaluate a fix on whether the app survived. The crash rate moves by an order of magnitude for
reasons not yet understood, so a survival/death outcome has almost no power:

- Single-run bisects taken during a high-rate window produced two answers that both evaporated on
  repetition ("tree mode survives"; "removing `PaneColumnJitterProbe` survives" — it then died 2 of
  the next 3).
- 22 consecutive warm survivals looked like proof the mitigation worked; forcing the assert back on
  then survived 6/6 as well.

Any future evaluation needs interleaved arms, cold starts, and ideally a **continuous** metric —
update-constraints passes per display cycle — rather than a binary one.

## The instrument, and why every fixture before it was blind

**`window.layoutIfNeeded()` cannot reach AppKit's runaway guards.** That is the single most useful
thing measured so far, it explains all three failed investigations at once, and it was never
checked because it looked like plumbing. Driven against a deliberate never-settling loop — two
sibling views each re-dirtying the other, with a constraint constant that really moves — one arm per
process, assert armed:

| driver | on screen | outcome |
|---|---|---|
| `layoutIfNeeded()` ×400 | no | **survives** — 469,000 `updateConstraints` calls, no raise |
| `layoutIfNeeded()` ×400 | yes | **survives** — 471,100 calls, no raise |
| one second of the runloop | no | **raises** |
| one second of the runloop | yes | **raises** |
| one second of the runloop, assert suppressed | either | survives, 853–874 passes |

On-screen-ness makes no difference; the **driver** decides. Why AppKit behaves this way is not
established — the mechanism was never disassembled, only the behaviour measured — so take the table
as the claim and nothing more.

**One caveat, stated because this file's job is to stop the next person over-reading it.** The
ping-pong raises from `_NSViewUpdateConstraints` — AppKit's "something dirtied during the pass"
guard — not from `_postWindowNeedsUpdateConstraints`, the window pass-budget guard the real crash
hits. Both are runaway guards, both went off only on the display cycle, and both funnel through
`+[NSApplication _crashOnException:]`; but this experiment shows the manual driver disarms *a*
guard, not specifically *that* one. What it does establish is enough to disqualify the null results
below: a fixture driven by `layoutIfNeeded` can churn half a million constraint updates and still
report success.

Every headless fixture written against this bug drives with `layoutIfNeeded` — the `roundsToSettle`
helper in `PaneTreeSwapLayoutBudgetTests`, `PaneRowHeightStabilityTests` and
`ColumnsRepublishLayoutLoopTests`, and the `pump` in `PaneColumnsLayoutLoopTests`, which re-lays out
by hand on every runloop turn. **Their "settles in 2 rounds" verdicts are therefore not evidence
about this crash**: they were measuring a path that structurally cannot fail. Each now carries a
note saying so. What they do still prove — that the tree stops dirtying itself under a manual pump —
is worth keeping, and is a weaker claim than the one they were being read as making.

**The continuous metric.** `-[NSWindow updateConstraintsIfNeeded]` is called once per
update-constraints pass, on both drivers, and it is **public API** — no private selector, nothing a
future macOS renames silently. Counting it per runloop turn is exactly "update-constraints passes
per display cycle", which is the continuous metric this file has been asking for.

- In tests: `ColumnsDisplayCycleTests.PassCountingWindow`, an `NSWindow` subclass. The fixture
  pumps the runloop and *only* the runloop.
- In the app: `DisplayCycleTrace`, which exchanges the same public method and flushes on a
  `CFRunLoopObserver`. **Off unless armed** — an ordinary session installs no hook at all:

  ```sh
  defaults write com.abhishekgirish.SyncCloud displayCycleTraceEnabled -bool YES
  ```

  Armed, it writes `[cycle] "<title>" (<n> views) spent N update-constraints passes in one display
  cycle` to `~/sync-cloud.log`, and keeps a per-window high-water mark so a session can be read
  after the fact rather than watched live.

  **A cycle is reported only if it clears two gates**, both calibrated on the measurements below
  rather than guessed. It must reach **12** passes — a healthy two-pane provider switch spends 7 —
  *and* an eighth of AppKit's own budget, which is the window's view count. The second gate is
  there because the first is not sufficient: mounting the same pane costs **14** passes against 136
  views, which is over any useful absolute floor and entirely healthy. Only a fraction of the real
  budget separates "a lot of layout" from "heading for the cliff", and it scales with the window
  instead of needing a new constant per surface.

  This is also what finally answers the open cost question below — the churn is now countable
  whether or not it ever reaches the crash.

## What the new fixture measures, and what it does not

`ColumnsDisplayCycleTests` mounts the pane on the runloop driver in two shapes. Both are
**deterministic** — identical numbers across repeated runs and across on-screen/offscreen arms,
which is itself worth noting given how much variance the crash rate has:

| fixture | views | worst cycle |
|---|---|---|
| one pane, Columns, the `resetNavigation()` republish | 136 | **3 passes** |
| two panes in Columns, both drilled, preview up, real `PaneBarPlacement` and the host's `onBarEdgeFlip`, right pane's provider switched | 351 | **7 passes** |
| the same, with a **risky-name badge on every row** | 351 | **7 passes** — no change at all |

The second is `ContentView.treeView`'s actual composition — `FileTreeView` in columns mode,
`.equatable()`, the row-bottoms preference feeding a live placement — and neither brought it near
the budget. (It also *passes* the edge-flip callback exactly as `ContentView` does, but that
callback never fires; see below. The list of what this arm establishes stops where the callback
does.)

**Every claim in that row is now checked against what AppKit laid out, because two of them were
not.** The arm asserts both panes drilled to a two-column stack and both preview columns rendered,
and the badged arm counts the badges it handed out. That is not belt-and-braces — it is the second
correction this fixture has needed:

- `onBarEdgeFlip` is wired here exactly as the app wires it and fires **zero** times (`b4550396`).
- The preview column was **absent** from every measurement taken before this check existed. The
  earlier "348 views / 7 passes" numbers were a pane with no preview in it, while the row claimed
  "preview up". Fixed rather than retracted — the wait now waits for the preview to actually
  arrive, and the answer is unchanged at 7 passes, so the claim is now real instead of vacuous.

**Why it was missing is worth keeping.** The wait was bounded by runloop turns, and
`CFRunLoopRunInMode` returns the instant the loop has nothing to do — so several hundred "turns"
cost microseconds, while what the preview waits on is a **timed** settle. Turn-counting is the
right bound for quiescence (`docs/flaky-tests.md` mechanism 2) and the wrong one on its own for
anything waiting on a clock; `pumpUntil` now sleeps 8ms a turn as `LayoutPumpWait` does. **Quiescence
is not arrival** — a wait for "layout stopped moving" returns happily before the thing you are
waiting for exists.

**The third arm exists because of the v3-only evidence at the top of this file.** `RiskyNameBadge`
and `RiskyNameBadgeCache` are the only files in this pane that `main` has and `v2.x` does not, which
made the badge the strongest available lead — and the badge takes width beside a name whose `Text`
carries no `lineLimit`, which is exactly the shape a height oscillation would need. It changes
nothing: 7 passes either way.

That arm also closed a hole every fixture in this file had. `FileActionDelegate.riskyNameReason`
carries a **protocol-extension default of nil**, so a test double that does not override it renders
no badge at all — every measurement here, and every one in the older fixtures, was taken on a pane
*without* the feature under suspicion. The badged arm asserts a badge was actually handed to a row,
because "the badge changes nothing" and "the badge was never drawn" otherwise produce the same
sentence.

**So the fixture still does not reproduce it, and now that is a sharper statement than before**:
it is not that the harness could not have seen a runaway (this one can), it is that this
composition does not produce one. Whatever the real app does differently is still outside the
fixture. The next thing to try is the armed trace against the manual repro, which is the only
trigger anyone trusts.

## Ruled out, by measurement

**Read this list against the driver finding above.** These were all taken with the
`layoutIfNeeded` fixtures, so the ones phrased as "the window settles" are weaker than they read;
the ones that measured a geometry directly (row heights across a width sweep, integral rounding)
are unaffected, because they never depended on the guard.

Headless probes (`PaneTreeSwapLayoutBudgetTests`, `PaneRowHeightStabilityTests`,
`ColumnsRepublishLayoutLoopTests`) all settle in 2 rounds against a 130–250-view budget:

- the view-budget collapsing when both trees are dropped at once;
- both panes resolving to the same path (independently dead — one crash had different paths);
- long names wrapping and making row height width-dependent (names truncate; height stays fixed
  across a 900→260pt sweep);
- Columns + preview at a fractional stored width + compact density, republished at nine widths;
- fractional row heights defeating integral rounding (heights are integral at all eight
  density × text-size combinations).

## The mitigation in place

`SyncCloudApp.init` registers `NSWindowAssertWhenDisplayCycleLimitReached = false`, which is the
default AppKit reads to decide raise-versus-tolerate. Registration domain, so it is overridable and
writes nothing into the user's preferences. Not registered under tests, so CI still fails loudly if a
fixture ever does reproduce the runaway.

Verified against the manual repro, which crashed on every attempt beforehand and stopped crashing
with the assert disabled. It was **not** verifiable against the scripted repro, which by then had
stopped firing in either arm.

To get the crash — and its backtrace — back for a diagnostic session:

```sh
defaults write com.abhishekgirish.SyncCloud NSWindowAssertWhenDisplayCycleLimitReached -bool YES
```

That is a *persistent* domain write, and it beats the registration domain, which is why it works.

## Is the mitigation actually plumbed in

Measured 2026-08-03, because the section above cannot answer it. "Crashed every time before,
stopped crashing after" is exactly the survival/death outcome this file already says has almost no
power, and the same file records 22 survivals with the assert off matched by 6/6 with it forced
back on. A review raised the specific worry that `register(defaults:)` writes the **registration
domain**, an `NSUserDefaults`-level construct that `CFPreferencesCopyAppValue` is not obliged to
see — so if AppKit read the key through CFPreferences, the line would be inert and the crash only
appeared to be handled.

**It is plumbed in. The worry does not apply, for two independent reasons.**

*What AppKit actually calls.* Disassembling
`-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]` shows the key read twice, both
times as `_NSGetBoolAppConfig(@"NSWindowAssertWhenDisplayCycleLimitReached", 1, <cache byte>,
NSWindowAssertWhenDisplayCycleLimitReachedDefaultValueFunction)`. Disassembling
`AppKit`_NSGetBoolAppConfig` in turn shows its whole body: `[NSUserDefaults standardUserDefaults]`
→ `objectForKey:` → `boolForKey:`, plus a `volatileDomainForName:` lookup for the argument domain.
**There is no `CFPreferences` call anywhere on that path**, so the registration domain cannot be
invisible to it.

*End-to-end, in both directions.* Calling AppKit's own `_NSGetBoolAppConfig` — the exact address
the crash site branches to — with AppKit's own default-value function for this key, and a fresh
cache byte each time so every arm is a genuine cold read:

| Arm | AppKit's read returns |
|---|---|
| nothing registered | `YES` → raise (the crash) |
| `register(defaults: [key: false])` — what ships | `NO` → tolerate |
| control: `register(defaults: [key: true])` | `YES` → raise |

The control arm is what makes this more than one observation: the read tracks the registration
domain *in both directions*, so the middle row is the registration being honoured and not a
coincidence. AppKit's built-in default for the key is `YES`, confirming the unmitigated app is
meant to raise.

*The premise was wrong on its own terms too.* On this OS `CFPreferencesCopyAppValue` **does** see
the registration domain — after `register(defaults:)` it returns `0` with
`CFPreferencesGetAppBooleanValue`'s `keyExistsAndHasValidFormat` set. So even the hypothetical
CFPreferences read path would have worked. Modern `NSUserDefaults` and `CFPreferences` share one
CFPrefs implementation; the "registration domain is invisible to CFPreferences" rule is folklore
that no longer holds here.

*Timing.* The read is cached in a static byte on first use, so registering too late would latch
AppKit's `YES`. It cannot be too late: the only code referencing the key is the limit-reached
branch of `_postWindowNeedsUpdateConstraints`, which by definition needs a window that has already
blown its pass budget, and `SyncCloudApp.init` runs before any window exists.

**So `register(defaults:)` stays.** Switching to `set(_:forKey:)` would buy nothing and would cost
the "writes nothing into anyone's preferences" property.

The app now logs which state the session is in, so `~/sync-cloud.log` answers this without anyone
re-deriving it — `[layout-guard] … suppressed app-wide`, or `… ARMED` when a `defaults write` or
launch argument has put the crash back. The line sits in the delegate's
`applicationDidFinishLaunching`, next to the launch breadcrumb and for the same reason: that fires
exactly once, while `App.init` can be re-run by SwiftUI, and a diagnostic saying the crash guard is
off is worth less each time it repeats.

**It reads `object(forKey:)` before `bool(forKey:)`, and that is load-bearing.** `bool(forKey:)`
answers `false` to both "registered false" and "absent", while AppKit absent the key falls back to
its default-value function, which returns YES — so a `bool`-only check reports *suppressed* in
precisely the state where AppKit raises. That state is not hypothetical: nothing is registered
under tests, deliberately. Checked against AppKit's own `_NSGetBoolAppConfig` across every state,
which is how the `bool`-only version was caught:

| State | AppKit | `object` then `bool` | `bool` alone |
|---|---|---|---|
| absent (as under tests) | ARMED | ARMED | **suppressed — wrong** |
| `register(false)` — what ships | suppressed | suppressed | suppressed |
| `register(true)` | ARMED | ARMED | ARMED |
| `defaults write … -bool YES` | ARMED | ARMED | ARMED |

Mirroring AppKit's own order (`objectForKey:`, then `boolForKey:`) is what makes the two agree.

## What the churn costs is still unmeasured

The suppression is **app-global and permanent for the session**: every window the process opens —
Settings sheet, Activity Log, anything added later — runs without AppKit's runaway-layout guard,
not just the Columns pane that needs it.

The mitigation's own commit says "the window still churns the passes, it just survives them", and
**nobody knows what that costs.** It could be a hitch too short to see or a core pegged after every
provider switch, and those are materially different products. This is an honest open question, not
a guess:

- **A headless measurement was attempted and did not get there.** A synthetic never-settling
  constraint loop — two sibling views each re-dirtying the other from inside `updateConstraints`,
  which is the shape of the real bug and avoids AppKit's stricter "you dirtied yourself in your own
  `updateConstraints`" guard — churns hard but never reaches the display-cycle limit branch at all.
  That is the same wall the three investigations above hit: no fixture has ever reproduced this
  path, which is why the mitigation is a mitigation.
- **The right instrument already exists and is not armed.** `MainThreadHitchMonitor`'s duty-cycle
  line — what fraction of each second the main thread was busy — is precisely the "brief hitch vs.
  pegged core" discriminator, and it is deliberately not a spike threshold. But it is gated behind
  `PaneScrollTrace.isEnabled`, so a normal session records nothing.
- **And now a second one, which measures the churn itself rather than its cost.**
  `DisplayCycleTrace` (above) counts the passes. Arm both for the same session and the two lines
  answer different halves of the question: how many passes the switch spent, and what that did to
  the main thread.

To get the number, the manual repro is still the only reliable trigger, so it needs a real session:
launch with the trace flag on, put both panes in Columns, switch a pane's provider, and read the
`[hitch]` duty-cycle lines around the switch out of `~/sync-cloud.log`. Budget an hour, and expect
the crash-rate variance above to apply to the churn as well — take several switches, not one.

**Until that is done, v2.9 ships a mitigation of known-correct plumbing and unknown cost.** That is
a deliberate trade and it is the right one at this point: the alternative is shipping the crash
itself, which is unambiguously worse than an unquantified hitch.

**This is now answered, and the answer is the bad one.** See "The runaway, finally measured" and
"The manual repro, traced" below: up to 5,840 update-constraints passes against a 227-view budget,
and the cost is **seconds of frozen main thread** — a click stamped `press→settled 4676.7 ms`
alongside a 3,615-pass cycle, and a 174-node publish that takes 2.96 s instead of its usual 0.3 ms.
Not a hitch too short to see. It is a pegged core, and it is almost certainly what the open
dead-click and column-jitter reports are.

## The slow-walk precondition, and why it is NOT the cause

Every crash and every 9-13 s `publish` happened while a provider was cold and the deep walk was
taking **25-46 s**, so the next switch landed while the previous load was still in flight. Warm, the
walk takes 0.4-0.8 s, loads never overlap, and 38 consecutive switches across three configurations
published in 12-22 ms with no crash. That is why the crash rate collapsed from 5/5 to about 1-in-8
over a single evening: the investigation itself kept everything warm.

`WalkStall` (`Modules/Sync/Sources/Sync/WalkStall.swift`) turns that precondition into a knob:

```sh
defaults write com.abhishekgirish.SyncCloud debugWalkStallMillisecondsPerDirectory -int 15
defaults write com.abhishekgirish.SyncCloud debugWalkStallBlocks -bool YES   # optional: block, don't suspend
```

**It did not reproduce the runaway, and that is the finding.** With the stall armed:

- switches land mid-walk **8 times out of 8** (`superseded during the deep walk`) — the overlap is
  real and now on demand;
- walks stretched to 10-15 s and allowed to COMPLETE still publish a 38,461-node tree in 22-58 ms;
- blocking the walk's threads outright — starving the cooperative pool the way a real
  `getattrlistbulk` stall does — changes nothing either.

So a slow walk is a **correlate** of the crash, not a cause. Whatever the runaway needs, it is not
elapsed walk time, not overlapping loads, and not pool starvation.

## The runaway, finally measured — 2026-08-04

**It is real, it is enormous, and it is now a number.** The trace was armed against the installed
app (`3.0-dev` / build 300) and driven with the scripted repro. During one four-minute window every
provider switch but one blew AppKit's budget:

| | passes | window's view budget | over budget by |
|---|---|---|---|
| worst seen | **5,840** | 227 | **25×** |
| typical | 600–4,800 | 146–233 | 3–20× |
| rate | **9 of 10 switches** | | |

AppKit raises once passes exceed the view count, so essentially every one of these would have been
the crash — which is exactly why the manual repro "reproduces by hand, every time". The session
survived only because the assert is suppressed.

**Two cycles per switch, and the budget moves the wrong way.** Each switch produced a cycle at
~146–157 views and a second at ~230–233. The tree being dropped is what shrinks the view count, so
the window's budget is at its *smallest* in the very cycle the churn is at its largest. Anything
that reduces view count during a republish makes the cliff nearer.

**A second, independent finding: the provider-picker popover churns too.** `"untitled"` at 57 views
spent 21–23 passes, 37–40% of its own budget, on three separate occasions — and every one of those
was *before* any main-window churn. This is a different window from the pane, so the app-global
suppression is load-bearing for more than Columns.

### What the metric ruled out that survival counts never could

All measured against the same trace, on the running app:

- **A slow walk is not it, confirmed with a continuous metric.** `WalkStall` armed at 15 ms/dir,
  9 switches landing mid-walk (`superseded` 9/9 — the overlap precondition genuinely present):
  **zero** churning cycles. This corroborates `WalkStall`'s own note from a binary outcome to a
  measured one.
- **A cold process is not it.** Quit, relaunch, measure immediately: 12 switches, zero.
- **Load overlap is not it** — see the 9/9 superseded run above.
- **Window activation is not it.** Interleaved, 8 switches per arm, frontmost-and-key versus
  background: 0/8 either way.

### The correlation that is left, and it is a sharp one

**The churning window began immediately after a real click into the pane, and ended when the
clicking stopped.** From the log, in order:

```
06:56:28.712  [columns] right pane depth 0 → 1 at Immigration   ← a drill, i.e. a CLICK
06:56:28.880  [click]   right pane selected 1 item(s)
06:56:30.679  [deselect] right col1 empty area
06:56:30.819  [cycle]   "SyncCloud" (463 views) spent 1216 passes   ← 0.14 s later
```

Before that click, in the same session, the main window produced no cycle line at all — only the
popover's. After it, 9 of 10 switches ran away. The next session, driven identically but with
**zero** interaction lines in the whole log (no `[click]`, `[columns]`, `[crumb]`, `[deselect]`),
produced zero churning cycles across more than thirty switches, cold start and stall included.

So the missing precondition is something a **click** leaves behind that `resetNavigation()` does not
clear and a `defaults write` never creates. First responder inside the column's `NSTableView` is the
obvious candidate — it survives a provider switch, it is precisely the "the picker click also moves
first responder; that difference has not been closed" note above, and it would explain the whole
pattern at once: why clicking reproduces every time, why the scripted route is unreliable, why no
headless fixture has ever reproduced it (an offscreen window that is never key has no first
responder), and why the rate appears to "decay over an evening" — investigators stop clicking.

**This also reframes the slow-walk story.** Cold providers correlated with crashes because early
sessions involved more clicking, not because elapsed walk time matters; the stall measurement above
now says so directly.

### How to take the next step

Arm the trace, then **click into a column in the right pane before switching the provider** — the
drill is the part that matters, not the switch:

```sh
defaults write com.abhishekgirish.SyncCloud displayCycleTraceEnabled -bool YES
```

`grep '\[cycle\]' ~/sync-cloud.log`. A line naming `"SyncCloud"` with passes above the view count is
the runaway; no line means the window stayed under an eighth of its budget. The number is reported
whether or not the session dies, so a candidate fix is now evaluated by watching 5,840 fall rather
than by counting survivals.

## The manual repro, traced — and the causal story here was backwards

The click the scripted route cannot make was made by hand, with the trace armed. It reproduced
twice in twenty seconds, and this time both occurrences are *attributable*.

**A column drill alone reproduces it. No provider switch is involved.**

```
07:13:33.069  [columns] right pane depth 1 → 2 at Finance/US        ← a drill, i.e. a CLICK
07:13:37.745  [cycle]   "SyncCloud" (560 views) spent 3615 passes
07:13:37.745  [click]   right pane selected 1 item(s), press→settled 4676.7 ms
```

The runaway and the click's own settle stamp land in the same millisecond. **That is the cost, and
it is not a hitch: 4.7 seconds of frozen main thread for one click.** It is also, almost certainly,
the open "dead click" and "first column moves up and down" reports — same window, same cause.

**The slow publish is an EFFECT of the runaway, not evidence of a slow provider.** This file has
until now read the 9–13 s publishes as a symptom of a cold walk. The same tree, published five times
in one session, says otherwise — 174 nodes, the same folder, the same code path:

| when | walk | publish | churning cycle in the same second? |
|---|---|---|---|
| 07:11:07 | 74.3 ms | **0.3 ms** | no |
| 07:13:39 | 55.9 ms | **0.7 ms** | no |
| 07:13:39 | 55.9 ms | **0.8 ms** | no |
| 07:13:43 | 36.8 ms | **51.6 ms** | no |
| 07:13:51 | 40.2 ms | **2.96 s** | **yes — 1794 passes / 233 views** |

Four thousand times slower, on the one occasion the layout ran away, with the tree held constant and
the walk at 40 ms. A 174-node publish cannot take three seconds for any reason except a main thread
stuck in layout. Together with `WalkStall` (slow walks armed, zero churn) the direction is settled:
**the runaway makes the publish slow; the slow walk never made the runaway.** Cold providers
correlated because those sessions involved more clicking.

### The tracking-loop asymmetry — tried, and FALSIFIED

**Read this before the section below, which is the hypothesis it kills.** The candidate was built,
installed and clicked. It made the runaway roughly four times worse and reintroduced the dead click
as a side effect. It is parked on branch `candidate-tap-deferral` (`dba29645`) so the result is
reproducible rather than folklore; nothing was landed on `main`.

The change was minimal and exactly what the asymmetry argued for: the tap gesture kept committing
its selection inline (so the `dba5cd3`/`aa9d407` dead-click fix stayed intact) and only
`onNavigate` — the column-stack restructure — moved to the next runloop turn, behind the same
`DeferredColumnNavigation.isStillValid` guard the List binding already uses.

| one drill, one click | shipped | with the deferral |
|---|---|---|
| worst cycle | 3,615 passes / 560 views | **13,882 passes / 566 views** |
| that click's own stamp | `press→settled 4676.7 ms` | **`press→settled 20811.7 ms`** |
| navigations discarded | — | **6** |

**The six discarded navigations are the dead clicks, and the mechanism is not subtle.** They are
`[columns] dropped a stale deferred tap navigation to …`, a line that exists only in the candidate.
The deferred block was queued behind a main thread already churning for twenty seconds; by the time
it ran, `browsePath` had moved on, `isStillValid` answered false, and the drill was thrown away.
Clicks on `Purchases/US/ATT`, on `Immigration` five times, on `Purchases/US` four times — every one
discarded, from one burst.

**So the tap gesture drilling synchronously is load-bearing, not the inconsistency it looks like.**
The two paths differ because their situations differ: when the List binding defers, `NSTableView`
has *already* committed the selection, so the click has visibly landed and the deferred part is
only the stack. The tap gesture's navigation IS the click's only effect, so deferring it puts the
whole click behind whatever the main thread is doing — and the one situation guaranteed to be
pathological is the very one this bug creates. **Deferring work behind a hang cannot fix the hang;
it can only feed the hang the work that was supposed to survive it.**

Two honest limits on the numbers. Each arm is a **single** run, and this file already documents how
far the rate swings, so 13,882-versus-3,615 should be read as "no improvement, plausibly worse"
rather than as a measured 4× regression. The six dropped navigations are not subject to that
caveat: they are new code doing a new thing, and they match the reported symptom exactly.

One thing the failed run bought outright: **13,882 passes and a 20.8-second click put the ceiling
far above the 5,840 recorded above.** Whatever bound anyone assumed this loop had, it is higher.

A possible reason it got *worse*, offered as a hypothesis rather than a finding: with both paths
deferred, the two navigations — which previously ran separately, one synchronously at mouse-up and
one on a later turn — now land back-to-back inside the same runloop turn, so the stack is
restructured twice with no display cycle between. That was not measured and would need its own arm.

**What this does not touch.** The click is still required to reproduce (see above); what is
falsified is that the *timing* of the restructure relative to the tracking loop is the mechanism.
Whatever the loop is, issuing the same restructure a turn later does not calm it — so the next
candidate should be about what the restructure *does*, not when it is issued.

### The tracking-loop asymmetry — the hypothesis, now falsified above

A click reaches the drill through **two** paths in `PaneColumnsView`, and they treat the same call
differently:

- The **List's selection binding** computes the target and then defers: `DispatchQueue.main.async`,
  guarded by `DeferredColumnNavigation.isStillValid`. Its comment says why — *"writing it from
  inside the List's own selection commit is the mid-commit sibling write that drops clicks
  outright (`aa9d407`)"*.
- The **tap gesture** calls `onNavigate(navigation(for:depth:))` **synchronously**, and the comment
  immediately below it states the context in the code's own words: *"This closure runs INSIDE the
  same tracking loop."*

So one path defers restructuring the column stack out of `NSTableView`'s mouse-down tracking loop,
and the other restructures it — adding or removing whole columns, each its own `List`, `NSTableView`
and hosting view — from inside that nested loop, while display cycles are running in it.

That predicts everything measured here. A programmatic `browsePath` write never enters the tracking
loop, which is why the fixture drills to 7 passes and `defaults write` switches were mostly quiet;
a real click does, which is why clicking reproduces every time. It also explains the offscreen
fixture's immunity — a window that is never key gets no mouse tracking at all.

**The candidate fix followed directly** — defer the tap gesture's `onNavigate` by a runloop turn as
the List path already does — **and it was wrong.** It was built, installed and clicked; the section
above this one records what happened (worse churn, and the dead click back). Kept here because the
reasoning still reads as sound and the next person will otherwise re-derive it: the flaw is not in
the observation, it is in assuming that deferring work off a loop calms the loop.

## The next lead

**That step has been taken** — the trace is armed, the repro is traced, and the sections above
carry the numbers. What is left is the next *candidate*, and the falsification above narrows it
usefully: **the loop is not about when the column-stack restructure is issued, so look at what the
restructure does.** A drill adds a column, which is a whole new `List` / `NSTableView` /
`NSHostingView` subtree, while the rows of the existing columns are still measuring themselves —
and the crash's own frame is a row reporting a new ideal height from inside the pass. Whatever a
newly-inserted column does to its siblings' height measurement is the part nobody has looked at
yet.

Two cheap things still unrecorded, worth taking on the next armed session:

- **Which window.** The trace counts per window and the suppression is app-global. The pane and the
  picker popover are both now known to churn (the popover at 21–31 passes against 53–57 views); the
  Settings sheet and the Activity Log have never been checked.
- **The duty cycle.** Arm `paneScrollTraceEnabled` alongside for `MainThreadHitchMonitor`'s line.
  The cost is no longer unknown — a 4.7 s and a 20.8 s click are on the record — but the duty-cycle
  trace would say what the main thread was doing across the whole switch rather than at one click.

The open "first column moves up and down" report (see `PaneColumnJitterProbe`) is now very likely
this same loop at sub-fatal amplitude: same window, same clicks, and a click that takes seconds to
settle is exactly what a column parking and snapping back looks like from the outside.

**What is now known not to be the difference**, from the fixture table above: it is not the number
of panes, not the drilled column stack, not the preview column, not the fractional stored preview
width, not the action bar's placement plumbing, and not the risky-name badge — which was the best
v3-only lead there was. Nor is it whether the window is on screen.

### The `withAnimation` edge flip is NOT among them — it never fired

Corrected 2026-08-04, by counting rather than by reading. `TwoPaneHarness` wires
`onBarEdgeFlip` exactly as `ContentView` does, which is what made it look covered. Instrumenting
that closure and running `testTwoPaneProviderSwitchStaysInsideTheDisplayCycleBudget` reports
**`onBarEdgeFlip` fired 0 times**. The 7-passes result is real; it is just silent about this path.

Two independent reasons, and the second is the one that matters:

1. *In that fixture specifically* — the harness never calls `placement.resolveAtTop(selection:)`
   from the host and mounts no bar overlay, so `barSelection` stays empty, `reresolveAtTop()`
   always answers `false`, and `flipEdgeIfScrolledAcross` returns at its `!=` guard every time.
2. *In any fixture* — `flipEdgeIfScrolledAcross` calls back only when `reresolveAtTop()` disagrees
   with the committed `atTop`, and the host commits **synchronously from its own `body`**
   (`ContentView`: `let barAtTop = placement.resolveAtTop(…)`). So **a selection change can never
   produce a flip**; only geometry moving under an unchanged selection can, which in the app is a
   scroll. And a scroll does not re-render the host, because `PaneBarPlacement` is a plain class —
   that asymmetry is the design, and it is what makes the callback the only observer that notices.

   In a fixture the asymmetry inverts. Every available lever for moving geometry — mutating an
   `@Published`, resizing the window, `contentView.scroll(to:)` — either re-renders the SwiftUI
   root, so the host's `resolveAtTop` commits *first* and the callback finds nothing changed, or
   moves AppKit's clip view without re-driving SwiftUI's geometry preferences at all. Measured on a
   harness built specifically to arm it — two panes, a live `resolveAtTop` from the host, a bar
   overlay on the resolved edge, the selection on the lowest row the bar actually covers, then six
   rounds of scroll + resize: **zero flips**.

`PaneBarPlacementCommitTests` pins the half of this that is assertable, so the reason stays
executable rather than being rediscovered: the edge really moves on a selection change, and no
callback is made while it does.

**So the edge flip is un-ruled-out, and it cannot be ruled out from a fixture.** It needs a real
scroll gesture inside the List, i.e. the live session — which is where the trace already points.

So the remaining suspects are the things the fixture still does not have: **the edge flip under a
real scroll**, the real `PaneActionDelegate` and `FileSyncManager` with its ~56 published
properties, the surrounding chrome (header ladder, differences bar, action bar overlay, workspace
rows), and a provider switch that is a real asynchronous load rather than two synchronous
assignments. All but the first can be added to `ColumnsDisplayCycleTests` one at a time now, and the
pass count says immediately whether it mattered — which is the point of having built the instrument.
