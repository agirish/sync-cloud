# SyncCloud — working agreement

## Three release lines: `main` is v4, `v3.x` and `v2.x` are maintenance

As of 2026-08-16 there are **three long-lived branches**, and they are the only three. Every
shipped major keeps a maintenance line, cut from that major's last tag when the next major opens
on `main`:

| Branch | Carries | Marker at tip | Breaking changes |
|---|---|---|---|
| `main` | the **v4 line** — where the next release is built | `4.1-dev` / `401` | **allowed** |
| `v3.x` | maintenance for the shipped **3.x series** (cut at `v3.1`, 2026-08-11) | `3.2-dev` / `302` | **never** |
| `v2.x` | maintenance for the shipped **2.x series** (cut at `v2.8`, 2026-08-01) | `2.10-dev` / `210` | **never** |

**`v3.x` sat undocumented for eleven days.** It was cut correctly from the `v3.1` tag on 2026-08-11
and then nothing landed on it — this file still said "two lines", so every session backported to
`v2.x` and `main` only, and 52 commits went onto `v2.x` between 2026-08-05 and 2026-08-16 without
anyone asking whether they applied to 3.x too. Its tip also sat on the plain release number `3.1`
for that whole time — exactly what "re-bump immediately" (below) exists to prevent. If a
maintenance line is ever cut again, **add its row here and to `branches:` in
`.github/workflows/tests.yml` in the same commit that pushes the branch** — CI never ran on `v3.x`
either, for the same eleven days, because the workflow named only `main` and `v2.x`.

**Decide where work goes before starting it:**

- **Anything that breaks behaviour, removes a feature, or restructures** → `main` only. That is
  what the current major's line is for; do not put it on a maintenance line.
- **Everything else** → land it on the **oldest line that carries the code**, then cherry-pick it
  forward onto every newer line that also carries it, in the same session. Oldest-first because a
  patch that applies to 2.x code almost always applies to 3.x and `main`; a fix written against
  `main` and intended to be backported later is how a fix gets lost. Three lines means a fix can
  be three landings — that is the cost of keeping the lines, not a reason to skip one.
- **Work on code that exists only on `main`** → `main`, because there is nowhere else for it to go.

**"Applies" means the code is there, not that a user would notice.** This is the bar, and it is
deliberately low: bug fixes, minor features that need no redesign, test-only changes, flake fixes,
docs and tooling all go to every line that carries the file. A narrower reading — "only fixes
that matter to someone running 2.8" — is what this line used to say, and under it landing a shared
test helper's fix on both lines read as a judgement call to argue rather than the default. That is
the failure mode: nothing announces a maintenance line quietly keeping a defect its own CI runs
into.

Two commands settle it before you start, per line, and byte-identical files cherry-pick clean:

```sh
for l in v2.x v3.x; do git ls-tree -r --name-only origin/$l -- <path>; done   # which lines carry it?
diff <(git show origin/main:<f>) <(git show origin/v3.x:<f>)
```

**What each line is OWED is tracked in [`docs/backports.md`](docs/backports.md)** — the confirmed
gaps, the families checked and deliberately *not* owed, and the size of the surface nobody has
audited. It is carried on all three lines, so a maintainer on `v2.x` or `v3.x` can read what that
line is missing without going through `main`'s history. Record a decision there when you settle
one, in either direction: "checked and not owed" saves the next audit as much time as "owed".

**Never merge one line into another.** All three stay linear; move individual commits with
`git cherry-pick`. A merge commit between lines defeats the split.

Releases are cut as **tags on the line that owns them** — `v2.9` from `v2.x`, `v3.1` from `main`
(before `v3.x` was cut), a future `v3.2` from `v3.x`, `v4.0` from `main`. Tags mark history and are
never branched from — except once, when a new maintenance line is cut from a major's last tag;
these three branches are the only ones that persist.

## Session isolation: work in a worktree, land on your target line directly

The goal is a **linear `main`** where every completed change lands directly — no long-lived
feature branches, no PRs. But **in-progress (uncommitted) work must never share a working tree
with another session.** On 2026-07-13 several sessions edited the shared `main` checkout at the
same time and their uncommitted changes got entangled ("commit-everything-together"). This rule
exists to prevent that.

**Every session works in its own git worktree.** Do not edit files directly in the primary
checkout at `/Users/abhishek/Projects/SyncCloud` while work is in progress — that checkout is the
shared landing zone, not a scratch space.

1. **Start** — create a worktree on a fresh branch off the line you are targeting (`origin/main`
   for v4 work, `origin/v3.x` for a 3.x fix, `origin/v2.x` for a 2.x fix):
   ```sh
   git -C /Users/abhishek/Projects/SyncCloud fetch origin
   git worktree add /Users/abhishek/Projects/SyncCloud-<task> -b <task> origin/<line>
   ```
   This is an **xcodegen** project — run `xcodegen` in the new worktree before `xcodebuild`.

