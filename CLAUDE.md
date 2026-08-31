# SyncCloud — working agreement

## Four release lines: `main` is v5, `v4.x`, `v3.x` and `v2.x` are maintenance

Four long-lived branches, and only four. Every shipped major keeps a maintenance line, cut from
that major's last tag when the next major opens on `main`:

| Branch | Carries | Marker at tip | Breaking changes |
|---|---|---|---|
| `main` | the **v5 line** — where the next release is built | `5.1-dev` / `501` | **allowed** |
| `v4.x` | maintenance for the shipped **4.x series** (cut at `v4.6`, 2026-08-28) | `4.7-dev` / `407` | **never** |
| `v3.x` | maintenance for the shipped **3.x series** (cut at `v3.1`, 2026-08-11) | `3.2-dev` / `302` | **never** |
| `v2.x` | maintenance for the shipped **2.x series** (cut at `v2.8`, 2026-08-01) | `2.10-dev` / `210` | **never** |

**Land on `main`. No backporting — standing direction, given 2026-08-26 without a scope limit
(`e2b35dad`), and it governs new work generally rather than one batch.** This replaced an
oldest-line-first rule; do not re-derive that rule from the shape of the table, and do not re-raise
the question per batch.

**Record the gap anyway, in [`docs/backports.md`](docs/backports.md).** Those rows are now a
*record* of what `main` carries that `v4.x`, `v3.x` and `v2.x` do not — what a future audit needs if
the direction ever changes — not a to-do list. Write down both directions: "checked and not owed"
saves the next audit as much time as "owed", and the per-file pick notes are the expensive half to
reconstruct. The file is carried on all four lines, so a maintainer on a maintenance line can read
it without going through `main`. Largest known gap: **`v3.x` has none of the `DeleteOutcome`
family**, so it cannot tell a trashed item from a permanently deleted one and offers ⌘Z for removals
it cannot take back.

**If a maintenance line is ever cut again, add its row here and to `branches:` in
`.github/workflows/tests.yml` in the same commit that pushes the branch** — and re-bump its tip
marker in that same commit (see **Cutting a release**, step 5).

**Never merge one line into another.** All four stay linear; move commits with `git cherry-pick`.
If a pick is ever authorised again, **verify it landed by CONTENT, not by `git branch -r --contains`**
— a cherry-pick has a new SHA, so `--contains` answers about the wrong commit.

**`origin` carries the four lines and nothing else — and that is a thing to CHECK, not assume.**
A stray `roots` branch sat there unnoticed until 2026-08-27 because nothing here ever looked. One
command, and it prints exactly four lines when the remote is clean:

```sh
git ls-remote --heads origin | awk '{print $2}'   # expect refs/heads/{main,v2.x,v3.x,v4.x}, nothing else
```

A fifth is scaffolding and can go — but **deleting a remote branch is outward-facing, so establish
that nothing unique dies first and ask before pushing the delete.** Two checks settle it:
`git diff --name-status main <branch> | grep '^A'` must print nothing (it adds no file `main`
lacks), and a local branch at the same SHA means the commits outlive the remote ref.

Releases are cut as **tags on the line that owns them** — `v2.9` from `v2.x`, `v5.0` from `main`.
Tags mark history and are never branched from, except once when a new maintenance line is cut from a
major's last tag; these four branches are the only ones that persist.

**One branch is a deliberate exception, written here so nobody tidies it away:
`candidate-tap-deferral` (`dba29645`).** It parks a single unlanded 2026-08-04 commit — a tap-gesture
deferral that was built, installed, clicked and **falsified** — which
[`docs/columns-layout-loop.md`](docs/columns-layout-loop.md) cites by name and SHA, with the numbers,
so the result stays reproducible instead of becoming folklore. **Delete the branch and the doc cites
a SHA git will eventually collect.** A tag would be tidier, but the tag namespace is release-only
(`git tag | grep -v '^v[0-9]*\.[0-9]*$'` must stay empty). Any other branch you find is scaffolding
and can go.

## Session isolation: work in a worktree, land only when he says so

The goal is a **linear `main`** where every completed change lands as a small number of thematic
commits — no long-lived feature branches, no PRs, no merge commits. But **in-progress work must
never share a working tree with another session**: on 2026-07-13 several sessions edited the shared
`main` checkout at once and their uncommitted changes got entangled.
`/Users/abhishek/Projects/SyncCloud` is the shared landing zone, not a scratch space — do not edit
it while work is in progress.

**Everything stays local until he says to push. Standing direction, 2026-08-30.** Commit freely
inside the worktree — those commits are a working record, not the shipped history — but do not
touch the primary checkout, do not `push`, and do not treat "the work is done and the tests are
green" as permission to land. **Ask, in so many words, and wait for an explicit yes.** "Looks
good" about the code is not a push approval; neither is an earlier session's approval, nor his
approval of the *previous* batch. One ask, one push.

