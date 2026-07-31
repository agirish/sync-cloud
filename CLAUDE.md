# SyncCloud — working agreement

## Session isolation: work in a worktree, land on `main` directly

The goal is a **linear `main`** where every completed change lands directly — no long-lived
feature branches, no PRs. But **in-progress (uncommitted) work must never share a working tree
with another session.** On 2026-07-13 several sessions edited the shared `main` checkout at the
same time and their uncommitted changes got entangled ("commit-everything-together"). This rule
exists to prevent that.

**Every session works in its own git worktree.** Do not edit files directly in the primary
checkout at `/Users/abhishek/Projects/SyncCloud` while work is in progress — that checkout is the
shared landing zone, not a scratch space.

1. **Start** — create a worktree on a fresh branch off the latest `main`:
   ```sh
   git -C /Users/abhishek/Projects/SyncCloud fetch origin
   git worktree add /Users/abhishek/Projects/SyncCloud-<task> -b <task> origin/main
   ```
   This is an **xcodegen** project — run `xcodegen` in the new worktree before `xcodebuild`.

2. **Work** — make and test all changes inside that worktree. Uncommitted changes stay isolated
   there; nothing leaks into `main` or into a concurrent session until you deliberately commit.

3. **Finish — land on `main` directly.** Only once the work is complete and ready to commit:
   - Commit on the worktree branch (imperative subject; prose body explaining *why*; trailer
     `Co-Authored-By: <model> <noreply@anthropic.com>`).
   - Rebase the branch onto the latest `origin/main` if `main` moved.
   - Fast-forward the primary checkout to the branch (keep history linear — **no merge commits**):
     `git -C /Users/abhishek/Projects/SyncCloud merge --ff-only <task>`
   - `git push`.
   - Remove the worktree: `git worktree remove /Users/abhishek/Projects/SyncCloud-<task>`.

Net effect: everything lands on `main` directly (commit → push → rebase), exactly as before — but
no session's half-finished edits can collide with another's before that commit happens.

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