2. **Work** — make and test all changes inside that worktree. Uncommitted changes stay isolated
   there; nothing leaks into any line or into a concurrent session until you deliberately commit.

3. **Finish — land on the target line directly.** Only once the work is complete and ready:
   - Commit on the worktree branch (imperative subject; prose body explaining *why*; trailer
     `Co-Authored-By: <model> <noreply@anthropic.com>`).
   - Rebase the branch onto the latest `origin/<line>` if the line moved.
   - Fast-forward the primary checkout to the branch (keep history linear — **no merge commits**).
     The primary checkout tracks `main`; to land on a maintenance line, push the branch straight
     to it:
     ```sh
     git push origin <task>:v2.x        # v2.x (likewise <task>:v3.x)
     git -C /Users/abhishek/Projects/SyncCloud merge --ff-only <task> && git push   # main
     ```
   - If the change was a maintenance-line fix that also applies to the newer lines,
     **cherry-pick it forward now** — `v2.x` → `v3.x` → `main` — not later. Verify each landing
     with `git branch -r --contains <sha>`.
   - Remove the worktree: `git worktree remove /Users/abhishek/Projects/SyncCloud-<task>`.

Net effect: everything lands on its line directly (commit → rebase → push), and no session's
half-finished edits can collide with another's before that commit happens.

Commit and push **proactively** as work lands; don't wait to be asked each time.

## Cutting a release

**The version bump is part of the release, not a follow-up.** Between `v0.10` and `v2.8` the
version in `project.yml` never moved: every one of those twenty-odd tagged releases installed an
app that reported itself as **1.0 (build 1)** — in the Settings rail, in `~/sync-cloud.log`, and
in Finder's Version column. Nothing failed, because nothing reads the version; it was simply
wrong for two years. The steps below exist so that cannot recur.

### Where the version lives

`project.yml` is the only source of truth:

```yaml
# main's values; v3.x carries "3.2-dev" / "302", v2.x carries "2.10-dev" / "210"
CFBundleShortVersionString: "4.1-dev"   # the marketing version — what people see
CFBundleVersion: "401"                  # the build number — what Launch Services orders by
```

`MacApp/Info.plist` is **generated from it by xcodegen and tracked in git**, so it changes in the
same commit — run `xcodegen` after editing `project.yml` and commit both files. A `project.yml`
edit alone leaves the tracked plist stale.

Two things read the version, both display-only — there is no version-keyed migration or compare
anywhere, which is what makes changing it safe:

- the Settings rail — `Modules/Settings/Sources/Settings/SettingsLayout.swift`
- the launch breadcrumb in `~/sync-cloud.log` — `MacApp/SyncCloudApp.swift`

### The two numbers

**Marketing version.** Between releases each branch tip carries a **pre-release marker** for the
version it is heading toward, suffixed `-dev`: `main` sits at `4.1-dev`, `v3.x` at `3.2-dev`,
`v2.x` at `2.10-dev`. The suffix says "this build is no release" without implying a distributed beta
programme. A release drops the suffix, and the tip is re-bumped straight afterwards, so a plain
number like `2.9` is only ever what the tagged commit itself carries.

