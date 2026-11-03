# SyncCloud — committing and pushing

Imported by [`CLAUDE.md`](CLAUDE.md), so every session loads it. A bare § number means this file's
section; `CLAUDE.md` §n means that file's.

`main` is linear: each finished change lands as the fewest commits a reader can follow — usually
one. No PRs, no merge commits, no long-lived feature branches. Never share a working tree with
another session.

---

## 1. Start

A worktree on a fresh branch off `origin/main` (a worktree the app made for the session also works):

```sh
git -C /Users/abhishek/Projects/SyncCloud fetch origin
git worktree add /Users/abhishek/Projects/SyncCloud-<task> -b <task> origin/main
```

Run `xcodegen` in the new worktree before `xcodebuild`. Run every `xcodebuild`, `swift build` and
`swift test` through `scripts/build-slot` (`CLAUDE.md` §7).

## 2. Work

Keep all changes in the worktree. Commit as often as useful; these commits do not ship. Small,
single-purpose commits make a multi-theme squash possible. Commit a checkpoint before mutation
testing (§7). An empty `WIP` commit at the start keeps a cleanup sweep from deleting a branch with
no commits of its own; it is scaffolding, and §3 leaves it behind.

## 3. Rebase and squash

Rebase, then rebuild the shipped commit(s) on a fresh branch:

```sh
git fetch origin && git rebase origin/main
git checkout -b <task>-themed origin/main
```

**One commit** (the default) — and always a squash, even when `<task>` holds one real commit:
`<task>` also holds its WIP and checkpoints, and landing it lands them.

```sh
git merge --squash <task>
git commit -F <message-file>
```

**More than one** — only when a second commit clearly earns its place, such as a refactor worth
reading before the change it enabled, or docs that stand apart from the code. Never one commit per
file, never a stack of `WIP`. Group the working commits by theme:

```sh
git cherry-pick -n <sha> <sha> && git commit -F <message-file>   # repeat per theme
```

This works only where theme boundaries fall on commit boundaries.

**Never build a theme with `git checkout <task> -- <paths>`.** It takes each file's final content,
silently reverts changes `main` made to those files, and leaves files the branch deleted in place.
`git diff | git apply --index` does not fix this.

**Message:** imperative subject under ~65 characters; a short body explaining why; the trailer
`Co-Authored-By: <model> <noreply@anthropic.com>`. For a refactor, state the behaviour-preservation
proof (`CLAUDE.md` §5).

## 4. The gates

All must hold before landing:

1. **The rebuild kept everything** — this prints nothing (run it first):
   ```sh
   git diff <task> <task>-themed
   ```
   It does not check that each commit builds on its own; build each one if that matters.
2. **No empty commits** — this prints nothing:
   ```sh
   git log --format='%H %s' origin/main..HEAD |
     while read sha rest; do [ -z "$(git show --stat --format= $sha)" ] && echo "EMPTY: $sha $rest"; done
   ```
3. **Tests are green locally** for every changed package and every package that depends on it,
   each run through `scripts/build-slot`. Run FileExplorer as `scripts/test-shards
   Modules/FileExplorer`, which takes its own slot and about half the time. A shared gate that
   passed on the very tree you land counts (§8).
4. **An app change is installed and seen running** (`CLAUDE.md` §6).
5. **Any `docs/backports.md` row is inside the squash** (`CLAUDE.md` §1).
6. **You have read what will land:** `git log --oneline origin/main..HEAD` and
   `git diff --stat origin/main..HEAD`.

## 5. Land and push

As its own command, against the primary checkout:

```sh
git -C /Users/abhishek/Projects/SyncCloud push origin <task>-themed:main &&
  git -C /Users/abhishek/Projects/SyncCloud merge --ff-only <task>-themed
```

- Land `<task>-themed`, never `<task>`. Push first: a refused push then leaves `main` untouched
  both here and on `origin`.
- The push runs `scripts/pre-push-guard` as git's pre-push hook. It refuses an empty commit, a merge
  commit, or a subject starting `WIP`, `checkpoint`, `fixup!`, `squash!` or `amend!`, bound for
  `main` or a maintenance line. If it refuses, build `<task>-themed` again (§3) and retry. Never
  `--no-verify`. A new clone installs it once: `scripts/pre-push-guard --install`.
- Confirm with `git rev-parse --short origin/main`, then report what landed, with SHAs.
- If `--ff-only` refuses or the push is rejected, fetch, return to §3, re-squash, re-run the gates,
  and retry.
- `<task>` is the working record and never ships. Remove the worktree: `git worktree remove /Users/abhishek/Projects/SyncCloud-<task>`.
- Cite SHAs only after the push; the rebase and squash renumber commits.

---

## 6. Never force-push

Banned in every form: `--force`, `--force-with-lease`, a `+` refspec, deleting a remote branch and
pushing it again. `git reset` is banned in every form too, `--soft` included. The workflow keeps both
unnecessary:

- Only `main` is pushed, and only by fast-forward. Working branches never leave this machine.
- Rebase on `origin/main` right before every squash.
- A rejected push means another session landed first: fetch and rebase.
- A wrong commit on `main` is fixed by a new commit — a fix-forward or `git revert` — never by
  rewriting `main`.

If a force-push ever seems truly needed (for example, a secret committed to `main`), **stop and ask
first**, saying what happened, why a new
commit cannot fix it, exactly what it would overwrite, and what else was tried. The standing push
approval does not cover it.

## 7. Never discard uncommitted work

`git checkout -- <file>`, `git restore <file>`, `git clean -fd`, `git stash drop` and
`git reset --hard` destroy uncommitted changes with no reflog to recover from. Never run one while
uncommitted work exists in its path — commit first, `git stash push -- <file>` and pop it back, or
copy the file aside.

For mutation testing, checkpoint first:

```sh
git add -A && git commit -qm "checkpoint before mutation testing"
# ...mutate, run the test, watch it fail...
git checkout -- <file>     # restores to the checkpoint
git status --short         # must still list the file as modified when work was expected
```

## 8. Share one landing gate

Opt-in. When two sessions are about to run their gates and one gate already covers the other's,
run it once, on a tree carrying both changes. Each session still squashes, lands and reports its
own commit, with its own message. Everything in §3–§7 stands.

**Find each other.** Before queueing a gate:

```sh
scripts/gate-board announce   # your worktree, branch, SHA, files, gate, session id
scripts/gate-board list       # everyone's, with a verdict on sharing with each
```

Announce again with `--state running|passed|red` and `--passed <suites>` as your runs go, and
`scripts/gate-board clear` once you land or decline. Reach a session with `SendMessage`, `to` the
`local_…` id `list` shows (`ListAgents` lists who is live). An entry drops itself when its
session's process is gone. `scripts/gate-board --help` has the rest.

**It pays when all of these hold** — `list` checks the first three and says `maybe`:

- the two changes touch no common file;
- one gate covers the other: it runs every package the other does, and `xcodebuild test` if the
  other does (a Design change runs Design, every package above it and the app);
- both are final: squashed to `-themed`, rebased on today's `origin/main`, nothing left to change;
- both land on `main`.

**It does not pay:**

- **when the joining side is further along.** It would wait for the whole covering run; if its own
  remaining runs finish sooner, it runs them. On 2026-11-03, NOW's Dashboard run had passed and
  its FileExplorer run was third in line, so waiting for TE316's run of every package would have
  cost it time. It declined, rightly.
- **when either side is still changing.** A change after the shared run starts voids it for that
  side.
- **on a maintenance line.** Never.

**Always opt-in.** A session may decline with no reason, and nobody waits longer than their own
gate would take. The joining side may drop out at any point (the covering run slips in the queue,
say) and run its own gate, saying so.

**The procedure,** where A's gate covers B's:

1. B sends A its `-themed` SHA. Both are rebased on the same `origin/main` (§3).
2. A builds a scratch branch carrying both (worktrees share refs, so B's branch is visible), then
   announces it:
   ```sh
   git checkout -b <A-task>-gate <A-task>-themed && git cherry-pick <B-sha>
   scripts/gate-board announce --join <B's worktree>
   ```
3. A runs its gate there, once. On green, `scripts/gate-board announce --state passed` records the
   tested tree (`git rev-parse HEAD^{tree}`); A tells B it passed, with that tree SHA.
4. A lands `<A-task>-themed` (§5), never `-gate`, which carries B's commit: nobody lands another
   session's commit for it. Then `git branch -D <A-task>-gate`; it is scaffolding.
5. B fetches, rebases `<B-task>-themed` on the new `origin/main`, and checks its stacked tree is
   byte-identical to the tested one:
   ```sh
   scripts/gate-board verify <A's worktree>   # or: git diff --quiet <tested-tree> HEAD^{tree}
   ```
   Identical, and B's gate 3 holds: B lands. Any difference (another session landed in between,
   or B changed) and B reruns its own gate.
6. Both `clear`.

A's commit lands without B's for a while, and that tree was never tested alone. Hosted CI tests
every commit pushed to `main` (`docs/ci.md`), and with no common files a change that needs the
other's to pass is rare; a red there is A's to fix forward.

**A red result.** Neither lands. Read [`docs/flaky-tests.md`](docs/flaky-tests.md) first. Then
each reruns the red suites, narrowed (`--filter`, `-only-testing:`), on its own `-themed` tree.
Whichever reproduces it owns it; if neither does, the two changes interact. Either way they split
and each runs its own gate.

**Installs (gate 4).** One install can serve both: A installs the `-gate` build
(`install-sync-cloud` from A's worktree), so the app running is the tested tree. Each session
still checks its own change by hand in it, and tells the other when done; neither installs over
it until both are. If B's `verify` fails, B installs and checks its own tree again.
