# SyncCloud — working agreement

How work on SyncCloud gets done. "He" is Abhishek, who owns the project, runs the app against his real
cloud data, and audits every commit. Releasing has its own file, [`RELEASE.md`](RELEASE.md) — read it
before any release cut or version bump.

## At a glance

- **Work in your own worktree.** Never edit the primary checkout `/Users/abhishek/Projects/SyncCloud`
  except to fast-forward `main` when landing.
- **Land on `main` only.** No backporting; record the gap in `docs/backports.md` instead (§1).
- **Push to `main` automatically** once the gates pass — no ask ([`COMMIT.md`](COMMIT.md)). Then
  keep going (§3).
- **Still ask first:** release cuts, deleting a remote branch, pushing to a maintenance line, and
  design calls only he can make (§4).
- **Never force-push** — if one ever seems truly needed, ask and say why. **Never `git reset`, of
  any kind. No merge commits. Never merge one line into another.**
- **Never discard uncommitted work** — commit a checkpoint before anything that restores files
  (`COMMIT.md` §7).
- **Prefer one commit per change**, built by replaying onto a fresh branch (`COMMIT.md` §3).
- **Refactors must be proven behaviour-preserving** (§5).

---

## 1. Branches and release lines

Five long-lived branches, and only five. Each shipped major keeps a maintenance line, cut from that
major's last tag when the next major opens on `main`:

| Branch | Carries | Marker at tip | Breaking changes |
|---|---|---|---|
| `main` | the **v6 line** — where the next release is built | `6.0-dev` / `600` | **allowed** |
| `v5.x` | maintenance for the shipped **5.x series** (cut at `v5.5`, 2026-10-17) | `5.6-dev` / `506` | **never** |
| `v4.x` | maintenance for the shipped **4.x series** (cut at `v4.6`, 2026-08-28) | `4.7-dev` / `407` | **never** |
| `v3.x` | maintenance for the shipped **3.x series** (cut at `v3.1`, 2026-08-11) | `3.2-dev` / `302` | **never** |
| `v2.x` | maintenance for the shipped **2.x series** (cut at `v2.8`, 2026-08-01) | `2.10-dev` / `210` | **never** |

The markers are copies of `project.yml` and must move with it — [`RELEASE.md`](RELEASE.md) §2 has the
check. Cutting a new maintenance line: `RELEASE.md` §5.

### No backporting

**Land on `main`. No backporting** — standing direction since 2026-08-26 (`e2b35dad`), with no scope
limit: it governs all new work, not one batch. It replaced an oldest-line-first rule; do not
re-derive that rule from the shape of the table, and do not re-raise the question per batch.

**Record the gap anyway, in [`docs/backports.md`](docs/backports.md)** — a record of what `main`
carries that the maintenance lines do not, for a future audit if the direction ever changes. Not a
to-do list.

- Write down both directions: "checked and not owed" saves the next audit as much time as "owed",
  and the per-file pick notes are the expensive half to reconstruct.
- The row goes **inside** the change's own commit, never as a follow-up commit. If it is marginal
  (test-only, a `main`-only suite), mention the gap in your report and skip the row.
- The file is carried on all five lines, so a maintainer on any line can read it.
- Largest known gap: **`v3.x` has none of the `DeleteOutcome` family**, so it cannot tell a trashed
  item from a permanently deleted one and offers ⌘Z for removals it cannot take back.

### Keeping the lines clean

- **Never merge one line into another.** All five stay linear. If a pick between lines is ever
  authorised again, use `git cherry-pick`, and **verify it landed by content, not by
  `git branch -r --contains`** — a cherry-pick has a new SHA, so `--contains` answers about the wrong
  commit.
- **`origin` carries the five lines and nothing else — check it, do not assume it.** A stray `roots`
  branch sat there unnoticed until 2026-08-27 because nothing ever looked. This prints exactly five
  lines when the remote is clean:
  ```sh
  git ls-remote --heads origin | awk '{print $2}'   # expect refs/heads/{main,v2.x,v3.x,v4.x,v5.x}
  ```
- **Any other remote branch is scaffolding and can go — but ask before pushing the delete**, and
  first establish that nothing unique dies with it: `git diff --name-status main <branch> | grep '^A'`
  must print nothing (it adds no file `main` lacks), and a local branch at the same SHA means its
  commits outlive the remote ref.
- **Tags are release-only** (`RELEASE.md` §1) and are never branched from, except once when a new
  maintenance line is cut.

### The one deliberate exception: `candidate-tap-deferral`

