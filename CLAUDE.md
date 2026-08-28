# SyncCloud — working agreement

## Three release lines: `main` is v4, `v3.x` and `v2.x` are maintenance

Three long-lived branches, and only three. Every shipped major keeps a maintenance line, cut from
that major's last tag when the next major opens on `main`:

| Branch | Carries | Marker at tip | Breaking changes |
|---|---|---|---|
| `main` | the **v4 line** — where the next release is built | `4.7-dev` / `407` | **allowed** |
| `v3.x` | maintenance for the shipped **3.x series** (cut at `v3.1`, 2026-08-11) | `3.2-dev` / `302` | **never** |
| `v2.x` | maintenance for the shipped **2.x series** (cut at `v2.8`, 2026-08-01) | `2.10-dev` / `210` | **never** |

**Land on `main`. No backporting — standing direction, given 2026-08-26 without a scope limit
(`e2b35dad`), and it governs new work generally rather than one batch.** This replaced an
oldest-line-first rule; do not re-derive that rule from the shape of the table, and do not re-raise
the question per batch.

**Record the gap anyway, in [`docs/backports.md`](docs/backports.md).** Those rows are now a
*record* of what `main` carries that `v3.x` and `v2.x` do not — what a future audit needs if the
direction ever changes — not a to-do list. Write down both directions: "checked and not owed" saves
the next audit as much time as "owed", and the per-file pick notes are the expensive half to
reconstruct. The file is carried on all three lines, so a maintainer on a maintenance line can read
it without going through `main`. Largest known gap: **`v3.x` has none of the `DeleteOutcome`
family**, so it cannot tell a trashed item from a permanently deleted one and offers ⌘Z for removals
it cannot take back.

Two commands answer "does this line even carry the code?", if an audit ever needs it:

```sh
for l in v2.x v3.x; do git ls-tree -r --name-only origin/$l -- <path>; done
diff <(git show origin/main:<f>) <(git show origin/v3.x:<f>)
```

**If a maintenance line is ever cut again, add its row here and to `branches:` in
`.github/workflows/tests.yml` in the same commit that pushes the branch.** `v3.x` sat undocumented
for eleven days: this file said "two lines", so every session backported to `v2.x` and `main` only,
52 commits landed on `v2.x` unexamined for 3.x, CI never ran on `v3.x` at all, and its tip sat on the
plain number `3.1` — exactly what "re-bump immediately" exists to prevent.

**Never merge one line into another.** All three stay linear; move commits with `git cherry-pick`.

**`origin` carries the three lines and nothing else — and that is a thing to CHECK, not assume.**
A `roots` branch sat on `origin` from the roots work until 2026-08-27, unnoticed because nothing
here or in the install skill ever looked. `git branch -d roots` refusing — *"not yet merged to
`refs/remotes/origin/roots`"* — was the only thing that revealed it, which is luck rather than a
process. One command, and it prints exactly three lines when the remote is clean:

```sh
git ls-remote --heads origin | awk '{print $2}'   # expect refs/heads/{main,v2.x,v3.x}, nothing else
```

A fourth is scaffolding by the rule below and can go — but **deleting a remote branch is
outward-facing, so establish that nothing unique dies first and ask before pushing the delete.**
Two checks settle it: `git diff --name-status main <branch> | grep '^A'` must print nothing (it
adds no file `main` lacks), and a local branch at the same SHA means the commits outlive the
remote ref. `roots` passed both — its tip was `backup-roots-preReviewSquash2` — and its two
commits were a superseded two-round version of a review `main` carries at three rounds.

Releases are cut as **tags on the line that owns them** — `v2.9` from `v2.x`, `v4.0` from `main`.
Tags mark history and are never branched from, except once when a new maintenance line is cut from a
major's last tag; these three branches are the only ones that persist.

