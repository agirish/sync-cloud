# SyncCloud — working agreement

## Three release lines: `main` is v4, `v3.x` and `v2.x` are maintenance

Three long-lived branches, and only three. Every shipped major keeps a maintenance line, cut from
that major's last tag when the next major opens on `main`:

| Branch | Carries | Marker at tip | Breaking changes |
|---|---|---|---|
| `main` | the **v4 line** — where the next release is built | `4.6-dev` / `406` | **allowed** |
| `v3.x` | maintenance for the shipped **3.x series** (cut at `v3.1`, 2026-08-11) | `3.2-dev` / `302` | **never** |
| `v2.x` | maintenance for the shipped **2.x series** (cut at `v2.8`, 2026-08-01) | `2.10-dev` / `210` | **never** |

**Decide where work goes before starting it:**

- **Breaks behaviour, removes a feature, or restructures** → `main` only.
- **Everything else** → land on the **oldest line that carries the code**, then cherry-pick forward
  onto every newer line, in the same session. Oldest-first because a patch written against 2.x
  almost always applies forward; a fix written on `main` "to backport later" is how a fix gets lost.
  Three lines means three landings — that is the cost of keeping the lines, not a reason to skip one.
- **Code that exists only on `main`** → `main`.

**"Applies" means the code is there, not that a user would notice.** Deliberately low bar: bug fixes,
minor features needing no redesign, test-only changes, flake fixes, docs and tooling all go to every
line carrying the file. The narrower reading ("only what matters to someone running 2.8") is what
this said before, and under it a shared test helper's fix read as a judgement call to argue rather
than the default — nothing announces a maintenance line quietly keeping a defect its own CI hits.

Two commands settle it per line; byte-identical files cherry-pick clean:

```sh
for l in v2.x v3.x; do git ls-tree -r --name-only origin/$l -- <path>; done   # which lines carry it?
diff <(git show origin/main:<f>) <(git show origin/v3.x:<f>)
```

**What each line is OWED is tracked in [`docs/backports.md`](docs/backports.md)** — confirmed gaps,
families checked and deliberately *not* owed, and the size of the unaudited surface. Carried on all
three lines, so a maintainer on `v2.x` or `v3.x` can read it without going through `main`. Record
decisions there in either direction: "checked and not owed" saves the next audit as much time as
"owed". Open and deliberately deferred: **`v3.x` has none of the `DeleteOutcome` family**, so it
cannot tell a trashed item from a permanently deleted one and offers ⌘Z for removals it cannot take
back — a scope call, reasoning in that file.

**If a maintenance line is ever cut again, add its row here and to `branches:` in
`.github/workflows/tests.yml` in the same commit that pushes the branch.** `v3.x` sat undocumented
for eleven days: this file said "two lines", so every session backported to `v2.x` and `main` only,
52 commits landed on `v2.x` unexamined for 3.x, CI never ran on `v3.x` at all, and its tip sat on the
plain number `3.1` — exactly what "re-bump immediately" exists to prevent.

**Never merge one line into another.** All three stay linear; move commits with `git cherry-pick`.

Releases are cut as **tags on the line that owns them** — `v2.9` from `v2.x`, `v4.0` from `main`.
Tags mark history and are never branched from, except once when a new maintenance line is cut from a
major's last tag; these three branches are the only ones that persist.

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
   - If it was a maintenance-line fix that also applies forward, **cherry-pick it now** —
     `v2.x` → `v3.x` → `main`, not later. Verify each with `git branch -r --contains <sha>`.
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
CFBundleShortVersionString: "4.6-dev"   # the marketing version — what people see
CFBundleVersion: "406"                  # the build number — what Launch Services orders by
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

- `RELEASE_NOTES.md` — **`main` is the superset; a maintenance line carries only the releases it can
  run.** Write them on the line that owns the release; if that is a maintenance line, cherry-pick
  **forward** to `main`. **Do not send a newer major's sections backward** — `v4.0` and `v4.1` stay
  on `main` alone.

  **The test is whether the section is addressed to that line's reader, not whether the file matches
  byte for byte**, so `cmp` is not the check and a section `main` has that a maintenance line lacks
  is not a finding. A `v4.0` section on `v2.x` would warn that "rules you create in v4.0 cannot be
  read by `v3.x`" — addressed to somebody who cannot run v4, in the notes of somebody who cannot
  leave 2.x. The precedent cuts both ways: `v2.x` carries the full `v3.0` section deliberately,
  because its "**if you are on macOS 15, stay on the 2.x line**" only functions in front of a 2.x
  reader. Baseline (2026-08-17, all correct, none of it drift): `v2.x` and `v3.x` are byte-identical
  and agree with `main` from `## v3.0` down; `main` adds `v4.0`, `v4.1`, four bullets inside
  `## v3.1` (retroactively, `27fa9c14`), and whatever release is currently in draft.
