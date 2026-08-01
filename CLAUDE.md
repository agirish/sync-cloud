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