**One branch is a deliberate exception, and it is written here so nobody tidies it away:
`candidate-tap-deferral` (`dba29645`).** It carries a single unlanded 2026-08-04 commit — the tap
gesture's drill deferred out of `NSTableView`'s tracking loop — that was built, installed, clicked,
and **falsified**: roughly four times worse (13,882 passes against 3,615; a 20.8 s click against
4.7 s) plus six dead clicks. [`docs/columns-layout-loop.md`](docs/columns-layout-loop.md) cites the
branch by name and SHA precisely so that result stays reproducible instead of becoming folklore, and
`main` still drills synchronously on purpose. A tag would be the tidier home for it, but the tag
namespace is release-only (`git tag | grep -v '^v[0-9]*\.[0-9]*$'` must stay empty), so the branch
is where it lives. **Delete it and the doc cites a SHA that git will eventually collect.** Any other
branch you find is scaffolding and can go.

## Session isolation: work in a worktree, land on your target line directly

The goal is a **linear `main`** where every completed change lands directly — no long-lived feature
branches, no PRs. But **in-progress (uncommitted) work must never share a working tree with another
session**: on 2026-07-13 several sessions edited the shared `main` checkout at once and their
uncommitted changes got entangled. `/Users/abhishek/Projects/SyncCloud` is the shared landing zone,
not a scratch space — do not edit it while work is in progress.

1. **Start** — worktree on a fresh branch off the line you are targeting (`origin/main` for v4 work,
   `origin/v3.x` / `origin/v2.x` for a maintenance fix):
   ```sh
   git -C /Users/abhishek/Projects/SyncCloud fetch origin
   git worktree add /Users/abhishek/Projects/SyncCloud-<task> -b <task> origin/<line>
   ```
   This is an **xcodegen** project — run `xcodegen` in the new worktree before `xcodebuild`.

2. **Work** — all changes inside that worktree; nothing leaks until you deliberately commit.

3. **Finish — land on the target line directly.** Only once the work is complete:
   - Commit on the worktree branch (imperative subject; prose body explaining *why*; trailer
     `Co-Authored-By: <model> <noreply@anthropic.com>`).
   - Rebase onto the latest `origin/<line>` if the line moved.
   - **Drop the empty `WIP` commit from step 1 — it is scaffolding, not work.** Nothing else in
     this step removes it, and every landing verb here takes the WHOLE branch: `merge --ff-only`
     and `push <task>:<line>` both carry it onto the line, where it is permanent. Four sit in
     `main`'s history (`33c25bd2`, `8456c9d0`, `ea6441bf`, `a6622782`) from sessions that followed
     every other line of this step exactly — which is the point: the rule that mints the commit
     has to be the rule that retires it.
     ```sh
     git rebase --onto origin/<line> <the-WIP-sha> <task>   # replays the real work only
     git log --oneline --format='%H %s' origin/<line>..<task> |
       while read sha rest; do [ -z "$(git show --stat --format= $sha)" ] && echo "EMPTY: $sha $rest"; done
     ```
     The second command prints nothing when the branch is clean, and names the offender when it is
     not. Run it before landing, not after: removing one afterwards needs a force-push to a branch
     other sessions are working on, which is why the four above are staying.
   - Fast-forward the primary checkout — **no merge commits**. The primary tracks `main`; to land on
     a maintenance line, push the branch straight to it:
     ```sh
     git push origin <task>:v2.x        # v2.x (likewise <task>:v3.x)
     git -C /Users/abhishek/Projects/SyncCloud merge --ff-only <task> && git push   # main
     ```
   - Record any maintenance-line gap in `docs/backports.md` — a record, not a to-do; see the
     standing direction above. (If a maintenance fix is ever authorised again, pick it forward in
     the same session, `v2.x` → `v3.x` → `main`, and verify by CONTENT: a cherry-pick has a new SHA,
     so `git branch -r --contains` answers about the wrong commit.)
   - `git worktree remove /Users/abhishek/Projects/SyncCloud-<task>`.

Commit and push **proactively** as work lands; don't wait to be asked each time.

## Cutting a release

