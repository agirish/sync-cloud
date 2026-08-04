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
| two panes in Columns, both drilled, preview up, real `PaneBarPlacement` and the host's `onBarEdgeFlip`, right pane's provider switched | 348 | **7 passes** |
| the same, with a **risky-name badge on every row** | 348 | **7 passes** — no change at all |

The second is `ContentView.treeView`'s actual composition — `FileTreeView` in columns mode,
`.equatable()`, the row-bottoms preference feeding a live placement, the edge-flip callback writing
host state inside `withAnimation` — and not one of those brought it near the budget.

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

## The next lead

**Arm `displayCycleTraceEnabled` and do the manual repro.** That is now the shortest path to a real
number, and it needs no crash: the trace reports the pass count whether the session dies or
survives, which is precisely what the crash-rate variance made impossible before. A switch that
spends 300 passes against 400 views names the loop as still live even on a session that happens not
to die; one that spends 7, like the fixture, says the runaway needs something neither the fixture
nor that session had.

Two things to record while doing it, because both are cheap and neither is known:

- **Which window.** The trace counts per window, and the suppression is app-global — the Settings
  sheet and the Activity Log run unguarded too. Nobody has checked whether they churn.
- **What it costs.** Arm `paneScrollTraceEnabled` in the same session for
  `MainThreadHitchMonitor`'s duty-cycle line, and the "unmeasured cost" section above closes.

After that, the open "first column moves up and down" report (see `PaneColumnJitterProbe`) is
plausibly this same loop at sub-fatal amplitude, and the trace is the way to tell: if the jitter
coincides with cycles above the floor, it is one bug, not two.

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
