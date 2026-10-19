# SyncCloud — committing and pushing

How a change gets from a worktree onto `main`. [`CLAUDE.md`](CLAUDE.md) imports this file, so every
session loads it at launch. A bare § number here means this file's section; `CLAUDE.md` §n means
that file's.

The goal is a **linear `main`** where each finished change lands as the fewest commits a reader can
follow — usually **one** — with no long-lived feature branches, no PRs and no merge commits.

**In-progress work never shares a working tree with another session.** On 2026-07-13 several sessions
edited the shared checkout at once and their uncommitted changes got entangled. The primary checkout
`/Users/abhishek/Projects/SyncCloud` is the landing zone, not scratch space: never edit it except to
fast-forward `main` in §5.

**Push to `main` automatically — no ask.** Standing direction since 2026-10-18, replacing the
2026-08-30 "everything stays local until he says push" rule; do not re-derive that rule from older
notes or memory. When a change is finished and passes the gates (§4), rebase, squash, land and push in
one go — then report what landed, with SHAs, and keep going (`CLAUDE.md` §3). What still needs an ask
is listed in `CLAUDE.md` §4.

---

## 1. Start

A worktree on a fresh branch off `origin/main` (a worktree the app made for the session is fine too):

```sh
git -C /Users/abhishek/Projects/SyncCloud fetch origin
git worktree add /Users/abhishek/Projects/SyncCloud-<task> -b <task> origin/main
```

This is an **xcodegen** project: run `xcodegen` in the new worktree before `xcodebuild`.

## 2. Work

All changes stay inside the worktree. Commit as often as is useful — these commits are your working
record, not the shipped history, so a commit per experiment is fine and reverting one is cheap. Small,
single-purpose commits also make a multi-theme squash possible later. **Before any mutation testing,
commit a checkpoint** (§7).

## 3. Rebase and squash

Rebase first, always, then build the shipped commit(s) on a fresh branch. **Squash by replaying, not by
rewriting**: no ref moves, nothing is discarded, and `<task>` survives as both the fallback and the
thing you diff against.

```sh
git fetch origin && git rebase origin/main
git checkout -b <task>-themed origin/main
```

**One commit — the default.** The whole delta staged at once, deletions and renames included:

```sh
git merge --squash <task>
git commit -F <message-file>    # no editor here, so write the message to a file
```

**More than one — only when a second commit earns its place**: a refactor worth reading on its own
before the behaviour change it enabled, or docs that stand apart from the code. Never one commit per
file, never a stack of `WIP`. "Prefer one" is a default, not a hard rule — two well-drawn themes
beat one commit nobody can review. Group the working commits by theme:

```sh
git cherry-pick -n <sha> <sha> && git commit -F <message-file>   # repeat per theme
```

`cherry-pick` replays each *change*, not a file's end state, so two themes may share a file, and a
change `main` made under you **conflicts loudly** instead of vanishing. It only works where theme
boundaries fall on commit boundaries.

**Never build a theme with `git checkout <task> -- <paths>`.** Measured 2026-09-09, it loses work three
ways, silently: it takes the file's *final* content, so a later theme bleeds into an earlier commit;
it *reverts* any change `main` made to that file, with no conflict; and a path the branch *deleted* is
left in place, with only `error: pathspec ... did not match` to show for it.
`git diff | git apply --index` fixes only the third.

**Message shape:** imperative subject under ~65 characters; a short prose body explaining *why*; the
trailer `Co-Authored-By: <model> <noreply@anthropic.com>`. For a refactor, state the
behaviour-preservation proof in the body (`CLAUDE.md` §5).

## 4. The gates

All of these must hold before anything lands:

1. **The rebuild kept everything — this must print nothing:**
   ```sh
   git diff <task> <task>-themed
   ```
   It catches a dropped file, a lost deletion and a bled theme at once — run it before you read
   anything else. It says nothing about whether
   each commit builds on its own — build at each one if that matters.