**The version bump is part of the release, not a follow-up.** Between `v0.10` and `v2.8` the version
in `project.yml` never moved, so all twenty-odd tagged releases installed an app reporting itself as
**1.0 (build 1)** — in the Settings rail, in `~/sync-cloud.log`, and in Finder's Version column.
Nothing failed, because nothing reads the version; it was simply wrong for two years.

### Where the version lives

`project.yml` is the only source of truth:

```yaml
# main's values; v3.x carries "3.2-dev" / "302", v2.x carries "2.10-dev" / "210"
CFBundleShortVersionString: "4.7-dev"   # the marketing version — what people see
CFBundleVersion: "407"                  # the build number — what Launch Services orders by
```

`MacApp/Info.plist` is **generated from it by xcodegen and tracked in git** — run `xcodegen` after
editing `project.yml` and commit both; a `project.yml` edit alone leaves the tracked plist stale.

Two things read the version, both display-only — there is no version-keyed migration or compare
anywhere, which is what makes changing it safe:

- the Settings rail — `Modules/Settings/Sources/Settings/SettingsLayout.swift`
- the launch breadcrumb in `~/sync-cloud.log` — `MacApp/SyncCloudApp.swift`

**Three places repeat the number instead of reading it, and all must move in the same commit** —
they are copies, so nothing fails when they drift:

- the `versionMarker` literal in `Modules/Settings/Tests/Settings/SettingsLayoutTests.swift` (step 2)
- the branch table above, and the example block just above this list (a compaction removed the
  third spelling this once pointed at — under **The two numbers** nothing repeats the tip marker
  any more)
- `MacApp/Info.plist`, which xcodegen regenerates

The table is the one that gets missed — the v4.2 re-bump moved `project.yml` and the test literal but
left all three lines' tables reading `4.1-dev` / `401`, and the table is what a session consults
*before* a cut. This prints nothing when the table is right, and names the offender when it is not:

```sh
for l in main v3.x v2.x; do
  m=$(git show origin/$l:project.yml | grep -o '"[0-9.]*-dev"' | tr -d '"')
  r=$(git show origin/main:CLAUDE.md | grep "^| \`$l\`" | grep -o '`[0-9.]*-dev`' | tr -d '`')
  [ "$m" = "$r" ] || echo "$l: table says $r, project.yml says $m"
done
```

### The two numbers

**Marketing version.** Between releases each tip carries a **pre-release marker** suffixed `-dev` for
the version it is heading toward. The suffix says "this build is no release" without implying a
distributed beta. A release drops the suffix and the tip is re-bumped straight afterwards, so a plain
number like `2.9` is only ever what the tagged commit itself carries.

Non-numeric is deliberate and verified: SyncCloud is distributed directly, not through the App Store,
so `CFBundleShortVersionString` is a free-form display string. Measured on a real Release build —
Launch Services stores `3.0-dev` verbatim and Spotlight emits `kMDItemVersion = "3.0-dev"` (Finder's
Version column); LS *orders* on `CFBundleVersion`, not on this string. (The App Store's 1–3-integers
rule would apply only on submission, and would mean dropping the suffix, nothing more.)

**Build number.** `CFBundleVersion` = **MAJOR × 100 + MINOR** — `2.9` → `209`, `2.10` → `210`,
`3.0` → `300`. One integer, so it orders correctly under both numeric and naive string comparison
(`"2.10"` vs `"2.9"` does not); it increases across all lines at once, so a v4 build always outranks
a v3.x one; and it is derived rather than being a second thing to remember. It changes in the same
edit as the marker, and the `-dev` build shares it with the release it becomes — fine, because it
identifies the version, not the build. **Keep MINOR under 100** or it stops being monotonic.

### Writing the notes, and auditing every claim in them

**The notes are part of the release too** — v2.9 reached the point of being tagged with none, because
nothing here said to write them. They live in two places:

- `RELEASE_NOTES.md` — `main` is the superset. **The test is whether a section is addressed to that
  line's reader, not whether the files match byte for byte**, so `cmp` is not the check and a section
  `main` has that a maintenance line lacks is not a finding. Baseline (2026-08-17, all correct):
  `v2.x` and `v3.x` are byte-identical and agree with `main` from `## v3.0` down; `main` adds `v4.0`
  onward plus four bullets retrofitted into `## v3.1` (`27fa9c14`).