1. **Start** — worktree on a fresh branch off `origin/main`:
   ```sh
   git -C /Users/abhishek/Projects/SyncCloud fetch origin
   git worktree add /Users/abhishek/Projects/SyncCloud-<task> -b <task> origin/main
   ```
   This is an **xcodegen** project — run `xcodegen` in the new worktree before `xcodebuild`.

2. **Work** — all changes inside that worktree. Commit as often as is useful; the granularity here
   is for you, not for `main`, so a commit per experiment is fine and reverting one is cheap.
   Nothing leaves the worktree at this stage.

3. **Squash into thematic commits — before you ask, not after he says yes.** The branch's shipped
   shape is a handful of commits, each one theme a reader could review on its own: a behaviour
   change and its tests together, a refactor separate from the behaviour change it enabled, docs
   separate from code. Not one commit per file, and not one commit for the whole session.
   Interactive rebase is unavailable here, so squash by replaying onto the line and re-committing
   in themed chunks, or with `git reset --soft` to the merge base and staging path by path:
   ```sh
   git fetch origin && git rebase origin/main            # rebase first, squash onto the real base
   git reset --soft $(git merge-base origin/main HEAD)   # all work now staged, nothing lost
   git restore --staged . && git add <paths for theme 1> && git commit   # repeat per theme
   ```
   `git reset --soft` **stages against the ref as it is now** — if the line moved under you, it
   clobbers; rebase first, and check `git status` shows exactly the files you expect before the
   first commit.
   - Message shape: imperative subject; prose body explaining *why*; trailer
     `Co-Authored-By: <model> <noreply@anthropic.com>`.
   - **Empty commits do not survive the squash, but check anyway** — this prints nothing when the
     branch is clean and names the offender when it is not:
     ```sh
     git log --oneline --format='%H %s' origin/main..HEAD |
       while read sha rest; do [ -z "$(git show --stat --format= $sha)" ] && echo "EMPTY: $sha $rest"; done
     ```
     Four empty `WIP` commits sit in `main`'s history (`33c25bd2`, `8456c9d0`, `ea6441bf`,
     `a6622782`) from sessions that landed the whole branch without looking. Removing one after it
     lands needs a force-push, which is why they are staying.
   - Then show him what you are proposing to land — `git log --oneline origin/main..HEAD` and
     `git diff --stat origin/main..HEAD` — and ask.

4. **Land, once he has said yes.** Fast-forward the primary checkout; **no merge commits**:
   ```sh
   git -C /Users/abhishek/Projects/SyncCloud merge --ff-only <task> && git push
   ```
   Then record any maintenance-line gap in `docs/backports.md` — a record, not a to-do; see the
   standing direction above. Finally `git worktree remove /Users/abhishek/Projects/SyncCloud-<task>`.

**Cite SHAs only after the push.** The squash and the rebase both renumber everything, so a SHA
read before step 4 names a commit that no longer exists.

## Cutting a release

**The version bump is part of the release, not a follow-up.** Between `v0.10` and `v2.8` the version
in `project.yml` never moved, so all twenty-odd tagged releases installed an app reporting itself as
**1.0 (build 1)** — in the Settings rail, in `~/sync-cloud.log`, and in Finder's Version column.
Nothing failed, because nothing *depends* on the version — the two things that read it only display
it; it was simply wrong for two years.

### Where the version lives

`project.yml` is the only source of truth. Each line's current values are in the branch table at the
top of this file — this block shows the shape, not any line's numbers, so that it cannot drift:

```yaml
CFBundleShortVersionString: "<MAJOR>.<MINOR>-dev"   # the marketing version — what people see
CFBundleVersion: "<MAJOR × 100 + MINOR>"            # the build number — what Launch Services orders by
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
- the branch table at the top of this file — the only place CLAUDE.md spells a live number
- `MacApp/Info.plist`, which xcodegen regenerates

The table is the one that gets missed — the v4.2 re-bump moved `project.yml` and the test literal but
left all three lines' tables reading `4.1-dev` / `401`, and the table is what a session consults
*before* a cut. This prints nothing when the table is right, and names the offender when it is not:

```sh
# main's row is read from the WORKING TREE — that is the copy you are about to land, and during a
# cut it is the only one that is right. The maintenance rows come from origin, the only place they
# exist. Reading origin on BOTH sides reports "clean" all through a local bump, which is useless.
for l in main v4.x v3.x v2.x; do
  if [ "$l" = main ]; then m=$(grep -o '"[0-9.]*-dev"' project.yml | tr -d '"')
  else m=$(git show origin/$l:project.yml | grep -o '"[0-9.]*-dev"' | tr -d '"'); fi
  r=$(grep "^| \`$l\`" CLAUDE.md | grep -o '`[0-9.]*-dev`' | tr -d '`')
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
identifies the version, not the build. **Keep MINOR under 100** or it stops being monotonic — and
**MAJOR under 100** too, for a different reason: past that the rail's version line wraps (see **The
version line has a width budget**). Both halves of the scheme are bounded.