2. **No empty commits** — this prints nothing when clean and names the offender when not:
   ```sh
   git log --format='%H %s' origin/main..HEAD |
     while read sha rest; do [ -z "$(git show --stat --format= $sha)" ] && echo "EMPTY: $sha $rest"; done
   ```
   Four empty `WIP` commits already sit in `main` (`33c25bd2`, `8456c9d0`, `ea6441bf`, `a6622782`),
   from sessions that landed without looking. Removing them would need a force-push, so they stay.
3. **Tests are green locally** for every package that changed and every package that depends on it.
4. **An app change has been installed and seen running** (`CLAUDE.md` §6).
5. **Any `docs/backports.md` row is inside the squash**, never a follow-up commit (`CLAUDE.md` §1).
6. **You have read what is about to land** — `git log --oneline origin/main..HEAD` and
   `git diff --stat origin/main..HEAD`. A mistake caught now costs nothing; on `main` it costs a new
   commit.

## 5. Land and push

Fast-forward the primary checkout and push — as its own command, run against the primary:

```sh
git -C /Users/abhishek/Projects/SyncCloud merge --ff-only <task>-themed && git push
```

Read back `git rev-parse --short origin/main` to confirm. The **themed** branch is what lands; `<task>`
is the working record and never ships. Finally remove the worktree:
`git worktree remove /Users/abhishek/Projects/SyncCloud-<task>`.

**Cite SHAs only after the push.** The rebase and the squash renumber everything, so a SHA read
earlier names a commit that no longer exists.

---

## 6. Never force-push — and work so that one is never needed

Standing direction, restated 2026-10-18. Every flavour counts: `--force`, `--force-with-lease`, a `+`
refspec, deleting a remote branch and pushing it again. `git reset` is banned too, in every flavour,
`--soft` included (2026-09-09). The flow above is built so neither is ever needed — keep it that way
consciously:

- **Only `main` is ever pushed, and only by fast-forward.** `<task>` and `<task>-themed` never leave
  this machine, so rebasing or rebuilding them rewrites nothing anyone else has.
- **Rebase on `origin/main` right before every squash**, and again if `main` moved before you land.
- **If `--ff-only` refuses or the push is rejected, another session landed first.** Fetch, go back to
  §3, re-squash, re-run the gates, retry.
- **A commit that is wrong once it is on `main` gets fixed by a new commit** — a fix-forward or a
  `git revert` — never by rewriting `main`.

If a force-push ever seems truly needed — a secret committed to `main` is the only plausible case —
**stop and ask him first, and say why**: what happened, why a new commit cannot fix it, exactly what
the force would overwrite, and what else was tried. The standing push approval does not cover it.

## 7. Never discard uncommitted work

`git checkout -- <file>` and `git restore <file>` do not undo *your last edit*: they throw the file
back to `HEAD` and take **every uncommitted change in it** with them, silently, with no reflog entry
to recover from. So do `git clean -fd`, `git stash drop` and `git reset --hard` (banned anyway, §6).

**It happened twice on 2026-08-30, in one session**, during mutation testing — where it bites, because
reverting the mutation is the point of the step and the same file holds the fix under test. The second
time it wiped a new view's whole API — a property, two parameters and the branch that used them —
and the build then failed in a *different* file with `generic parameter 'R' could not be inferred`
and a stray mention of `TableColumn`, because SwiftUI's `Group` fell back to another overload once
its content stopped type-checking. The error named neither the deleted code nor its file.

**So commit a checkpoint before mutating anything.** Worktree commits are free and the squash removes
them:

```sh
git add -A && git commit -qm "checkpoint before mutation testing"
# ...mutate, run the test, watch it fail...
git checkout -- <file>     # now restores to the checkpoint, which is what was meant
git status --short         # MUST still list the file as modified when work was expected
```

The last line is the point: a clean `git status` where you expected modifications means the restore
just took your work. **No command that discards working-tree state may run while uncommitted work
exists in its path** — commit first, or `git stash push -- <file>` and pop it back, or copy the file
aside and back. Never `checkout --` on faith.