- `docs/releases.html` — **`main` only.** Pages serves `docs/` from `main`. Add the new article ahead
  of the last one.

**The badge flips at the cut, not when the notes are written.** Pages goes live the moment the notes
land, so an article carrying `latest` announces a release nobody can install — v4.2 shipped that way
and had to be fixed on a live site. A draft lands as `<article class="rel draft">` with
`<span class="tag draft">In development</span>`, the previous release **keeps** `latest`, and the
footer reads `Changes so far: <tag>...main` (the compare link cannot name a tag that does not exist).
`RELEASE_NOTES.md` gets `## <version> — DRAFT, not released` plus a blockquote. `586333f8` is the
v4.1 cut that did it right; these flip in step 1 of **Cutting it**.

**That is not a checklist of everything to flip — a draft says "not released" in prose too, and
prose has no markup to enumerate.** The v4.3 draft carried an HTML comment and a `<b>Not released
yet</b>` clause opening the lede — the first sentence a reader sees — and both survived a flip that
moved every marker correctly. Neither was reachable from a markup checklist because neither existed
when it was written, and the next draft will invent its own. **So grep for the words, before you
commit:**

```sh
grep -in 'draft\|not released\|still to come\|changes so far\|in development' \
     RELEASE_NOTES.md docs/releases.html
```

It never comes back empty — read it, do not count it. At the v4.5 cut the survivors were the three
`.rel.draft` CSS rules (the next draft needs them) and one v4.1 bullet using "draft" about a rule the
editor is composing. **A hit inside the release being cut is the finding; every other hit must be
named.**

**A "Still to come in <version>" section cannot survive the cut it was written ahead of.** What is
missing at the tag is a limitation, not a promise: rename it to `### Known limitations`, and reword
the HTML `<p class="known">` to "**Not in vX.Y.**".

**Then audit every claim against the previous tag** — one command per claim, did this exist at the
last tag?

```sh
git grep -l "<symbol>" v4.4 -- Modules SyncCloudCLI MacApp | grep "/Sources/"
```

- **Audit the section before its bullets.** A feature that arrives inside the range has no prior
  behaviour to be better than, so every "used to / was doing" clause in it is false by construction.
  Five of eleven v4.1 tab bullets carried one. Delete them in one pass.
- **Cut the self-inflicted** — introduced *and* fixed inside the range, so no user of the previous
  release was ever exposed. Five of v2.9's eighteen.
- **A commit whose subject is about coverage is not a user-facing fix.** One v2.9 entry credited a
  behaviour the release already had; the commit had added a *test*.
- **A new file does not mean a new bug.** Two v2.9 claims survived a `git blame` challenge because
  the code was refactored in-range while the behaviour predated it. That direction matters as much.
- **A number that lives in prose rather than test output has not been checked.** Both figures in
  v4.1's pane-bullet were wrong; chasing one turned up `ScaledFont.nsFont(scale:)` silently dropping
  `.rounded` (`97154a32`). Treat a number you cannot reproduce as a finding, not a rounding
  difference — and prefer printing the measurement ("about 37 ms a pass, now about 2 ms") over
  describing it ("an order of magnitude"), because only the first is checkable by the next reader.
- **A number in a TEST's doc comment is still prose, and can go stale inside one release.** v4.5 said
  "twenty-six glyph-only buttons" on the authority of the scan that produced it — and a later commit
  in the same range named two more. Count the net against the tag:
  `git diff v4.4..HEAD -- 'Modules/*/Sources/*' 'MacApp/*' | grep -c '^+ *\.accessibilityLabel('`.
- **A quoted UI string is a claim.** v4.5 told readers a feature was "still available as *Mentions
  all of*"; the label is "Mentions the words". One `git grep` on every quoted label — a reader takes
  it into the app and looks for it.
