# SyncCloud — working agreement

"He" is Abhishek, the project's owner. The commit and push workflow is [`COMMIT.md`](COMMIT.md),
imported in §2. Releasing is [`RELEASE.md`](RELEASE.md) — read it before any release cut or version
bump.

## Rules

- Work in your own worktree. Touch the primary checkout `/Users/abhishek/Projects/SyncCloud` only
  to fast-forward `main` when landing.
- Land on `main` only. No backporting.
- Push to `main` without asking once the gates pass (`COMMIT.md` §4). Any older note saying to ask
  before pushing is superseded.
- Never force-push. Never `git reset`, of any kind. No merge commits. Never merge one release line
  into another.
- Never run a command that discards uncommitted work (`COMMIT.md` §7).
- One commit per change, unless a second clearly earns its place.
- Refactors must be proven behaviour-preserving (§5).
- Run every `xcodebuild`, `swift build` and `swift test` through `scripts/build-slot` (§7).

---

## 1. Branches

Five long-lived branches, and only five:

| Branch | Carries | Marker at tip | Breaking changes |
|---|---|---|---|
| `main` | the **v6 line** — where the next release is built | `6.3-dev` / `603` | **allowed** |
| `v5.x` | maintenance for the shipped **5.x series** (cut at `v5.5`) | `5.6-dev` / `506` | **never** |
| `v4.x` | maintenance for the shipped **4.x series** (cut at `v4.6`) | `4.7-dev` / `407` | **never** |
| `v3.x` | maintenance for the shipped **3.x series** (cut at `v3.1`) | `3.2-dev` / `302` | **never** |
| `v2.x` | maintenance for the shipped **2.x series** (cut at `v2.8`) | `2.10-dev` / `210` | **never** |

- The markers must match each line's `project.yml` — check with the script in `RELEASE.md` §2.
  Cutting a new maintenance line: `RELEASE.md` §5.
- **No backporting**, and do not re-raise it per batch. Record what `main` carries that the
  maintenance lines lack in [`docs/backports.md`](docs/backports.md), both "owed" and "checked, not
  owed" — a record, not a to-do list. The row goes in the
  change's own commit. For a marginal change (test-only, a `main`-only suite), skip the row and
  mention the gap in your report.
- Keep every line linear. If a pick between lines is ever authorised, use `git cherry-pick` and
  verify it landed by content, not by `git branch -r --contains`.
- `origin` holds exactly these five branches. Check it:
  ```sh
  git ls-remote --heads origin | awk '{print $2}'   # expect refs/heads/{main,v2.x,v3.x,v4.x,v5.x}
  ```
- Any other remote branch may be deleted — ask first, and only once both checks pass:
  `git diff --name-status main <branch> | grep '^A'` prints nothing, and its commits survive in a
  local branch at the same SHA.
- Tags are release-only (`RELEASE.md` §1).
- **Keep the local branch `candidate-tap-deferral` (`dba29645`).**
  [`docs/columns-layout-loop.md`](docs/columns-layout-loop.md) cites it by SHA. Any other stray local
  branch is scaffolding.

---

## 2. Committing and pushing

@COMMIT.md

---

## 3. After a push: keep going

Do not stop to report and wait. In order:

1. **Watch CI for the SHA you pushed** — `gh run list --workflow hosted-ci.yml --commit <sha>`: every
   push to `main` runs on GitHub's hosted runners, one run per commit (`docs/ci.md`). Fix a red your
   commit caused, forward, through the same steps. Read [`docs/flaky-tests.md`](docs/flaky-tests.md) first.
   A push that changes only root-level Markdown or `docs/` starts no run (`docs/ci.md`), so there is
   nothing to watch; `RELEASE_NOTES.md`, `README.md` and `docs/releases.html` still run.
2. **Pick up the next pending item** — your own follow-ups first, then open items the roadmap and
   memory list as built-but-not-pushed or planned. Check `git worktree list` and the running
   sessions so you do not take over another session's work.
3. **If nothing is pending, run an adversarial review** of what landed on `main` since the last one:
   edge cases, claims in commit bodies or docs the code does not support, vacuous tests, regressions
   against the previous tag. Fix what is real, push, and go back to 1.

**Unrelated work starts in its own session, and asks its questions there.** Fixing your own red
(step 1) stays in this session; a step 2 item from elsewhere and every step 3 review do not.

Stop only for a question you truly need answered — ask it directly, then stop.

---

## 4. When to ask

