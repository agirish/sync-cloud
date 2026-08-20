# Backport tracker

What each maintenance line is **owed**, what it is **deliberately not** owed, and how much of the
surface **nobody has looked at**. One file, carried identically on all three lines, so a maintainer
sitting on `v2.x` can see what `v2.x` is missing without reading `main`'s history.

The rule this tracks is in [`CLAUDE.md`](../CLAUDE.md): land a change on the **oldest line that
carries the code**, then cherry-pick forward. Only breaking changes, removals and restructures are
`main`-only. "Applies" means *the code is there*, not that a user would notice.

## How to check one thing

Two stages, and the second is the one that gets skipped:

```sh
git ls-tree -r --name-only origin/v3.x -- <path>        # 1. is the FILE there at all?
git show origin/v3.x:<path> | grep -c '<symbol>'        # 2. is the SHAPE there?
```

A file can be present and the fix absent — that is the usual case, and stage 1 alone reads as
"already done". Note `grep -c` **exits 1 on zero**, so `grep -c … || echo 0` prints *two* lines and
a miss silently reads as a hit; test the count, not the exit status. (Written down because this
audit made that exact mistake and every "MISSING" came back "Y".)

---

## `v3.x` — owed

### 1. The `DeleteOutcome` family — OPEN, deliberately deferred

`Modules/Sync/Sources/Sync/DeleteOutcome.swift` is absent on this line and `deleteItems` still
answers an `Int`, so it cannot report whether an item reached the Trash or was destroyed
permanently. Three fixes on `main` and `v2.x` have no `v3.x` counterpart, and each is a ⌘Z promise
the line cannot keep on a Trash-less volume (exFAT, most SMB shares):

| Missing on `v3.x` | `v2.x` / `main` | What 3.x still does |
|---|---|---|
| merge undo guard (`anyPermanentlyDeleted`) | `f8648c0c` / `7a220e62` | offers ⌘Z after a permanent delete — and undoing the fold DELETES the copied files, with the originals gone |
| partial-batch `undoable:` flag | `83a05f22` / `8a505b5f` | offers an undo that never expires, so it comes to point at another operation |
| duplicate-review log branch | `d6791da0` / `b632223d` | logs "Trashed" for a copy destroyed permanently |

**Not the usual cherry-pick**, which is why it is written down rather than done: each fix reads
`DeleteOutcome`, so taking them means taking the type and a `deleteItems` signature change onto a
shipped maintenance line. That is a scope call. Expect the `MacApp/` caller to move in the same
commit — leaving it behind is exactly what broke `main` and `v2.x` on 2026-08-16, with green
package suites and a red app-target step.

**This has a deadline.** `v3.x` sits at `3.2-dev`. Cutting v3.2 before this lands ships the
⌘Z-after-permanent-delete promise again, in a release, knowingly.

### 2. `theFloorIsOnlyLoweredByItsOwnTests` — OPEN, small

The repo-wide scan that keeps every real wait on `LayoutPumpWait`'s default floor exists **only on
`v2.x`** (`2f5ca5b5`). `v3.x` and `main` have `LayoutPumpWaitPollTests.swift` and the `poll` floor,
but nothing standing over it.

Not mechanical either: the guard is a substring scan for `floor: `, so on `v3.x`/`main` it would
immediately flag `ShortcutRevealTrackerTests`, which legitimately declares its own parameter. It
needs a permit entry or package scoping first. **Owed to `main` as well as `v3.x`.**

### Checked and NOT owed

Verified present on `v3.x` on 2026-08-20, so a future audit need not re-raise them:

| Family | symbol checked |
|---|---|
| cloud accounts wiped by an unreadable `CloudStorage` | `CloudStorageAccounts` |
| automation rules lost to one unreadable value | `unreadableFields` |
| spend record zeroed by an unreadable payload | `unreadable` in `FilingSpend.swift` |
| storage snapshots amended away | `unreadable` in `StorageLensStore.swift` |
| undo/redo moving an item it cannot identify | `liveLocation` |
| the `poll`/`pump` wait floors | `static func poll` |

---

## `v2.x` — owed

### Nothing confirmed

Every safety family above is present on `v2.x`, and it is the line the `DeleteOutcome` family
landed on first. No confirmed fix debt was found by this audit.

### Checked and NOT applicable

- **Storage lens preservation.** `Modules/Sync/Sources/Sync/StorageLensStore.swift` does not exist
  on `v2.x` at all — the lens is a 3.x-and-later feature. Stage 1 answers this; there is nothing to
  port to.

---

## The unaudited surface, honestly

Neither line has been audited commit-by-commit. These are the sizes as of 2026-08-20, narrowing from
raw divergence to plausible debt:

| | `v3.x` (vs `main`) | `v2.x` (vs `v3.x`) |
|---|---|---|
| commits not on this line (`git cherry`) | 504 | 135 |
| …touching ≥1 `.swift` this line carries | 326 | — |
| …touching `Sources/Sync` or `Sources/Settings` it carries | 129 | 51 |
| …and fix-shaped by subject | **96** | **35** |

**A fix-shaped subject touching a shared file is a candidate, not a debt**, and most of these are
not debt. The bulk of `v3.x`'s 96 are "fix N findings from a review of *X*" where *X* is v4 feature
work — the filing router, the household, the Organize restructure — that does not exist on `v3.x`,
so the fix has nothing to apply to. **Read the diff, not the subject**; that distinction is the
whole cost of this audit and the reason the number is not a to-do list.

Regenerate the table with:

```sh
git cherry origin/v3.x origin/main | grep -c '^+'
git ls-tree -r --name-only origin/v3.x > /tmp/v3files
# then: for each candidate, does it touch a file in /tmp/v3files?
```

---

## Recording a decision

Add a row here when a candidate is settled, in either direction — **"checked and not owed" is worth
as much as "owed"**, because the expensive part of this audit was re-deriving that a family was
already present. State the symbol that was checked, not just the verdict; a bare "done" is what
sends the next person back to `git log`.

Move an item out of "owed" only when `git branch -r --contains <sha>` names the line.
