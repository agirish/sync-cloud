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

`SyncCloudApp.init` now logs which state the session is in, so `~/sync-cloud.log` answers this
without anyone re-deriving it — `[layout-guard] … suppressed app-wide`, or `… ARMED by an explicit
override` when a `defaults write` or launch argument has put the crash back.

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

The open "first column moves up and down" report (see `PaneColumnJitterProbe`) is plausibly this same
loop at sub-fatal amplitude. Chasing it would give a signal that is observable without a crash, which
is exactly what the measurement problem above calls for.