`candidate-tap-deferral` (`dba29645`) parks a single unlanded 2026-08-04 commit — a tap-gesture
deferral that was built, installed, clicked and **falsified**. [`docs/columns-layout-loop.md`](docs/columns-layout-loop.md)
cites it by name and SHA, with the numbers, so the result stays reproducible instead of becoming
folklore. **Delete the branch and the doc cites a SHA git will eventually collect.** A tag would be
tidier, but the tag namespace is release-only. Any other local branch you find is scaffolding.

---

## 2. Committing and pushing

@COMMIT.md

The full workflow is [`COMMIT.md`](COMMIT.md), imported by the line above so it loads with this file in
every session. In short: work in your own worktree; rebase on `origin/main`; squash by replaying onto a
fresh `<task>-themed` branch, preferring one commit; pass the gates (the equivalence diff is empty,
tests green, the app installed and seen running); fast-forward the primary and push — no ask. Never
force-push, never `git reset`, and commit a checkpoint before anything that discards working-tree
state.

---

## 3. After a push: keep going

Do not stop to report and wait. In order:

1. **Watch CI for the SHA you pushed** — `gh run list --branch main --limit 3`. A red your commit
   caused is the next task: fix it forward through the same steps. Read
   [`docs/flaky-tests.md`](docs/flaky-tests.md) before blaming the commit (§5).
2. **Pick up the next pending item** — your own session's follow-ups first, then open items that the
   roadmap and memory list as built-but-not-pushed or planned. Check `git worktree list` and the
   running sessions first, so you do not take over work another session is doing.
3. **If nothing is pending, run an adversarial review** of what has landed on `main` since the last
   one. Try to break the recent commits: edge cases, claims in commit bodies or docs the code does
   not support, tests that pass vacuously, regressions against the previous tag. Fix what is real,
   push it the same way, and go back to 1.

Stop only when you truly need his input — then ask that one question directly, and stop.

---

## 4. When to ask

The standing approval covers pushing finished work to `main`. **These still need his explicit yes,
asked one question at a time, in terms of what he will see:**

- cutting a release — tags, a GitHub release, flipping a Pages `latest` badge ([`RELEASE.md`](RELEASE.md))
- deleting a remote branch (§1)
- pushing to a maintenance line
- a force-push, if one ever seems truly needed (`COMMIT.md` §6)
- a design call only he can make

A mechanical choice with a clear default is not an ask: pick it, say so in the report, and keep
going.

---

## 5. Correctness and CI

**Refactors must be provably behaviour-preserving.** Build the pre-change binary at `HEAD` and diff
stdout, exit codes and resulting file trees against the new binary on a controlled fixture. State the
verification in the commit body. He runs this against real cloud data and audits commits, so a silent
behaviour change is costly.

**Before blaming a commit for a red suite, read [`docs/flaky-tests.md`](docs/flaky-tests.md).** It
carries the known flake mechanisms with the tell for each — the difference between fixing a
regression and re-diagnosing a machine. It is carried on all five lines, but the numbering is
per-line, so **cite a mechanism by its title, never its number**.

**The self-hosted CI runner is this Mac.** Heavy local test runs compete with it, and the
load-sensitive flakes then look like real failures. Check `uptime` before reading a red as a verdict.

---

## 6. Trying an app change

**Install from the worktree before you push** — an app change nobody has seen running has not been
verified, and he will be using the installed copy. Run the `install-sync-cloud` skill. It resolves the
current worktree's `.dd` as well as the shared DerivedData root, so nothing has to land first.

The skill quits the running instance, installs the fresh build to `/Applications/SyncCloud.app`,
de-dupes the DerivedData copy from Spotlight, sweeps stale build debris, then launches and verifies
the app — **by polling `~/sync-cloud.log` for a new line, not by `pgrep`**. A silent `open` exit is
not proof the app started, and neither is a live pid: the app can come up wedged with zero windows
and an empty log, which `pgrep` cannot see.

### Signing

**Every build is ad-hoc; the installed copy is signed with this Mac's Apple Development identity.**

- macOS keys a privacy grant to the app's designated requirement. An ad-hoc app's requirement is its
  cdhash, which changes with every build, so each install used to be a new app to macOS — and the
  iCloud pane sat blank behind the "access files in your Documents folder" dialog until someone
  answered it (the 2026-09-25 speed audit found 15 of 16 launches waiting, from 1.9 s to 46 min).
- Step 4 of the skill re-signs the bundle before copying it, so the requirement names the
  certificate instead. CI never uses the certificate, and neither does anyone else building from
  source.
- The app logs which kind of build it is right after its `launched` line — `Code signature: team …`
  or `Code signature: ad-hoc …`. An ad-hoc install asks for Documents access at first launch, and so
  will every install after it until one is signed.
- **The certificate expires 2026-12-01.** The skill signs through a renewal while both certificates
  carry the same name; with none, or with two different names, it installs ad-hoc and says so.