- `docs/releases.html` — **`main` only.** GitHub Pages serves `docs/` from `main`, so a section
  landed solely on `v2.x` publishes nothing. Add the new article ahead of the last one.

  **The badge flips at the cut, not when the notes are written** — the whole reason the draft styles
  exist. Pages is live the moment the notes land, so an article carrying `latest` announces a release
  nobody can install. Notes are normally drafted well before the tag, so a draft lands as
  `<article class="rel draft">` with `<span class="tag draft">In development</span>`, the previous
  release **keeps** `latest`, and the footer reads `Changes so far: <tag>...main`, because the
  compare link cannot name a tag that does not exist yet. `RELEASE_NOTES.md` gets the matching
  `## <version> — DRAFT, not released` heading and a blockquote. These flip in step 1 of
  **Cutting it**. v4.2 shipped its notes with `latest` already on them and had to be corrected on a
  live site; `586333f8` is the v4.1 cut that did it right.

  **Do not treat that as a checklist of everything to flip — a draft says "not released" in prose
  too, and prose has no markup to enumerate.** This used to read "all four flip together", and the
  v4.3 draft carried two more that the four could not name: an HTML comment reading
  `<!-- v4.3 — DRAFT, not released. Keep the Latest badge on v4.2 … -->` where every other article
  carries a plain `<!-- vX.Y -->`, and a `<b>Not released yet</b> — this is what is on main today`
  clause opening the `<p class="lede">`, which is the **first sentence a reader sees**. Both survived
  a flip that moved every one of the four correctly. Neither was reachable from a markup checklist,
  because neither existed when it was written — and the next draft will invent its own. So after
  flipping, **grep both files for the words rather than the markup**, and account for every hit:

  ```sh
  grep -in 'draft\|not released\|still to come\|changes so far\|in development' \
       RELEASE_NOTES.md docs/releases.html
  ```

  It does not come back empty, so read it rather than counting it: at the v4.3 cut the surviving
  hits were the three `.rel.draft` CSS rules and two v4.1 bullets using "draft" about a *person
  name*. A hit inside the release being cut is the finding; everything else must be named.

  **A "Still to come in <version>" section cannot survive the cut it was written ahead of.** What is
  still missing at the tag is a limitation of the release, not a promise inside it: rename the
  heading to `### Known limitations` in `RELEASE_NOTES.md` and reword the HTML `<p class="known">`
  from "Still to come in vX.Y." to "**Not in vX.Y.**" — the shape `v4.1` already uses for the folder
  profile it shipped with nothing able to reach it.

**Then audit every claim against the previous tag before publishing** — one command per claim, did
the thing this describes exist at the last tag?

```sh
git grep -l "<symbol>" v2.8 -- Modules SyncCloudCLI MacApp | grep "/Sources/"
```

- **Audit the section before its bullets.** When a feature arrives inside the range, every "used to /
  was doing / had been" clause describes that feature's own construction — there is no prior
  behaviour for it to be better than. Five of eleven v4.1 tab bullets carried one; all five went, and
  the section read as a feature plus fixes but was a feature. Delete every "used to" in one pass.
- **Cut the self-inflicted.** Five of v2.9's eighteen entries were introduced *and* fixed inside the
  range, so no user of the previous release was ever exposed. Shipping those counts work that reached
  nobody.
- **A commit whose subject is about coverage is not a user-facing fix.** One v2.9 entry credited a
  behaviour the previous release already had; the commit behind it had added a *test*.
- **A new file does not mean a new bug — check the behaviour, not the file's age.** Two v2.9 claims
  survived a challenge for this reason: a `git blame` proxy flagged them because the surrounding code
  was *refactored* in-range, but the behaviour predated it. That direction matters as much.
- **A number that lives in prose rather than in test output has not been checked.** Both figures in
  v4.1's pane-bullet were wrong — "Birth Certificate needs 95.7pt" was measured in the wrong *face*
  (the row draws SF Rounded; the real figure is 92.9), and the 77.6/154pt pair was ~13pt out in both
  halves. Treat a number you cannot reproduce as a finding, not a rounding difference: chasing 95.7
  is what turned up `ScaledFont.nsFont(scale:)` silently dropping `.rounded`, fixed in `97154a32`.
- **A sentence about how the code is *structured* needs the same grep as one about what it does.**
  Two v4.1 claims asserted the opposite of the code, from intent: that ⌘T's menu item says "here" (it
  is `Button("New Tab")`, under a comment explaining why it deliberately does not), and that a mirror
  test is "shared as one expression" (it is written twice). Publishing that a drift hazard is
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
3. **Commit, land on the line, and let CI go green for that SHA.** Then **check that the folder
   survey's ground truth actually ran**, which a green run does not tell you:
   `FolderSurveyGroundTruthTests` is the only suite comparing the survey rules to a real tree, and it
   is gated on a live profile and an awake display, so it is routinely absent from a green package
   run. `FolderSurveyGroundTruthGateTests` always runs and prints the verdict:

   ```sh
   gh run view <run-id> --log | grep '\[ground-truth\]'   # want: RAN — …
   ```

   A `SKIPPED` line names which gate closed it. Not a reason to hold the cut on its own, but a reason
   not to believe the rules were checked against reality in it.
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
