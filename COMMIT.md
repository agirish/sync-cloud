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

Run `xcodegen` in the new worktree before `xcodebuild`.

## 2. Work

Keep all changes in the worktree. Commit as often as useful; these commits do not ship. Small,
single-purpose commits make a multi-theme squash possible. Commit a checkpoint before mutation
testing (§7).

## 3. Rebase and squash

Rebase, then rebuild the shipped commit(s) on a fresh branch:

```sh
git fetch origin && git rebase origin/main
git checkout -b <task>-themed origin/main
```

**One commit** (the default):

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
3. **Tests are green locally** for every changed package and every package that depends on it.
4. **An app change is installed and seen running** (`CLAUDE.md` §6).
5. **Any `docs/backports.md` row is inside the squash** (`CLAUDE.md` §1).
6. **You have read what will land:** `git log --oneline origin/main..HEAD` and
   `git diff --stat origin/main..HEAD`.

## 5. Land and push

As its own command, against the primary checkout:

```sh
git -C /Users/abhishek/Projects/SyncCloud merge --ff-only <task>-themed && git push
```

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
