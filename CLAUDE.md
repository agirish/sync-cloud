# SyncCloud — working agreement

## Two release lines: `main` is v3, `v2.x` is maintenance

As of 2026-08-01 there are **two long-lived branches**, and they are the only two:

| Branch | Carries | Breaking changes |
|---|---|---|
| `main` | the **v3 line** — where the next major is built | **allowed** |
| `v2.x` | maintenance for the shipped **2.x series** (cut at `v2.8`) | **never** |

**Decide where work goes before starting it:**

- **Anything that breaks behaviour, removes a feature, or restructures** → `main` only. That is
  what the v3 line is for; do not put it on `v2.x`.
- **A bug fix that matters to someone running 2.8** → land it on **`v2.x` first**, then cherry-pick
  it onto `main`. Fixing on `main` and intending to backport later is how a fix gets lost.
- **Everything else** (new non-breaking work, docs, tooling) → `main`.

**Never merge one line into the other.** Both stay linear; move individual commits with
`git cherry-pick`. A merge commit between the lines defeats the split.

Releases are cut as **tags on the line that owns them** — `v2.9` from `v2.x`, `v3.0` from `main`.
Tags mark history and are never branched from; these two branches are the only ones that persist.

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
   for v3 work, `origin/v2.x` for a 2.x fix):
   ```sh
   git -C /Users/abhishek/Projects/SyncCloud fetch origin
   git worktree add /Users/abhishek/Projects/SyncCloud-<task> -b <task> origin/<line>
   ```
   This is an **xcodegen** project — run `xcodegen` in the new worktree before `xcodebuild`.

2. **Work** — make and test all changes inside that worktree. Uncommitted changes stay isolated
   there; nothing leaks into either line or into a concurrent session until you deliberately commit.

3. **Finish — land on the target line directly.** Only once the work is complete and ready:
   - Commit on the worktree branch (imperative subject; prose body explaining *why*; trailer
     `Co-Authored-By: <model> <noreply@anthropic.com>`).
   - Rebase the branch onto the latest `origin/<line>` if the line moved.
   - Fast-forward the primary checkout to the branch (keep history linear — **no merge commits**).
     The primary checkout tracks `main`; to land on `v2.x`, push the branch straight to it:
     ```sh
     git push origin <task>:v2.x        # v2.x
     git -C /Users/abhishek/Projects/SyncCloud merge --ff-only <task> && git push   # main
     ```
   - If the change was a 2.x fix that also applies to v3, **cherry-pick it onto `main` now** —
     not later.
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
# main's values; v2.x carries "2.10-dev" / "210"
CFBundleShortVersionString: "3.0-dev"   # the marketing version — what people see
CFBundleVersion: "300"                  # the build number — what Launch Services orders by
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
version it is heading toward, suffixed `-dev`: `main` (the v3 line) sits at `3.0-dev`, `v2.x`
sits at `2.10-dev`. The suffix says "this build is no release" without implying a distributed beta
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
naive string comparison (`"2.10"` vs `"2.9"` does not), it increases across both release lines at
once so a v3 build always outranks a v2.x one, and it is derived from the marketing version
rather than being a second thing to remember. It changes in the same edit as the marker; the
`-dev` build and the release it becomes share a number, which is fine because it identifies the
version rather than the individual build. **Keep MINOR under 100** or it stops being monotonic.

### Cutting it

Releases are cut as tags on the line that owns them — `v2.9` from `v2.x`, `v3.0` from `main`.
Tag names are **two components**: `v2.9`, never `v2.9.0` (all 35 existing tags are `vMAJOR.MINOR`).
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
   `210`; after `v3.0`, `main` becomes `3.1-dev` / `301`. Same edit shape as step 1 plus
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
