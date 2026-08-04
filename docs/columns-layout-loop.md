# The Columns display-cycle crash

A hard crash — `EXC_BREAKPOINT` in `+[NSApplication _crashOnException:]` — taken four times by one
user on 2026-07-27 and 2026-08-02, plus five more driven deliberately while investigating. **The
symptom is suppressed; the underlying layout loop is not fixed.** This file is the standing record so
the next attempt does not re-run the three investigations that came before it.

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

## Ruled out, by measurement

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

The open "first column moves up and down" report (see `PaneColumnJitterProbe`) is plausibly this same
loop at sub-fatal amplitude. Chasing it would give a signal that is observable without a crash, which
is exactly what the measurement problem above calls for.