### Writing the notes

**The notes are part of the release too** — v2.9 reached the point of being tagged with none,
because nothing said to write them. They live in two places: `RELEASE_NOTES.md` (`main` is the
superset) and `docs/releases.html` (**`main` only** — Pages serves `docs/` from `main`).

**The badge flips at the cut, not when the notes are written.** Pages goes live the moment the notes
land, so an article carrying `latest` announces a release nobody can install. A draft lands as
`<article class="rel draft">`, the previous release **keeps** `latest`, and `RELEASE_NOTES.md` gets
`## <version> — DRAFT, not released`. `586333f8` is the v4.1 cut that did it right.

**Then audit every claim in them against the previous tag — one command per claim.** The audit
rules, each with the release that produced it, are in
**[`docs/release-notes-audit.md`](docs/release-notes-audit.md)**. **Read that file during the cut**
— step 1 of **Cutting it** requires it. Nothing fails when the audit is skipped, which is exactly
why it gets skipped; the notes then ship claims the code does not support.

### Cutting it

Tags are **two components** — `v2.9`, never `v2.9.0`; `git tag | grep -v '^v[0-9]*\.[0-9]*$'` should
stay empty. Work in a worktree as always — and the push rule from **Session isolation** applies
here too: build the whole cut locally, then ask once before step 3 puts any of it on `origin`.
Everything after that point is outward-facing and irreversible in public (a pushed tag, a published
release, a live Pages article), so the ask covers the cut as a unit, not each command in turn.

1. **Drop the suffix, and publish the notes with it.** In `project.yml`, `2.9-dev` → `2.9`. Leave
   `CFBundleVersion` alone — it is already `209`. In the same commit take the notes out of draft:
   `RELEASE_NOTES.md`'s DRAFT heading and blockquote go; on `docs/releases.html` the article loses
   `class="rel draft"`, its tag goes `draft`/"In development" → `latest`, the previous release trades
   `latest` for a theme tag, and the footer goes `Changes so far: <prev>...main` →
   `Full changelog: <prev>...<new>`. Then **work through
   [`docs/release-notes-audit.md`](docs/release-notes-audit.md) before you commit** — it converts the
   "Still to come" section, runs the draft-word grep (the markup list is not the whole set), and
   audits every claim against the previous tag. v4.3's flip got every marker right and still landed
   with two "not released" sentences intact, and because Pages publishes on the push, the live page
   carried a `Latest` badge over a lede reading "Not released yet" until a follow-up caught it.
2. **Regenerate and update the test marker.** Run `xcodegen`, and set `versionMarker` in
   `Modules/Settings/Tests/Settings/SettingsLayoutTests.swift` to the same string — that literal is
   what gives `theVersionLineFitsTheRailOnOneLine` something real to measure (see below).
3. **Commit, land on the line, and let CI go green for that SHA — and STAY OFF THE MACHINE while
   it runs.** The self-hosted runner IS this Mac. The v4.5 cut took three attempts on one SHA:
   attempts 1 and 2 failed while local `swift test` runs were competing with the runner, and
   attempt 3 went green on the same commit, no code changed, with the machine quiet and the load
   average down from 6.61 to 4.20. Both flake families here — *"every gate parks at once, on the
   pool their releases need"* and *"a log assertion reading a window that has already rolled"* in
   [`docs/flaky-tests.md`](docs/flaky-tests.md) — are load-sensitive, so a busy machine
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

**The safe ceiling is 19 characters including the `SyncCloud ` prefix** — measured 2026-08-30, and
tighter than it looks. The column is 142pt; `SyncCloud 10.10-dev` is 19 characters and measures
136pt, but `SyncCloud 100.10-dev` is 20 and measures 145pt, which **wraps**. So the scheme here is
safe only while MAJOR stays below 100 — a two-character marker from trouble, not a comfortable
margin. The per-size table is in the test's doc comment. If a version does get long enough to
matter, `theVersionLineFitsTheRailOnOneLine` fails and names the number; do not widen the rail
without re-measuring the tabs that share its opening.

## Trying an app change

**Install from the worktree, before you ask for the push** — an app change he has not seen running
is not a change he can approve. The skill resolves the current worktree's `.dd` as well as the
shared DerivedData root, so nothing has to land first.

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
regression and re-diagnosing a machine. It is carried on all four lines, but **the numbering is
per-line and the counts differ** — cite a mechanism by its title, never by its number.