Non-numeric is deliberate and verified: SyncCloud is distributed directly, not through the App
Store, so `CFBundleShortVersionString` is a free-form display string. Measured on a real Release
build — Launch Services stores `3.0-dev` verbatim and Spotlight's importer emits
`kMDItemVersion = "3.0-dev"` (Finder's Version column). LS does its *ordering* on
`CFBundleVersion`, not on this string. (The App Store's 1–3-integers rule would apply only if
SyncCloud were ever submitted there; that would mean dropping the suffix, nothing more.)

**Build number.** `CFBundleVersion` = **MAJOR × 100 + MINOR** of the marketing version — `2.9` →
`209`, `2.10` → `210`, `3.0` → `300`. One integer, so it orders correctly under both numeric and
naive string comparison (`"2.10"` vs `"2.9"` does not), it increases across all release lines at
once so a v4 build always outranks a v3.x one and a v3.x one a v2.x one, and it is derived from
the marketing version rather than being a second thing to remember. It changes in the same edit
as the marker; the `-dev` build and the release it becomes share a number, which is fine because
it identifies the version rather than the individual build. **Keep MINOR under 100** or it stops
being monotonic.

### Writing the notes, and auditing every claim in them

**The notes are part of the release too.** v2.9 reached the point of being tagged with no notes at
all, because nothing here said to write them; they exist in two places and both are needed:

- `RELEASE_NOTES.md` — **`main` is the superset; a maintenance line carries only the releases it can
  run.** Decided 2026-08-17, replacing an earlier "identical on every line" rule. Write the notes on
  the line that owns the release; if that is a maintenance line, cherry-pick them **forward** to
  `main` so `main` keeps every release. **Do not send a newer major's sections backward** — `v4.0`
  and `v4.1` stay on `main` alone.

  The old rule read as drift to repair and was one cut away from being obeyed. What it would have
  produced is the argument against it: `v2.x` is the line someone runs *because they are on macOS
  15*, and the `v4.0` section it would have gained contains "rules you create in v4.0 cannot be read
  by `v3.x`" — a warning addressed to somebody who cannot run v4, sitting in the notes of somebody
  who cannot leave 2.x. The precedent cuts the other way too and is worth knowing: `v2.x` carries
  the full `v3.0` section deliberately, because its "**if you are on macOS 15, stay on the 2.x
  line**" only functions in front of a 2.x reader. **The test is whether the section is addressed to
  that line's reader, not whether the file matches byte for byte.**

  So `cmp` is no longer the check, and a section `main` has that a maintenance line lacks is not a
  finding. As of 2026-08-17 `v2.x` and `v3.x` are byte-identical to each other and agree with `main`
  from `## v3.0` down; `main` additionally has `v4.0`, `v4.1`, and four bullets inside `## v3.1`
  (`### The window, and what the chrome claims`, added retroactively by `27fa9c14`). All three states
  are correct under this rule and none of them needs repairing.
- `docs/releases.html` — **`main` only.** GitHub Pages serves `docs/` from `main`, so a section
  landed solely on `v2.x` publishes nothing. Add the new article ahead of the last one, move the
  `latest` badge onto it, and give the superseded release the theme tag every other one carries.

**Then audit every claim against the previous tag before publishing.** On v2.9 this killed **six of
eighteen** drafted entries, and it is one command per claim — did the thing this describes exist at
the last tag?

```sh
git grep -l "<symbol>" v2.8 -- Modules SyncCloudCLI MacApp | grep "/Sources/"
```

- **Five were self-inflicted** — introduced *and* fixed inside the same range, so no user of the
  previous release was ever exposed to them. Shipping those as "fixes" counts work that never
  reached anyone.
- **One was simply false.** It credited a behaviour the previous release already had; the commit
  behind it had added a *test*. **A commit whose subject is about coverage is not a user-facing
  fix** — that is the single easiest way to inflate a release.
- **Two survived a challenge**, and that direction matters as much: a `git blame` proxy had flagged
  them because the surrounding code was *refactored* in-range, but the behaviour predated it.
  **A new file does not mean a new bug — check the behaviour, not the file's age.**

Two tells worth knowing. The word **"again"** in a claim ("fits on a small display *again*") usually
means the release broke it in the first place. And a **short list after a large range** is the
honest outcome, not a failure of the notes: say what the work actually bought instead of padding —
v2.9's headline became its test volume, which was the one superlative that survived checking.

**v4.1 added two more, and the first is worth reaching for before the greps.** When a **whole
feature arrives inside the range**, every "used to / was doing / had been" clause in its section is
describing that feature's own construction — there is no prior behaviour for it to be better than,
because it shipped nowhere. Five of eleven tab bullets carried such a clause and all five went; the
section read as a feature *plus* a run of fixes and was a feature. **Ask "did this thing exist at
the tag?" of the section before auditing its bullets**, and delete every "used to" in one pass.

**A number that lives in prose rather than in test output has not been checked.** Both measurements
in the pane-bullet were wrong: "Birth Certificate needs 95.7pt" was measured in the wrong *face*
(the row draws SF Rounded; 95.7 is SF Pro, the real figure is 92.9), and the 77.6/154pt pair was
~13pt out in both halves. Re-derive every number, and treat one you cannot reproduce as a finding
rather than a rounding difference — chasing 95.7 is what turned up `ScaledFont.nsFont(scale:)`
silently dropping `.rounded` and resolving to the default face, fixed on this line in `ee04d018`.

Two claims also asserted the *opposite* of the code: that ⌘T's menu item says "here" (it is
`Button("New Tab")`, under a comment explaining why it deliberately does not) and that a mirror test
is "shared as one expression so a link cannot come to mean one thing for a drill and another for a
tab" (it is written twice). Both were asserted from intent. **A sentence about how the code is
*structured* needs the same grep as a sentence about what it does** — and publishing that a drift
hazard is structurally prevented, when it is prevented only by two copies currently agreeing, is
worse than saying nothing.

### Cutting it

Releases are cut as tags on the line that owns them — `v2.9` from `v2.x`, `v3.2` from `v3.x`,
`v4.1` from `main`. Tag names are **two components**: `v2.9`, never `v2.9.0` (all 35 existing tags are `vMAJOR.MINOR`).
Work in a worktree as always.