- **A sentence about how the code is *structured* needs the same grep as one about what it does.**
  Two v4.1 claims asserted the opposite of the code, from intent. Publishing that a drift hazard is
  structurally prevented, when only two copies currently agreeing prevent it, is worse than silence.

Two tells. **"again"** in a claim ("fits on a small display *again*") usually means the release broke
it in the first place. And a **short list after a large range is the honest outcome**, not a failure
of the notes — v2.9's headline became its test volume, the one superlative that survived checking.

### Cutting it

Tags are **two components** — `v2.9`, never `v2.9.0`; `git tag | grep -v '^v[0-9]*\.[0-9]*$'` should
stay empty. Work in a worktree as always.

1. **Drop the suffix, and publish the notes with it.** In `project.yml`, `2.9-dev` → `2.9`. Leave
   `CFBundleVersion` alone — it is already `209`. In the same commit take the notes out of draft:
   `RELEASE_NOTES.md`'s DRAFT heading and blockquote go; on `docs/releases.html` the article loses
   `class="rel draft"`, its tag goes `draft`/"In development" → `latest`, the previous release trades
   `latest` for a theme tag, and the footer goes `Changes so far: <prev>...main` →
   `Full changelog: <prev>...<new>`. Then convert the "Still to come" section and **run the word-grep
   from "Writing the notes" above, before you commit** — the markup list is not the whole set. v4.3's
   flip got every marker right and still landed with two "not released" sentences intact, and because
   Pages publishes on the push, the live page carried a `Latest` badge over a lede reading "Not
   released yet" until the follow-up commit caught it.
2. **Regenerate and update the test marker.** Run `xcodegen`, and set `versionMarker` in
   `Modules/Settings/Tests/Settings/SettingsLayoutTests.swift` to the same string — that literal is
   what gives `theVersionLineFitsTheRailOnOneLine` something real to measure (see below).
3. **Commit, land on the line, and let CI go green for that SHA — and STAY OFF THE MACHINE while
   it runs.** The self-hosted runner IS this Mac. The v4.5 cut took three attempts on one SHA:
   attempts 1 and 2 failed while local `swift test` runs were competing with the runner, and
   attempt 3 went green on the same commit, no code changed, with the machine quiet and the load
   average down from 6.61 to 4.20. Both flake families here — gate parking and log-buffer eviction,
   mechanisms 10 and 12 in `docs/flaky-tests.md` — are load-sensitive, so a busy machine
   manufactures exactly the reds that look like a bad release. Check `uptime` and
   `gh api repos/agirish/sync-cloud/actions/runners --jq '.runners[].busy'` BEFORE rerunning, and
   budget a rerun into the cut rather than reading the first red as a verdict. The discriminator, if
   you need one: run the failing suites locally at the red SHA — sub-second green there against a
   ~12s timeout on CI is load, not code.

   Then **check that the folder survey's ground truth actually ran**, which a green run does not
   tell you:
   `FolderSurveyGroundTruthTests` is the only suite comparing the survey rules to a real tree, and it
   is gated on a live profile and an awake display, so it is routinely absent from a green package
   run. `FolderSurveyGroundTruthGateTests` always runs and prints the verdict:

   ```sh
   gh run view <run-id> --log | grep '\[ground-truth\]'   # want: RAN — …
   ```

   A `SKIPPED` line names which gate closed it. On CI it always says `liveProfile is in
   SYNCCLOUD_SKIP_MACHINE_PINNED` — that gate never opens there, by design — so the only way to get
   a RAN is locally, and the display must be **woken and HELD**: `caffeinate -u <cmd>` only prevents
   sleep and a short `-t` expires during the rebuild, before the gate reads it.
   `nohup caffeinate -u -t 1200 &`, run it, then `pkill` the hold. Not a reason to hold the cut on
   its own, but a reason not to believe the rules were checked against reality in it.
