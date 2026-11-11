# Logging

How SyncCloud's log works, which level a line gets, and who reads the text. Read it before adding,
re-levelling or rewording a log line.

## How it works

- One logger, `Logger.shared` (`Modules/Events/Sources/Events/Logger.swift`): `debug`, `info`,
  `warning`, `error`. `warning` and `error` append ` | Location: File.swift:line / function`.
- Two sinks: `~/sync-cloud.log` (5 MB cap, trimmed to its newest half) and the Activity Log's last
  1,000 entries. Nothing goes to unified logging.
- The shipped level is **Info** (Settings ▸ Advanced ▸ Log level, `logMinimumLevel`). Arming a trace
  switch (`paneScrollTraceEnabled`, `displayCycleTraceEnabled`) runs that launch at Debug and says
  so. The launch line states the level: `SyncCloud 7.1-dev (build 701, log level Info) launched`.
- Tests always run at Debug, and no test may move `Logger.shared.minimumLevel`
  (`LogLevelWriteScanTests`): `LogCapture`'s flush marker is a Debug line.
- The CLI adopts the app's level in each command and writes a start line.

## Levels

**ERROR** — an item the user asked for did not happen; their data, or a record the app keeps for
them (history, spend, profiles, people), is lost or at risk; or our own request to a service was at
fault. The app could not recover. *"FAILED to redo …"; a bulk-sync item not copied; spend not
recorded.*

**WARN** — the app refused for safety or worked around a problem, and the result differs from what
the user expected and wasn't explained on screen; a command that partly completed with nothing
lost; an outside service that gave up. A user's choice is never WARN, unless it discards the only
copy of unsaved work. *Undo refused because the item changed; a cross-volume move reverted; a stall
while the app is in use.*

**INFO** — the default. One line per operation or command (start, finish, counts, time); facts once
per launch; any outcome or decision the user may ask about later that nothing else records; a limit
or state the UI already explains. *`[scan] #1 completed: found 589 differences in 211.4 ms; walked
1204 files and 87 folders on the left, 1198 files and 86 folders on the right`;
`User triggered Redo: …`; a collision skipped by policy, naming the file.*

**DEBUG** — UI mechanics fired per click, keystroke or frame; timing traces; diagnostic anomalies
with no effect on the user. *`[columns] left pane depth 2 → 3`; a collision replaced by policy.*

### Precedence

Apply in this order; the first rule that applies wins.

1. A detail line takes the level of the item line it explains.
2. An outcome or decision the user may ask about later, never an input, that nothing else records
   is at least INFO.
3. UI mechanics per input are DEBUG. A command the user invoked never counts as mechanics.
4. A user's choice is INFO; discarding the only copy is WARN.
5. A limit or refusal the UI already states is INFO.
6. A command partly done with nothing lost is WARN.
7. An outside service: INFO while the app retries on its own; WARN once it gives up or tells the
   user to try again; ERROR when our own request was at fault.
8. A record kept for the user that isn't saved is ERROR; an unsaved cache is WARN.

## House rules

- **One physical line per entry.** `LogEntry` collapses line breaks; don't rely on it.
- **Never drop a name.** Lists use `LogNames.lines`: sorted, at most 200 names or 16 KB a line,
  continuation lines saying which slice. A batch's failures use `GroupedFailureLog`: one line per
  kind of failure, keyed by `LogError.groupKey`, never by the description, which names the file.
- **Errors go through `LogError.describe`**: a system error gives domain, code, message and
  underlying error, never its whole userInfo; the app's own errors keep their reason.
- **Ask Claude:** no words from the user's question, at any site (`AskClaudeToolOutcome.logStep`).
  Anthropic's error message is allowed, capped at 300 characters (`AskClaudeProblem.httpLogLine`).
- **Banners state their log level** (`OperationBanner.LogLevel`). `.loggedAtSite` is only for a
  banner whose site logs its own WARN or ERROR beside it (`BannerLoggedAtSiteScanTests`).
- **Once-per-X gates** (`OncePerLaunch`, `FilingWarningBudget`) name their key and scope, and say
  what they held back.
- **Copy rules apply to log text outside a `Logger` call:** a standalone literal needs curly
  apostrophes and US spelling, or a name the copy scan reads as a log line (`logLine`).

## Sharing the log

The file keeps paths, emails and names: they are what make it useful, and it never leaves the Mac
on its own. **Copy Log for Sharing** (the Activity Log's bar, Settings ▸ Advanced) copies the whole
file masked (`LogSharing`): emails (keeping a `GoogleDrive-` or `OneDrive-` prefix), the home
folder and account name, and every name form of everyone in every profile's `people.json`, as
`<person N>`. The copy's header says what it doesn't mask. A new kind of identifying text in a log
line needs a masking step there, or a word in that header.

## Stalls

`MainThreadStallWatch` writes a sampled stall at WARN, unless `StallClassifier` finds it short
(10 s or less), mostly idle and over a hidden, inactive app with no activation near it: those are
counted, in one INFO line written when the app comes forward, every 30 minutes and at quit. A stall
still going after 10 s gets its own WARN line at once. Each of these lines ends `(pid N)`.

## Who reads the log

| Reader | Depends on | Emitted at |
|---|---|---|
| install-sync-cloud skill | `\[INFO\] SyncCloud .+ launched$`: the line must end in "launched" | `SyncCloudApp.swift` (`applicationDidFinishLaunching`) |
| CLAUDE.md §6, the skill | `Code signature: …`, `SyncCloud is quitting` | `LaunchSignature.swift`, `SyncCloudApp.swift` |
| Activity Log | `[timestamp] [LEVEL] `, the level spelled `WARN`, the ` \| Location: ` tail, and the fold prefixes `Synced file: ` and `Filing: filed ` | `Logger.swift`, `LogGrouping.swift` |
| `docs/columns-layout-loop.md` | `[cycle]`, `[layout-guard]` words, and the Debug interaction lines `[click]` `[columns]` `[crumb]` `[deselect]` (arm a trace switch, or set Debug) | `DisplayCycleTrace.swift`, `SyncCloudApp.swift`, pane code |
| `MANUAL_CHECKS.md` | the pane-chord aim line; `[load]` lines (Info only when slow or stranded) | `FileSyncManager+Navigation.swift`, `+Scanning.swift` |
| Stall tests | the prefix `[stall] main thread went` | `MainThreadStallWatch.swift` |
| Tests | many lines by text and some by level; grep a line's literal text across every Tests tree, including string literals (some tests read production source), before rewording it | — |