1. **Drop the suffix.** In `project.yml`, `2.9-dev` → `2.9`. Leave `CFBundleVersion` alone: it is
   already `209`, because the marker and the release share it.
2. **Regenerate and update the test marker.** Run `xcodegen`, and set `versionMarker` in
   `Modules/Settings/Tests/Settings/SettingsLayoutTests.swift` to the same string — that literal
   is what gives `theVersionLineFitsTheRailOnOneLine` something real to measure (see below).
3. **Commit, land on the line, and let CI go green for that SHA.**
4. **Tag that exact commit and push the tag** — `git tag v2.9 <sha> && git push origin v2.9`.
   Tags mark history and are never branched from. Push the tag **before** creating the GitHub
   release, so the release binds to a tag that already exists rather than to a commitish GitHub
   resolves for itself.

   Then cut the release, and **pass `--target` explicitly — it is the line that owns the release,
   not the default branch**:

   ```sh
   gh release create v2.9 --target v2.x \
     --title "v2.9 — <the lede, shortened>" --notes-file <body> --latest
   ```

   Without `--target`, `gh release create` stores the repo's **default branch** (`main`) as the
   release's `target_commitish` — even when the tag is on `v2.x`. v2.9 shipped that way before it
   was noticed. Nothing public renders it (the release page, the releases index and the tags page
   all show a *commit* chip), but it is wrong in the release's edit view and in every API read, and
   it invites exactly the question "was this cut from main?" about a maintenance release.

   It is fixable after publishing — the API's "unused if the Git tag already exists" caveat governs
   tag *creation*, not the stored value:

   ```sh
   RID=$(gh release view v2.9 --json databaseId --jq .databaseId)
   gh api --method PATCH repos/agirish/sync-cloud/releases/$RID -f target_commitish=v2.x
   ```

   **Re-verify the tag did not move afterwards** — that is the real risk in editing a published
   release. `gh api repos/agirish/sync-cloud/git/refs/tags/v2.9 --jq .object.sha` must be unchanged
   and `git branch -r --contains <sha>` must still name `origin/v2.x` alone.

   Do not "correct" **v2.8**, whose release says `main` and is right: it was tagged 2026-07-31,
   before the `v2.x` split at `0f016480`, so `main` genuinely was its line.
5. **Re-bump the tip to the next marker, immediately.** After `v2.9`, `v2.x` becomes `2.10-dev` /
   `210`; after `v4.0`, `main` becomes `4.1-dev` / `401`. **A freshly cut maintenance line needs the
   same re-bump in its first commit** — `v3.x` was cut from `v3.1` and left on `3.1` / `301` for
   eleven days. Same edit shape as step 1 plus
   `xcodegen`, its own commit. Do this now, not next time — a tip left sitting on a plain release
   number is exactly how the version silently stopped moving before.
6. **Install and confirm what the app reports.** Run the `install-sync-cloud` skill and check the
   first line of `~/sync-cloud.log` names the version you just cut.

### The version line has a width budget

The rail's version line is the one thing a version bump can actually break. `SettingsRail` is
**fixed-width (176pt) and does not scroll**, and the line has no `lineLimit`, so a string too wide
wraps onto a second row rather than clipping — and at the sheet's floor size that extra row takes
the Large text size over its opening, which has only 0.4pt of margin.

`Bundle.main` under `swift test` is the test host and carries **no** version at all, so the line
does not render on its own and every rail test was blind to it. `SettingsRail.versionText` is the
seam that fixes that: the tests inject `versionMarker` and really lay the line out. **Keep that
literal in step with `project.yml`** — that is the whole reason step 2 exists.

Measured room is 142pt against 119pt for `SyncCloud 3.0-dev` at the largest text size — about
three characters spare, comfortable out to roughly a 21-character line (`10.10-dev` still fits).
If a version ever does get long enough to matter, `theVersionLineFitsTheRailOnOneLine` fails and
names the number; do not widen the rail without re-measuring the tabs that share its opening.

## After shipping an app change

Run the `install-sync-cloud` skill (quits the running instance, installs the fresh build to
`/Applications/SyncCloud.app`, de-dupes the DerivedData copy from Spotlight, then sweeps stale
build debris). It launches and verifies the app itself — **by polling `~/sync-cloud.log` for a new
line, not by `pgrep`**: a silent `open` exit is not proof the app started, and neither is a live
pid. The app can come up wedged with zero windows and an empty log, which is exactly what `pgrep`
cannot see.

## Correctness bar

Refactors must be provably behavior-preserving: build the pre-change binary at `HEAD` and diff
stdout / exit codes / resulting file trees against the new binary on a controlled fixture. State
the verification in the commit body. He runs this against real cloud data and audits commits, so
silent behavior changes are costly.