4. **Tag that exact commit and push the tag** — `git tag v2.9 <sha> && git push origin v2.9` —
   **before** creating the GitHub release, so the release binds to a tag that already exists. Then
   cut it, and **pass `--target` explicitly — it is the line that owns the release, not the default
   branch**:

   ```sh
   gh release create v2.9 --target v2.x \
     --title "v2.9 — <the lede, shortened>" --notes-file <body> --latest
   ```

   Without `--target`, `gh release create` stores the repo's **default branch** (`main`) as
   `target_commitish` even when the tag is on `v2.x`; v2.9 shipped that way. Nothing public renders
   it, but it is wrong in the edit view and every API read, and invites exactly the question "was
   this cut from main?" about a maintenance release. Fixable after publishing — the API's "unused if
   the Git tag already exists" caveat governs tag *creation*, not the stored value:

   ```sh
   RID=$(gh release view v2.9 --json databaseId --jq .databaseId)
   gh api --method PATCH repos/agirish/sync-cloud/releases/$RID -f target_commitish=v2.x
   ```

   **Then re-verify the tag did not move** — the real risk in editing a published release.
   `gh api repos/agirish/sync-cloud/git/refs/tags/v2.9 --jq .object.sha` must be unchanged and
   `git branch -r --contains <sha>` must still name `origin/v2.x` alone. Do not "correct" **v2.8**,
   whose release says `main` and is right: it was tagged before the `v2.x` split at `0f016480`.
5. **Re-bump the tip to the next marker, immediately.** After `v2.9`, `v2.x` becomes `2.10-dev` /
   `210`. **A freshly cut maintenance line needs the same re-bump in its first commit** — `v3.x` was
   cut from `v3.1` and left on `3.1` / `301` for eleven days. Same edit shape as step 1 plus
   `xcodegen`, its own commit. Now, not next time.
6. **Install and confirm what the app reports.** Run the `install-sync-cloud` skill and check the
   first line of `~/sync-cloud.log` names the version you just cut.

### The version line has a width budget

The rail's version line is the one thing a version bump can actually break. `SettingsRail` is
**fixed-width (176pt) and does not scroll**, and the line has no `lineLimit`, so an over-wide string
wraps to a second row rather than clipping — and at the sheet's floor size that extra row takes the
Large text size over its opening, which has only 0.4pt of margin.

`Bundle.main` under `swift test` is the test host and carries **no** version, so the line does not
render on its own and every rail test was blind to it. `SettingsRail.versionText` is the seam that
fixes that: the tests inject `versionMarker` and really lay the line out. **Keep that literal in step
with `project.yml`** — the whole reason step 2 exists.

Measured room is 142pt against 119pt for `SyncCloud 3.0-dev` at the largest text size — about three
characters spare, comfortable out to roughly a 21-character line (`10.10-dev` still fits). If a
version does get long enough to matter, `theVersionLineFitsTheRailOnOneLine` fails and names the
number; do not widen the rail without re-measuring the tabs that share its opening.

## After shipping an app change

Run the `install-sync-cloud` skill (quits the running instance, installs the fresh build to
`/Applications/SyncCloud.app`, de-dupes the DerivedData copy from Spotlight, then sweeps stale build
debris). It launches and verifies the app itself — **by polling `~/sync-cloud.log` for a new line,
not by `pgrep`**: a silent `open` exit is not proof the app started, and neither is a live pid. The
app can come up wedged with zero windows and an empty log, which is exactly what `pgrep` cannot see.

## Correctness bar

Refactors must be provably behavior-preserving: build the pre-change binary at `HEAD` and diff
stdout / exit codes / resulting file trees against the new binary on a controlled fixture. State the
verification in the commit body. He runs this against real cloud data and audits commits, so silent
behavior changes are costly.

**Before blaming a commit for a red suite, read [`docs/flaky-tests.md`](docs/flaky-tests.md).** It
carries the known flake mechanisms with the tell for each, and it is the difference between fixing a
regression and re-diagnosing a machine. It is carried on all three lines, but **the numbering is
per-line and the counts differ** — cite a mechanism by its title, never by its number.