Pushing finished work to `main` needs no ask. These do, one question at a time, in terms of what he
will see:

- cutting a release — tags, a GitHub release, a Pages `latest` badge ([`RELEASE.md`](RELEASE.md))
- deleting a remote branch (§1)
- pushing to a maintenance line
- a force-push, if one ever seems truly needed (`COMMIT.md` §6)
- a design call only he can make

For a mechanical choice with a clear default, pick it, say so in the report, and keep going.

---

## 5. Correctness and CI

- **Refactors must be provably behaviour-preserving.** Build the pre-change binary at `HEAD`, diff
  stdout, exit codes and resulting file trees against the new binary on a controlled fixture, and
  state the verification in the commit body.
- **Read [`docs/flaky-tests.md`](docs/flaky-tests.md) before blaming a commit for a red suite.** Cite
  a mechanism by its title, never its number — numbering differs per line.
- **The self-hosted CI runner is this Mac**, for release tags, the nightly run and hand runs; pushes
  run on GitHub's hosted VMs (`hosted-ci.yml`), whose 3 vCPUs bring load flakes of their own. Check
  `uptime` before treating a self-hosted red as real. §7 keeps the load down.

---

## 6. Trying an app change

- **Install from the worktree before you push**, with the `install-sync-cloud` skill. It finds this
  worktree's build, so nothing has to land first. It quits the running app, installs to `/Applications/SyncCloud.app`, and verifies the launch by polling
  `~/sync-cloud.log` for a new line — not by `pgrep`, which cannot see a wedged app.
- **Builds are ad-hoc; the installed copy is signed** with this Mac's Apple Development identity. An
  ad-hoc signature changes with every build, so macOS would treat each install as a new app and ask
  for privacy access again; a signed copy keeps its grants. CI never signs. The log line after `launched` says
  `Code signature: team …` or `Code signature: ad-hoc …`; an ad-hoc install asks for Documents
  access at first launch.
- **The certificate expires 2026-12-01.** The skill signs through a renewal while both certificates
  share a name; with none, or two with different names, it installs ad-hoc and says so.

---

## 7. Builds share this Mac

Every session, and the CI runner, builds on the same ten cores. More concurrent builds than that buy
no throughput; they slow every build and make the timing-sensitive suites flake.

- **Queue every heavy command for a slot:** `scripts/build-slot xcodebuild …`,
  `scripts/build-slot swift test --package-path Modules/Sync …`. Commands wait first come, first
  served for one of a machine-wide number of slots (default **2**), then run with their output and
  exit status untouched. `xcodegen`, `git` and everything light run directly. A worktree without
  the script (a maintenance line) uses the primary checkout's copy,
  `/Users/abhishek/Projects/SyncCloud/scripts/build-slot`.
- **A hook enforces it.** `.claude/settings.json` runs `scripts/build-slot-hook` before every Bash
  call; it refuses an unwrapped `xcodebuild` build or test, `swift build`, `swift test` or
  `swift run` and names the exact command to rerun. Light commands, and text that only mentions
  a build, pass.
- **A wait is reported, never silent:** at once and then once a minute on stderr, with your place
  in line and each holder's PID, worktree and command. Run long builds in the background so a wait
  cannot hit the tool's timeout. `scripts/build-slot --status` shows the holders and how many wait.
- **Changing the count:** `echo 3 > ~/Library/Caches/SyncCloud-build-slots/slots` for every
  session, `BUILD_SLOTS=3` for one command. A killed or crashed holder frees its slot at once.
- **Stopping a wrapped command ends what it started**, such as the test helper a killed
  `swift test` can orphan (`docs/flaky-triage.md`). Killing the wrapper alone with `SIGKILL` skips
  this, and frees its slot while the build runs on.
- **Compile-only commands run at `nice` 10; tests never do**, because a slower test run is a
  flakier one (`docs/flaky-tests.md`). The CI runner takes no slot, by decision: its verdict is
  never queued behind a session's build.
- **Iterate narrow, gate wide:** `--filter` or `-only-testing:` while working; the full
  seven-package run and `xcodebuild test` only as the landing gate (`COMMIT.md` §4).
- **Debug while iterating; Release only for the install** (`install-sync-cloud`).
- **Run a CPU-stress flake probe (`yes` spinners and the like) under
  `scripts/build-slot --exclusive`**, which waits its turn, then holds every slot, so no session
  builds beside it. Check `gh run list --status in_progress --limit 1` first: CI takes no slot.
