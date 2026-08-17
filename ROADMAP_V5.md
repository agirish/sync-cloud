# SyncCloud — v5.0 roadmap: Restructure

**Scope:** one project. **Organize ▸ Restructure** — the storage-layer gaps behind a lens that
already ships (§4), the plan surface it was deliberately shipped without (§5), and the first folder
survey, run in the background, which is what gives a fresh machine anything to read at all (§6).
§§4–5 run first, under the four decisions recorded below; §6 follows the release, and that section
says why. `main` only.

**Moved out of `ROADMAP_V4.md` on 2026-08-16, unchanged.** It was v4.2's defining feature until
then; it is now its own release, because it is its own project. Everything below is the text as it
stood, with two exceptions, both deliberate and both visible: release references that said *4.2* now
say *5.0*, and the decisions block's "v4.2, not v5.0" bullet is struck with its reasoning kept —
that argument is reversed, and the reversal is explained where it sits rather than here.

**Section and figure numbers are carried over, not renumbered.** These are still §§4, 5 and 6, and
the figures are still 21–34. "§4.2 shipped" and "§5.5 step 6" appear in both companions, in commit
messages and in the audit notes; renumbering would silently repoint every one of them.
`ROADMAP_V4.md` keeps a tombstone at those numbers and starts its own new work at §7.

**Why v5.0 and not v4.3.** `CLAUDE.md` earns a major with a breaking change, and by that rule this
would be v4.3: nothing here breaks, removes or restructures a shipped behaviour, and §5.5 is written
so no `schemaVersion` ever goes incompatible. **The major is earned by size instead** — Apply moves
folders on disk and needs an on-disk inverse, a ledger, six invariants and a re-derived profile after
every landing. This is a deliberate departure from that bar, taken on 2026-08-16, and it is recorded
in three places (here, the decisions block, and `ROADMAP_V4.md`'s preamble) so that it reads as a
decision rather than an oversight when someone checks the rule against the tag.

Distinct from `ROADMAP.md` (the standing feature backlog across all surfaces),
`ROADMAP_V4.md` (the 4.x line), `DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md`
(internal shape). An item graduates out of this file the way it does out of those: deleted when it
ships, because git history is the record.

§§4–5 were designed and mocked on **2026-08-12**; **§6 was designed on 2026-08-13**, and its
constraints were read out of the code that day — the day part of §4.2 shipped, which is why §4.2
carries measurements rather than a plan.

An **illustrated companion** carries the figures this file can only describe:
<https://claude.ai/code/artifact/929eb3d2-d381-4fa5-b456-a0a9c9313cea>. **This file is the one that
ships** — if it disagrees with the companion, the companion is the stale one. §5 has a **second
companion**, its own eight-screen mockup set:
<https://claude.ai/code/artifact/73b57ccc-56f2-4437-9f2f-a1e85c47a646>.

**Reviewed for implementation-readiness on 2026-08-16 (evening)**, against the code, the live
profile and the 6 Aug manifest, with four decisions taken in that review; they are the block below,
and every §4–§6 item was re-cut under them. Where a figure in either companion now disagrees with
this file — the mapping editor's refusal of merges, §5.4's ledger, the Order — the file is right.
The companions also still call this a 4.2 release; that is the move, not a disagreement about the
work.

---

## Restructure in v5.0 — the decisions

Four questions the audit surfaced were answered on 2026-08-16, and they settle what §§4–6 may
claim. Everything below them is written under these; nothing in them is open.

| Question | Decision | What it changes |
|---|---|---|
| **Who is 5.0 for?** | **This machine.** Restructure ships against the hand-built profile that already exists here; the fresh-machine path is **§6, after the release**. | §6 is not on 5.0's path and nothing in §§4–5 waits on it. But §5.5's re-derivation (below) makes the *profile* half of §6 nearly free — see §6, "Two halves". |
| **Merges?** | **Designed in.** Two source folders onto one target inside a member is a first-class operation, with a collision policy and its own ledger line. | §5.4 stops refusing the case the flagship family needs; the mapping model, the manifest and the ledger all carry it. |
| **Who owns the profile after an Apply?** | **The app re-derives it from a fresh walk, carrying two judgement fields forward.** `buildTree` ＋ `FolderSurveyBuilder.build` after every landing; `acceptsNewFiles`/`noIntakeReason` and `naming` are copied from the previous profile for every path that survives, directly or through the manifest's rename map; the jurisdiction set is the distinct entry-level values of the previous profile (`US`, `IN`, **`Singapore`** — the header lists only two). The old file is never deleted: the new one is written under a fresh id and `profiles.json` is re-pointed, which is what `writeProfile` does today. | The finding is genuinely gone after Apply because the detector re-ran on a real profile. The create-only guard now protects *hand-built* files from *derived* ones by provenance, not existence. Costs accepted and written down in §5.5: the 80 cached cloud verdicts re-bill (the profile is in the fingerprint — and they name paths that moved, so invalidating them is correct), and the hand-authored doctrine sections go inactive (nothing decodes them; the file that carries them stays on disk). |
| **How far does Apply go in the release?** | **All of it, landed in stages** — renames first, then moves and merges, then the opt-in removal step — behind the six invariants, ⌘Z and an on-disk inverse. | §5.5 is release-gating, not a stretch. Export-only would leave the defining feature ending in a JSON file. |

**Two more that followed from those:**

- ~~**v4.2, not v5.0.**~~ **Reversed on 2026-08-16 when this work moved out of `ROADMAP_V4.md`:
  it is v5.0, and the major is earned by size rather than by breakage.** The original reasoning is
  kept because it is still true as far as it goes, and it is what makes the version *safe* to
  choose either way: nothing here breaks, removes or restructures a shipped behaviour — the lens
  gains a plan surface, the store gains a write it did not have, and every existing file still
  decodes. A major would be earned *by the compatibility rule* only through an incompatible
  `schemaVersion` on the profile, the corpus or the memory, and §5.5 is written so that never
  happens (the new profile is the *same* schema with a provenance field; the old one still loads).
  What changed is the other half of the argument: Apply moves folders on disk and needs an on-disk
  inverse, a ledger, six invariants and a re-derived profile after every landing, and shipping that
  as a point release would be the misleading label. **This is a deliberate departure from
  `CLAUDE.md`'s bar for a major**, recorded here so it reads as a decision rather than an oversight
  when someone checks the rule against the tag.
- **One app-owned store for everything Restructure remembers**, not four — see §5.0. Suppressions,
  Ask answers, drafted plans and the applied ledger all key on the same `kind × path` identity and
  all live in `restructure.json` beside the profile. §5.3 was going to be the store's first
  customer; the ledger is now, and it is release-gating.

**What makes it fundamentally useful, and not just correct** — worth stating because the audit
measured the shape detector at **one finding on the whole tree**: the value in 5.0 is spread across
five things, not one. (1) The flagship family finally converges, merges included. (2) **Backlog
becomes actionable, not just visible** — *set up 2025 like its siblings* creates the scaffold the
series expects and hands the flat files to To File; that is the operation you would use every year,
and it is non-destructive (§5.2). (3) The dead-weight and empty-folder counts turn into filtered
lists with a Trash path for the sub-class that has a rule (§5.2). (4) A landing that can be undone
after a quit, from a ledger, not only with ⌘Z (§5.5). (5) A profile that follows the tree, so the
lens is never describing a tree that no longer exists (§5.5). If those five hold, the release is
worth its name on a tree that has already been hand-tidied.

---
---

## 4. Restructure: a cached answer, and no way to run one

**Why:** the lens opens on its setup card and says its answer is cached (shipped `6c56768a`). It
cannot say *how* cached, and on a machine with no folder survey its card still has no trigger —
the app can now *derive* a profile (§4.2, shipped) but has no way to *run* the derivation (§6).
Both are storage-layer gaps behind a view that is already done.

### Context

| Fact | Where | Consequence |
|---|---|---|
| **The survey's `generated` stamp is write-only.** It is set on a private `Encodable` struct; `FilingMemory`, the type actually decoded at launch, has no such field. | `Modules/Sync/Sources/Sync/FilingSurveyStore.swift` | Nothing can read a date back today, which is why the card claims coverage only. |
| **And it means "last changed", not "last surveyed"** — the memory is written only when `memory != previousMemory`. | same, `write(corpus:memory:previousMemory:…)` | A survey run this morning on a settled tree leaves last month's stamp. Showing that would be worse than showing nothing. |
| **The corpus is written unconditionally, and is NOT hashed into the fingerprint** — which covers `folder-profile.json`, `filing-memory.json`, `people.json`. | `FilingProfileStore.fingerprint(id:in:)` | The corpus is the one artifact that moves on every survey *and* costs nothing to move. A per-survey timestamp in a hashed file changes `FilingVerdictKey` and re-bills every cached cloud classification. |
| **`resurveyFilingMemory` cannot bootstrap.** It opens with `guard let profileId = filingMemory?.profileId ?? filingFolderProfile?.profileId` and returns `.none` otherwise. | `Modules/Sync/Sources/Sync/FileSyncManager+FilingSurvey.swift` | The half the app owns cannot produce the half it does not, so a fresh machine has no way in. That is why §4.2 was a new builder rather than "just run the re-survey", and it is the guard §6 opens with. |
| **`isAxisValued` already falls back to `isBareYear` and `isInboxPath`** — its own doc says the fallbacks exist "for a profile that records no axes at all". | `Modules/Sync/Sources/Sync/StructureDivergence.swift` | A profile that records no axes at all is still enough to make **this lens** work, through those fallbacks; what it misses is exact — non-year axis values (`Family/Mom`, `Finance/US`) read as vocabulary, so two eras can look different when they differ only by whose folder they are. The derived profile does not need the fallback: it records `axes`, which is part of why Restructure cannot tell it from the hand-built one (§4.2). |
| **The folder profile has exactly one write path, and it refuses over an existing profile.** `writeProfile` throws `WriteRefusal.profileExists`, writes atomically, and re-points `profiles.json` only when nothing is active. `FilingSurveyStore` still never writes a profile. | `Modules/Sync/Sources/Sync/FilingProfileStore.swift` (`writeProfile`, shipped `d4280231`) | A derived profile can never land on top of a hand-built one, which is what a walk cannot re-derive: `naming`, `folderSemantics`, the `outbound-pack` refusals. There is deliberately no `overwrite:` parameter. **Revised by the decisions block:** from 5.0 the guard keys on *provenance* — a file the app derived is the app's to replace, a hand-built one still is not — and "replace" always means *write a new id and re-point*, never overwrite. §5.5 carries the mechanism. |
| **The builder needs a walk, not a survey** *(review)*. `FolderSurveyBuilder.build(tree:root:profileId:registry:jurisdictionValues:)` reads folder names, file names and counts; no PDF is opened. `FileSyncManager.buildTree(url:sortOption:fileManager:maxDepth:)` produces that walk today. | `FolderSurveyBuilder.swift:58`; `FileSyncManager+Scanning.swift:914` | Re-deriving a profile is seconds, and it is the same two calls whether the reason is an Apply (§5.5) or a fresh machine (§6). The hours in §6 are the *document* survey — the corpus and memory the router wants — which Restructure does not read. |

### 4.1 A truthful "last surveyed" — small

Display-only. Five files, ~150 lines.

1. `FilingCorpus` — add `public var surveyedAt: Date?`. Optional, so a corpus written earlier or by
   the offline builder still decodes.
2. `FileSyncManager+FilingSurvey` — stamp it before `FilingSurveyStore.write(…)`, and take `now` as
   a parameter (`docs/flaky-tests.md` mechanism 5: inject the instant, don't race the clock).
3. `FileSyncManager` — `@Published var filingSurveyedAt: Date?`, so the footnote updates the moment
   a re-survey finishes.
4. `MacApp/SyncCloudApp.swift` — read it in the block that already loads the profile, memory and
   fingerprint; `Sync` does not reach into a home directory.
5. `RestructureLens` — widen to `surveyNoteText(folderCount:surveyedAt:now:)`, plus a caution
   variant past a threshold. **Only the glyph takes the tint** — amber on 11pt body text is a
   contrast trap this repo has hit before.

**Test the pair that pulls both ways:** the stamp must move when a survey changes nothing, and the
fingerprint must *not* move with it.

**The threshold is unmeasured.** 30 days is a guess. Ship the plain variant first and pick the
number from real stamps.

### 4.2 Building a survey in the app — the derivation shipped

`FolderSurveyBuilder`, `FilingProfileStore`'s first write path and `JurisdictionCandidates` landed
in **`d4280231`** on 2026-08-13. The two items that remain are not a smaller version of what
shipped — they are an execution model and a dialog, and they are **§6**.

What shipping measured revises the plan those items were written under, so it is recorded here
rather than deleted with them. Every number below comes from walking the real tree and comparing
field by field against this machine's hand-built 3,013-folder profile (`~/Documents`); the
comparison itself is `FolderSurveyGroundTruthTests`, machine-pinned to that tree.

| The plan said | The measurement says |
|---|---|
| Leave `naming`, `anchors` and `axes` **empty** rather than guessing. | **`anchors` and `axes` are derived.** They are what the router consumes, and leaving them empty forfeited most of the value. Agreement: role .998, anchors .997 (the whole list, in order), `acceptsNewFiles` .998 with **39 of 39 inboxes refused and no false positives**, person .998, lifecycle .999, year and fiscalYear 1.000, jurisdiction 1.000 *once its values are supplied*. |
| A wrong `naming` would have the rename pass propose renames toward a convention nobody has. | Unchanged — `naming` is still never guessed — and now with a second reason: **nothing reads `FolderProfileEntry.naming`** outside test fixtures, so accuracy there would buy nothing even if it were free. |
| "the degradation asserted rather than described" — the same synthetic tree with and without axes. | **Restructure returns the identical finding from a derived profile as from the hand-built one.** `theLensSeesTheSameThingInADerivedProfileAsInAHandBuiltOne` pins the mechanism behind that — the lens reads no field a walk abstains from, so enriching a derived profile with `naming` changes nothing it returns. It does not pin the full claim, which is about two profiles whose `axes` differ by up to 0.2%, and `axes` is a field the lens does read; that remains measured rather than asserted. There is no degradation left for this lens to characterise, so the planned test is settled by removing its subject — but the *claim* still needed pinning, and for a while it had none: nothing outside `FolderSurveyBuilder`'s own tests fed a derived profile to anything, so the day this lens starts reading a field only the offline survey produces, nothing would have failed. What a walk still cannot re-derive is `naming`, `folderSemantics` and the jurisdiction vocabulary — and that, not a degraded profile, is what the store's refusal protects. |

Three rules came out **narrower** than the plan assumed. Each was swept rather than argued, and the
losing variant is written down beside the winner:

- **The inbox test asks the leaf, not the path.** Asking `isInboxPath` of the whole path scores
  .992 against .998, because `Finance/US/TODO/IRS/2023` is a year bucket. Its *permission* is a
  separate question, and `acceptsNewFiles` does still ask the whole path.
  (`FolderSurveyBuilder.role`, doc.)
- **The archive test asks the folder's own name**, with `axes.lifecycle` carrying the fact that
  propagates. Any-component matching costs the same .992. (same doc.)
- **The anchor cap is 10, not 14** — 10 → .997, 12 and 14 → .979. The literal is
  `FolderSurveyBuilder.anchorLimit`; the sweep behind it is in `d4280231`'s body, not in the source.

And two things the plan did not know it needed:

- **The anchor tokenizer is deliberately not `FilingRouter.tokenize`.** Running the whole pipeline
  through the router's tokenizer measures **.320 against .997**. The two exist for different jobs —
  the router's must agree byte for byte with the memory that wrote its index; this one feeds a
  human-readable list of what a folder is about — and `theRoutersTokenizerWouldBeMuchWorseHere`
  re-derives that gap on every run rather than quoting it, so nobody unifies them on the
  reasonable-looking grounds that both make tokens out of names.
- **Jurisdiction values cannot be derived.** The heuristic alone scores **.83**, and the gap is
  three inventions: it proposes `HPE`, `IT` and `PRD` as *places*. Without its 2–3-character bound
  the strongest candidate on this tree is **`TODO`**, under more parents than `US` — the inbox
  marker the whole filing path exists to refuse. So values are **proposed for confirmation, never
  adopted**, which is what puts them in §6's dialog. The rule also **misses**: `Singapore` is a real
  jurisdiction here (10 folders) and appears under only two parents, below the three-parent bar, so
  the dialog must let a value be **added** as well as ticked or the tree's third jurisdiction can
  never be recorded at all.

### 4.3 Shadow axis values — medium, and it is a report rather than a repair

`StructureDivergence` names this gap and explicitly does not claim it: a year-bearing folder name
that is not a *bare* year (`IRS Docs - 2023`) is treated as a role rather than as a year.

The pattern is on the real tree — `Finance/US/Income Tax` reports three shapes, one of which is
`IRS Docs - 2023, IRS Docs - 2024` beside bare years. Its own detector, not a wider `isBareYear`:
widening that would start swallowing real role names containing digits.

**Reframed by the 2026-08-16 audit, on two measurements.** This item used to say the shadow value
joins its parent's vocabulary and makes that parent's shape look unique — implying the Shape
detector is less accurate for it. Adding exactly that rule to `isAxisValued` and re-running the
whole detector over the live profile returns **the identical finding set**, one family before and
one after. So the value here is the *report* — naming `IRS Docs - 2023` as a year folder that should
be `2023` — not accuracy.

**And the rule has to be the narrow one.** **302 folders** carry a four-digit year in a name that is
not a bare year, and almost all are correct: `01. Jan 2019` monthly statement folders,
`2005 - 2006` Indian fiscal years. A detector keyed on *the name contains a year* fires 302 times,
which is precisely the failure `StructureDivergence`'s own doc was written to prevent. Scoped to
**a shadow year sitting beside bare-year siblings** it fires **5** times. Note also that its
proposed fix — `IRS Docs - 2023` → `2023`, where `2023` already exists — is a **merge**, which
§5.4 now defines: the two-file folder moves into the year and is emptied, and the year keeps its name.

**This is one of §5.2's eight detectors.** Build it once, there — it is listed here because it is
storage-side and needs neither the plan surface nor a scoped read.

---

## 5. Restructure: propose the fix, not just the finding

**Why:** the lens reports and stops. A finding names a disagreement and offers `Reveal`; acting on
one means Finder, by hand, for an afternoon. `ROADMAP.md` item 20 designed the plan surface and
deferred it behind six safety invariants — this is that surface, **scoped to the selected folder**,
plus the detectors it needs to be non-empty at a leaf. §4 is the storage underneath the same lens
and is independent of this.

The flagship case has been accumulating for thirteen years, and the whole flow was **run by hand
once** — `immigration_reorg_2026-08-06.json`: 132 file moves, 4 folder renames, 39 empty-folder
removals, 2 of them mistakes. That log is the worked example, and most of the constraints below are
scars from it.

**Be exact about which half of that day this surface claims.** Sorting the log's 179 operations by
whether a folder-name → folder-name mapping could have proposed them: **4 `rename-dir` yes**;
**108 file moves yes**, because they came from 44 source folders that moved wholesale and are
therefore folder-level operations; **24 file moves no** — they came from 5 folders whose files were
split by *content* (`Immigration/TODO` sent files to five different destinations), which is per-file
judgement and belongs to To File; **39 removals** only through §5.5's opt-in step. The plan surface
is the shape half. Saying so here is cheaper than discovering it on the first real run.

### Context

**Audited against the code and the live 3,013-folder profile on 2026-08-16, and re-read for
implementation-readiness the same evening.** The rows marked *audit* are ones that re-measuring
changed or added; the rows marked *review* were added by the readiness pass. Two of the audit rows
blocked items below until the decisions block settled them.

| Fact | Where | Consequence |
|---|---|---|
| **Restructure compares sibling *families*.** Under a scope pointed at a leaf the `inside` list is frequently empty and the lens falls back to showing the ancestor's findings, faintly — its own doc calls this out. | `RestructureLens.aboutAncestor` | The detectors that read **one subtree alone** (§5.2) are what make a scoped answer non-empty. Without them the plan surface has nothing to open at the depth people scope to. |
| **One detector of eight shipped.** Dead weight, backlog, mirrored inbox, echo names and shadow axes are designed and unbuilt. | `StructureDivergence` | A crowded branch gets the same answer as a tidy one: silence. Measured 2026-08-16, the whole lens returns **one finding, in one of sixteen top-level areas** — so the lens is thin because seven detectors are missing, not because it is unscoped, and that is the argument for §5.2 going first. §4.3 is one of the eight — build it as part of §5.2, not twice. |
| **`memberCount` sums the *vouched* schemes only** — a scheme of one is dropped as drift before the card is drawn. **And that is only one of two drop paths** *(audit)*: a sibling whose vocabulary is empty — a leaf, or one whose children are all axis values — is dropped *before clustering starts*, so it never becomes a scheme to grey. | `StructureFinding.memberCount`; `StructureDivergence.finding`, the `guard !words.isEmpty` | The card reads **11 folders** on a family of **17**: 11 vouched ＋ 5 unvouched drift ＋ 1 with no vocabulary at all (`CA State`, 3 files, 0 folders). **A folder with no shape is the one the plan most needs to house** — it is evidence for no era, so nothing else will claim it. |
| **`StructureFinding.id` is the family path** *(audit)*, and `RestructureLens` renders `ForEach(findings)`. | `StructureDivergence.swift`; `RestructureLens.body` | §5.2's whole point is that one family can produce a *Shape* **and** a *Series* **and** an *Ask* — three rows sharing one identity in one `ForEach`. **Put the kind in the identity before the second detector lands**, not after. The same composite key is what §5.3's answer store and *never suggest this again* both need, so it is one decision serving three items. |
| **Nothing in the app can rebuild a folder profile** *(audit)* — `writeProfile` throws `WriteRefusal.profileExists` and has deliberately no `overwrite:`; `resurveyFilingMemory` writes the corpus and the memory and never a profile; `structureFindings` is memoised and dropped only by `filingFolderProfile`'s `didSet`. | `FilingProfileStore.writeProfile`; `FileSyncManager+FilingSurvey`; `FileSyncManager.structureFindings` | **Was the blocking one; decided.** The detector reads `FolderProfile.folders`, keyed by relative path, and §5.5 renames exactly those paths. From 5.0 an Apply ends by re-deriving the profile from a fresh walk (decisions block; mechanism in §5.5), so the finding is gone because the tree was re-read. |
| **The corpus and the memory are keyed by relative path too** *(review)* — `FilingCorpus.documents` by document path, `FilingMemory.folders` by folder path; the memory is hashed into the fingerprint. | `FilingCorpus.swift`; `FilingMemory.swift`; `FilingProfileStore.fingerprint` | An Apply strands three artifacts, not one. Re-deriving fixes the profile; the corpus and memory get the **manifest replayed onto their keys** — a rename maps a prefix, a move maps a path — so no page is re-read for a file that only moved. The fingerprint moves either way; that is correct (§5.5). |
| **The primitives Apply needs already exist, and the rename pass is the worked example of using them** *(review)*: `enqueueFileOperation` (serialised, counted in `activeFileOperationsCount`), `safeMoveItem` (never overwrites), `generateUniqueURL` (keep-both), `registerMoveUndo` (one grouped ⌘Z per pass, **in-memory, gone at quit**), the `isVerifyAllRunning` write-exclusion guard, and the pattern of *re-listing the folder inside the operation and applying only steps the disk still asks for*. | `FileOperations+Primitives.swift:142,266`; `FileSyncManager+Undo.swift:189`; `FileSyncManager+FilingRename.swift:201` | "Shares the rename pass's review-and-apply path" means **these**, not its view. Two things it does not have and §5.5 adds: an inverse that survives a quit, and a verifier from a different code path. |
| **A folder rename on this tree is one filesystem operation carrying every file inside it** — the rename pass moves files; a `rename-dir` moves a directory with `safeMoveItem` and iCloud / Dropbox sync it as a rename. | `FileOperations+Primitives.swift:266` | The reason *prefer the rename* is not only tidiness: on an iCloud tree with evicted files a rename never forces a download, and a merge (per-file moves within one container) does not either. Nothing in §5.5 crosses a volume. |
| **`folderSemantics` is decoded by nothing** *(audit)* — the two matches in the Swift tree are both comments. `FolderProfile` decodes five fields; `conventions`, `axes`, `folderSemantics`, `structuralRules` and `canonicalPaths` are read by nobody, and the three live entries are hand-authored prose doctrine. | `FolderProfile`; `folder-profile.json` | §5.3 was specified to write its answer there. It cannot, and should not — see §5.3, which now carries its own store. |
| **The crowding counts came from a smaller tree** *(audit)*. | live profile, 2026-08-16 | Pass-through is **86**, not 52; single-file leaves **503**, not 434. Both figures print in the mockups as though they were the app's output — **derive them, never paste them**. |
| **The rename pass already owns a review-and-apply path** — per-folder plans, "as one undoable change", and a *left alone, for a stated reason* tail. | `RenamePassLens`, `onApply` | The plan shares it rather than growing a second one. `ROADMAP.md` 20 makes that its scheduling constraint. |
| **The one paid control names its model, names its batch size, and raises a spend pre-flight with a real estimate.** Its branch is *is a key stored*, not *is cloud switched on*. **It is typed to `[FilingSuggestion]`** *(audit)* and gated on `filingCloudRefineAvailable` ＋ `canRefineFilingSuggestions`. | `LensWorkspaceView.refineButton` | §5.6 reuses the **pattern** — same slot, same words up to the ellipsis, same billing sentence, nothing new to design — but not the function. That is the difference between "small once §5.4 exists" and a day. |
| **Answers and applied plans both invalidate the check that asked them.** | v3.1 review; `Refine` is already a generation-bumper | §5.3 and §5.5 must bump a structure generation and recompute, or the lens re-suggests what it was just told. |

### 5.0 Identity and the store — small, and first

Two things every item after this one leans on, so they land before any of them.

**Identity.** `StructureFinding.id` becomes `kind × family` — a `FindingKind` enum (`shape`,
`series`/backlog, `shadowAxis`, `echoName`, `mirroredInbox`, `deadWeight`, `ask`) plus the family
path. Today `id` is the family alone and `RestructureLens` does `ForEach(findings)`, so the second
detector to land collides with the first in one `ForEach` (audit). The kind carries the **verb** the
card shows (§5.1) and is the first half of every key below.

**The store.** One per-profile, app-owned, atomically written file, `restructure.json`, next to
`people.json` — precedents `PeopleStore`, `PersonTagStore`, `StorageLensStore`,
`FilingVerdictCache`. Four sections, one key:

| Section | Keyed on | Written by | Read by |
|---|---|---|---|
| `suppressed` | kind × path | *Never suggest this again* on any card | the lens, before rendering; the rail badge |
| `answers` | kind × path → chosen option | §5.3's Ask sheet | the detector that asked, so it never asks twice |
| `drafts` | kind × family → mapping ＋ manifest | §5.4, when the sheet closes with a plan | §5.7's *Planned, not applied* card |
| `applied` | manifest id → manifest, inverse, `at`, outcome counts, the profile id it was applied under and the one it produced | §5.5, at the end of a landing | §5.7's *Applied* card; **`Undo this reorganisation`**; the log |

**Answers, drafts and suppressions all survive a re-survey** — the profile can be replaced under
them (§5.5) and their keys are paths, not profile ids. What they do *not* survive is the path
moving: an Apply replays its manifest onto this file's keys too, the same replay §5.5 runs on the
corpus and memory. **Not `folderSemantics`**: nothing decodes it, and the profile is not the app's
to edit in place.

**Proof:** a round-trip test per section; a test that a suppressed finding stays suppressed after
the profile is swapped for a derived one; a test that a rename in a manifest re-keys every section
that named the old path — and leaves one that named a sibling alone.

### 5.1 The scoped read — small

Display-only, no new machinery. Fig. 21.

- Each finding card gains a **kind tag carrying the verb** — *Shape* renames or merges folders,
  *Series* scaffolds and hands off, *Ask* asks — so the class of change is legible before the sheet
  opens.
- The card states its blast radius, derived from the draft where one exists and from the family's
  shape where none does: for a one-to-one family *a plan here is folder renames, no file would move*;
  for the flagship family, whose convergence needs merges, *N folders would be renamed and M merged,
  so files would move* — the honest sentence, and the one that makes someone open the sheet.
- **The count stops undercounting, on both drop paths** (see Context): the subtitle counts the
  family, the unvouched scheme renders greyed as drift, and **the shape-less sibling gets a row of
  its own** — *no shape of its own* is a different sentence from *disagrees with the others*, and
  this lens's whole discipline is that no state borrows another's words. On the flagship family that
  is 11 → 17, not 11 → 16.
- `Reveal` demotes to a link; `Plan…` takes the primary slot.
- **The rail badge counts only the kinds that carry a plan.** A badge you cannot drive to zero is a
  badge people stop reading, which is why *Ask* is excluded. **Cheaper than it looks:** the badge is
  already scoped and already excludes ancestor findings (`RailCounts.restructure`), so filtering by
  kind is the only new part.

**Proof:** the flagship family fixture (folder names only, lifted from the live profile into the
repo — 17 members, 24 child names) renders **17** in the subtitle, one greyed drift scheme, and one
*no shape of its own* row for `CA State`; the badge equals the count of plan-bearing kinds inside
the scope and ignores an Ask beside them; a scoped read at a leaf still shows the ancestor's
findings faintly, and a `Plan…` on the card, never a `Reveal` in the primary slot.

### 5.2 The remaining detectors, and the crowding strip — medium

Each is a finding kind before it is a plan, and each is worth landing on its own. Fig. 22.

Detectors, all specified in `ROADMAP.md` 20: **backlog** (the newest instance of a recurring series
has no folders yet — worth saying the month it happens rather than thirteen years later),
**shadow axis** (= §4.3), **echo name** (`PG&E/PGE`), **mirrored inbox** (`Health/TODO/Dental` beside
`Health/Dental`), **dead weight** (pass-through folders and single-file leaves).

**What each would actually return here**, dry-run against the live profile on 2026-08-16 — worth
knowing before building, because two of them cannot be validated on this tree:

| Detector | Fires | Notes |
|---|---|---|
| **Backlog** | **10** | `Health/Dental/2025`, `Work/HPE/Compensation/Benefits/2026`, … All plausible, all computable from `fileCount` and `subfolderCount`, which the profile already carries. Best value of the five. |
| **Echo name** | **1** | A true hit: `Form W-2` beside `Form W2` under `Finance/US/Income Tax/2023/Forms`. **Its only fix is a merge** — which §5.4 now defines, so this lands with a two-row mapping (`Form W2 → Form W-2`) and a plan of one merge, collisions kept both. Until stage two of §5.5 lands, the card offers Export and says Apply is coming, rather than a button that dead-ends. |
| **Mirrored inbox** | **1** | Only the degenerate `Finance/US/TODO/IRS/IRS`. The 6 Aug TODO drain already cleared the class this tree had. **Build it, but do not expect to validate it here.** |
| **Shadow axis** | **5** | Under the narrow rule — see §4.3, which the audit reframed. |
| **Dead weight** | **86 / 503 / 20** | Pass-through, single-file leaves, and **wholly empty**. |

The crowding strip is the answer to *"it sees a lot of folders"*: three counts above the findings,
each a filter into a list. **Crowding is a property of the scope, not a finding** — always non-zero
on a real tree — so it never takes a badge. The counts are **scope-dependent**, which is the one
place this item can quietly put an O(folders) sweep behind a scroll: `structureFindings` is memoised
precisely because the overview asks for it on every render, so every detector here joins that cache
and the cache key grows a scope.

**Backlog is the one detector whose fix is cheap, safe and recurring — so it gets an Apply of its
own, and it is the highest-value addition of the review.** The finding today is *the newest year
has files and no folders*; the natural action is not a restructure but a **scaffold**: *Set up
`Health/Dental/2025` like its siblings* creates the folders the family's vouched vocabulary expects
(`Claims/`, `Statements/`, …) as `create-dir` operations and nothing else — no file moves, nothing
to undo but empty folders — and then **hands the flat files to To File scoped to that folder**,
which is the surface that already makes per-file judgements with a verdict, a shortlist and Undo.
Where the family has no vouched scheme (all drift), there is nothing to scaffold from and the card
says so. This is the operation a person would use *every year* rather than once a decade, it is
the "worth saying the month it happens" case from `ROADMAP.md` 20 made actionable, and it is what
lets 5.0 be useful on a tree that has already been hand-tidied. It shares §5.4's manifest
(`create-dir` only) and §5.5's landing (no removal step), so it costs a card and a hand-off, not a
second machine.

**Only sub-classes with a stated rule get an Apply.** The 503 single-file leaves get a number and
nothing else: a folder can look like debt and be a destination waiting for its next file, and
nothing in its own shape separates the two. That is the same mistake that had
`Supporting Documents/Resume` and `Supporting Docs/HPE/Payslips` put back on 6 Aug. **Pass-through
folders (86) are also report-only in 5.0**: hoisting `A/B/…` to `A/…` is a move of everything
under `B` and a rename of every path in the profile, corpus and memory beneath it, for a defect
that costs one click in a column view. Say the number, offer the list, offer no button.

**The 20 wholly empty folders — decided.** They appear as the third filter of the crowding strip
and, unlike the other two, they get §5.5's removal sheet — the *same* sheet, with the same split:
an empty **date bucket** (`2019`, `2013-2014`, `01. Jan 2019`) is debt and is ticked; an empty
**category** is a destination and is listed unticked with its path printed inline. Nothing is
deleted; folders go to the Trash; ⌘Z and the ledger cover it like any landing. That is the 6 Aug
rule applied to the folders that day's scope-bug taught it on, and it is the cheapest real win in
this item.

**Proof:** each detector gets a synthetic fixture that fires and a control that does not, *and* is
run against the in-repo flagship/backlog fixtures lifted from the live profile with the numbers
above pinned (`10`, `1`, `1`, `5`, `86 / 503 / 20`) — a detector whose count moves on the fixture
moves for a reason someone has to write down. The scaffold card's `create-dir` list equals the
vouched vocabulary minus what the newest member already has; the To File hand-off opens scoped to
that folder and to nothing wider.

### 5.3 Ask findings — medium

A finding with **no Apply button**, for a disagreement no fact in the tree settles —
`Health/Kaiser - PG&E` versus `Health/Medical/Kaiser`, coverage-through-an-employer versus care
records. Two answers and a *don't ask again*; the answer is remembered and never asked again,
including after a re-survey.

**The answer goes in its own store, not in the profile** — corrected by the audit. It was specified
to land in the profile's `folderSemantics`, and that cannot work twice over: **nothing decodes that
section** (`FolderProfile` reads five fields; `folderSemantics` has no Swift reader outside two
comments), and the profile's only write path refuses to write over an existing profile by design.
Its three live entries are hand-authored doctrine with a prose *why* and rules in English, which
machine-written answers should not be mixed into even if the file were writable.

So: **a small app-owned store, keyed on detector × folder path.** `PeopleStore`, `PersonTagStore`,
`StorageLensStore` and `FilingVerdictCache` are four existing precedents for exactly this — one
per-profile file, written atomically. That key is also the identity *never suggest this again* needs
(`ROADMAP.md` 20) and the suppression key §5.5 needs, so it is one decision serving three items.

**It therefore no longer needs the profile write path**, and stops being the item that unlocks the
ones after it. What it still needs is the **generation bump**: `structureFindings` is memoised and
dropped only by `filingFolderProfile`'s `didSet`, so the cache gains a second trigger or the lens
re-asks what it was just told. Schedule it on its own merits — which are modest today, since this
tree holds one Ask-shaped disagreement.

**Not release-gating for 5.0.** The store it needs ships with §5.0 regardless (the ledger and the
suppressions are release-gating; the `answers` section is a second key in the same file). If the
sheet and the one detector that asks are not done when the rest is, 5.0 ships without them and
loses one finding on this tree. Fig. 32 stays as the design.

### 5.4 Choose → map → manifest, with Export — large

The whole plan surface, ending in a file that §5.5 then lands. Figs. 23–24 — **with one correction
to both: the mapping editor no longer refuses merges.**

**Merges are designed in — decided.** Laid out in full, **the flagship family cannot converge
without one, in either direction**: 2013's `Federal Tax` · `State Tax (California)` · `State Tax
(North Carolina)` has no one-to-one image in 2016–2022's `Forms` · `Reference` · `Refund` ·
`Transcripts`, and the reverse has none in 2013's. Nor is it hypothetical: the 6 Aug run **fed 3
destinations from two sources each**, and §5.2's one real echo-name hit (`Form W-2` / `Form W2`) is
a merge too. So it is an operation, and this is its definition:

- **The mapping is per family: *source child name → target child name*, one row per distinct
  source name across every member** (24 rows on the flagship family). It is edited once and applied
  to every member; per member the operations are *derived*, never typed:
  - one source → a target absent in that member: **`rename-dir`** (atomic, carries its files);
  - N sources → one target absent in that member: **rename the source with the most files, merge the
    rest into it** — the fewest moves that reach the shape;
  - N sources → a target already present in that member: **merge all N into it**;
  - a target with no source in that member: **nothing**, unless the plan is a §5.2 scaffold, in
    which case `create-dir`;
  - a source mapped to *keep*: **`keep`**, listed (invariant 4).
  - **Ordering inside a member is derived too**: a folder is vacated before its name is filled
    (`Forms → Tax Records` runs before `Federal Tax → Forms`), a two-way swap goes through a
    temporary name, and a case-only rename (`forms → Forms`) takes the two-step `safeMoveItem`
    already has for case-insensitive volumes. The 6 Aug log never needed any of these; the flagship
    mapping will, and a manifest that lists them in the wrong order fails at the second action.
- **A merge is `move-file` per file plus `move-dir` per subfolder into the target, followed by the
  source becoming eligible for the removal step** — never a `move-dir` of the source *onto* the
  target, which would nest it. Apply sees only primitives; the sheet groups them as *merge `Federal
  Tax` into `Forms` (12 files, 1 folder)*.
- **Collision policy.** A file whose name exists at the target is moved under a unique name by
  `generateUniqueURL` — **keep both, never overwrite, and count it**: the ledger has a line *N name
  collisions, both kept*. If the two are the same document that is a Duplicates question, not this
  surface's; it may say so, it may not decide. A *subfolder* whose name exists at the target merges
  one level down by the same rules; deeper than that the subfolder is `keep` and reported.
- **The ledger separates what a merge does from what a rename does**: *files moved* (merges) from
  *files carried* (renames), *folders renamed* from *folders emptied*. The "8 renames · 0 moved ·
  92 carried · 5 kept" that Fig. 24 draws for the flagship family **predates merges and is not the
  number** — derive it from the mapping; do not paste it.

**Whether the manifest can also be replayed against the profile — decided (re-derive; see the
decisions block and §5.5).** What is still this item's is that the manifest be *replayable* at all:
an ordered list of typed path operations, each with a `src` and `dst`, so that §5.5 can run it
forwards on the disk, run it onto the corpus, memory and store keys, and derive its inverse
mechanically.

1. **Choose the target shape — nothing pre-selected.** The schemes found, labelled by what they are
   (*the largest group*, *the most recent*), with **Name it myself among them, not behind them**.
   Neither recency nor majority is the authority: the 6 Aug fix went **both ways at once**, because
   H-1B is filed on Form I-129 (a *petition*) and H-4 / H-4 EAD on I-539 / I-765 (*applications*) —
   a fact that exists nowhere in the tree.
   **Derive *the most recent* from the members' year axis, never from scheme order** *(audit)*. On
   the flagship family the most recent *vouched* scheme is `IRS Docs - 2023, IRS Docs - 2024`, while
   the genuinely newest folders — 2023, 2024, 2025 — are all unvouched drift sharing no scheme at
   all. A label taken from scheme order points at neither. And when the newest members are drift,
   **say there is no current shape**: that is a true and useful answer, and it is the finding rather
   than a failure to produce one.
2. **Tabulate the family group first** where parallel families share a vocabulary. Fixing H-4 alone
   would have left it disagreeing with its two siblings; laid out as a table the cause was visible
   in one glance (each filing lands flat and is foldered later).
3. **The mapping editor** — one row per distinct source folder name across the family, target
   dropdown, **default keep**, never a guessed mapping. This is where the leverage is: edited once,
   applied to every member. Two sources onto one target is a **merge** and the row says so in the
   margin (*merges into `Forms` in 3 members*), so the cost of a choice is visible where it is made.
   **Size it honestly:** the flagship family has **24 distinct child names across 17 members**, not
   the nine the mockup draws, and several are near-duplicates a dropdown alone cannot resolve
   (`Payment` / `Payments`, `Forms` / `Tax Returns`). **The mapping is one level deep**: it names a
   member's direct children; whatever is inside a renamed folder is carried, and whatever is inside
   a merged one moves with it. It does not reach into `2016/Forms/W-2/`.
4. **The manifest** — the 6 Aug log's schema, extended, and versioned so a reader can tell them
   apart. Header: `schemaVersion: 2`, `profileId`, `manifestId`, `createdAt`, `family`, `kind`
   (§5.0's), `mapping` (the rows as edited), `note`. Then `actions`, ordered as they run: `create-dir`
   · `rename-dir` · `move-dir` · `move-file` · `keep` · and, only in the removal step's own manifest,
   `remove-empty-dir`. Each carries `src`, `dst`, `evidence` (its written justification), and where
   it applies `filesCarried` (renames) or `bytes` and `md5` (file moves — **filled in at apply time**,
   invariant 5, never at plan time). The ledger is a pure function of `actions`.
   **Prefer the rename whenever a mapping is one folder to one folder**: it is atomic, preserves
   file identity and cannot half-finish. The 6 Aug run brought fourteen eras into agreement with
   4 renames carrying 58 files each and moving none.
   **The inverse is derived, not authored**: reverse the list, swap `src`/`dst`, turn `create-dir`
   into `remove-empty-dir` and `remove-empty-dir` into `create-dir` — and a collision-renamed file's
   inverse restores its *original* name, which is why the collision has to be recorded as its own
   fact on the action, not folded into `dst`.
5. **`Export plan…`** writes the manifest beside the profile as `restructure-<date>-<family>.json` —
   reviewable in a text editor with nothing at risk — and **saves the draft to the store** (§5.0),
   which is what makes §5.7's *Planned, not applied* survive the sheet closing and the app quitting.
   This is the natural stopping point in the build order: everything above is worth landing before
   any Apply exists.

**Proof — the 6 Aug oracle.** Reduce that day's `Immigration/Authorization` fix to a fixture (folder
names and counts only) and to a mapping (`Application → Petition` under H-1B; `Petition →
Application` under H-4 and H-4 EAD); the derived manifest must be **exactly the log's four
`rename-dir` operations with their `filesCarried`, and no `move-file`**. Then the flagship family
under a mapping that converges 2013 onto the 2016 vocabulary: the manifest carries merges, the
ledger's *files moved* is non-zero, `keep` lists `Transcripts` where the target has no slot, and a
seeded name collision surfaces as a counted line rather than a lost file. Round-trip the manifest
through its `Codable`, and check the inverse of the inverse is the original.

### 5.5 Apply — large, and the only destructive item here

Built on the rename pass's primitives (Context): `enqueueFileOperation`, `safeMoveItem`,
`generateUniqueURL`, `registerMoveUndo`, and its rule of re-listing inside the operation and applying
only what the disk still asks for. **Landed in three stages, each shippable**: renames and
`create-dir` first — the flagship's H-4-shaped cases and every §5.2 scaffold need nothing else —
then moves and merges, then the removal step. All three are in 5.0 (decisions block).

**What one landing does, in order:**

1. Refuse to start while `isVerifyAllRunning`, while any `ScanLifecycle.isRunning` (a filing scan,
   a re-survey or the duplicate scan reads the paths this is about to move), or while
   `activeFileOperationsCount > 0`; and, once started, hold `activeFileOperationsCount` so none of
   those starts underneath it. The rename pass guards only the first; this guards all three because
   it moves *folders*.
2. Write the **inverse manifest to disk first** — into the store's `applied` section with outcome
   *in progress* — so a crash mid-run leaves a reversible record (invariant 3).
3. Run the actions through `enqueueFileOperation`, **re-probing every `src` and `dst` immediately
   before each one** (invariant 5): a folder holding a file the manifest never listed is skipped and
   reported, and the rest of the plan runs (invariant 2); a `dst` that has since been taken gets
   `generateUniqueURL` and a collision line, never an overwrite; `bytes` and `md5` are recorded on
   each moved file *now*, from the disk.
4. **Verify from a different code path** (invariant 6): re-list every touched folder and reconcile
   file counts against what the manifest predicted — a verifier that agrees with the applier because
   it shares its arithmetic has proved nothing. A mismatch is reported on the card and in the log,
   and does not roll anything back on its own.
5. Register **one grouped ⌘Z** for the whole landing (`registerMoveUndo`, as the rename pass does),
   and finalise the ledger entry with counts and outcome. ⌘Z is this launch's undo; the ledger's
   inverse is every later one.
6. **Re-derive the profile** — the decision. `buildTree` over the profile root, then
   `FolderSurveyBuilder.build` with the previous profile's registry and its *entry-level*
   jurisdiction values (`US`, `IN`, `Singapore`); then the **carry-over**: for every path that exists
   in both, or maps across through this manifest's renames, copy `acceptsNewFiles`,
   `noIntakeReason` and `naming` from the old entry. Write under a fresh profile id with
   `derivedBy: "SyncCloud <version>"` and `derivedFrom: <old id>`, re-point `profiles.json`, and
   **keep the old file** — it is what Undo re-points to, and it is the last hand-built copy. Then
   set `filingFolderProfile`, whose `didSet` drops `cachedStructureFindings` — the finding is gone
   because the tree was re-read.
7. **Replay the manifest onto the keys of the corpus, the memory and the store** — a `rename-dir`
   re-prefixes every key beneath it, a `move-file` re-keys one document, a merge re-keys each file
   it moved — and write them. No page is re-read for a file that only moved. The fingerprint moves;
   the **80 cached cloud verdicts** on this machine are invalidated, and that is correct — every one
   of them names a destination as a path, and the paths just changed.
8. Log one line per landing: manifest id, family, counts, verifier result, old and new profile ids.
   The log is where the truth of an apply gets found later; make it findable by grepping the
   manifest id.

**`Undo this reorganisation`** — the button §5.7's *Applied* card carries — runs the stored inverse
through the same eight steps: guards, re-probe, verify, and re-point `profiles.json` back to the
profile recorded as `derivedFrom`, which was kept for exactly this. It survives a quit because the
inverse is on disk, and it is honest about drift: a file that has moved on since is skipped and
reported like any other unlisted file. It is not ⌘Z; both exist, and the card says which it is.

The six invariants from `ROADMAP.md` 20 are the acceptance criteria, three of them rendered on the
manifest where the decision happens (every moving file listed by full path first; the inverse plan
written to disk before the first operation; a folder holding an unlisted file skipped **and
reported**, with the rest of the plan still running) and three enforced (apply closed over the
manifest; every claim re-derived at the moment of the action, because he edits this tree while the
work is open; never hand an operation a parent folder as a proxy for its contents — that one sent
**69 files classified *keep*** to the Trash, and what caught the matching verifier bug was an
independent count from a different code path).

**Removal is a separate sheet, opt-in, scoped to folders the plan itself emptied**, and split by the
shape of the name: an empty **date bucket** is debt and is ticked; an empty **category** is a
destination and is not, with its paths printed inline because there are few enough to read. No file
is ever deleted; folders go to the Trash.

#### The gap this item used to be unable to close — and how the decision closes it

**Applying a plan made the lens's own input wrong.** The detector reads `FolderProfile.folders`,
keyed by relative path; this item renames and moves exactly those paths, and until 2026-08-16 three
independent paths confirmed there was no way back (`writeProfile` refuses over an existing profile,
the re-survey never writes one, `structureFindings` is memoised behind `filingFolderProfile`'s
`didSet`). Step 6 above is the answer: **re-derive from a fresh walk, carry two judgement fields
forward, write a new id, keep the old file.** Replaying the manifest onto the profile was the
alternative and it was rejected for one reason — replay is a model of the disk, and this tree is
edited while work is open; a walk *is* the disk.

**What that costs, accepted in the open** (measured on this machine's profile, 2026-08-16):

- ~0.2–0.3% of hand judgements per field are replaced by the walk's — roughly 6–9 folders each on
  `role`, `anchors`, `person`. `acceptsNewFiles` would have lost 6 (45 hand refusals against the 39
  inboxes the walk finds) — **that is why it is carried over**, with its `noIntakeReason`.
- `naming` on 2,534 entries would go — read by nothing outside tests today, **carried over anyway**,
  because the day the rename pass starts reading it must not be the day it silently stopped existing.
- The hand-authored doctrine sections (`folderSemantics` 3, `conventions` 3, `structuralRules` 4,
  `canonicalPaths` 5, the top-level `axes` prose) are **not** in the derived file. Nothing decodes
  them; the file that carries them stays on disk as `derivedFrom`; the active profile no longer
  carries prose. Accepted.
- The jurisdiction set is taken from the *entries*, not the header: the header says `US, IN`; the
  entries carry **`Singapore` on 10 folders**. Take the header and the tree loses an axis value.
- A new mutable write path where there was an immutable file. Provenance in the file, the old copy
  kept, Undo re-pointing back — those are the mitigations, and they are all in step 6.

**Silently keeping a stale answer was the one option that was never available**, because it is
indistinguishable on screen from an apply that did nothing; that is still true, and it is why
step 6 is not optional in stage one.

**Proof:** an apply against a temporary tree, seeded from the flagship fixture, in which a listed
file is deleted and an unlisted one added *between* plan and apply — the unlisted folder is skipped
and named, the rest lands, the ledger's counts match a `find` over the result; ⌘Z restores a
byte-identical tree (hash it, do not size it — 6 Aug); the on-disk inverse restores it after the
manager is thrown away and rebuilt; after the landing the derived profile has **no** finding for
the family, carries the old `noIntakeReason` for a surviving refused folder **and for one that was
renamed**, and records `Singapore`; the corpus key for a moved file changed and its stamp did not;
the fingerprint moved. And the guard: an apply started while a filing scan runs is refused with a
sentence, not queued.

### 5.6 Refine with Claude — small once §5.4 exists

**On the mapping, never on the apply.** The plan is derived mechanically from the mapping, so by
then there is no judgement left; the judgement is *what should these folders be called* — the one
question the tree cannot answer and a model can.

Reuses `LensWorkspaceView.refineButton`'s **pattern**: the invitation when no key is stored,
`Ask Opus about N folder names` when one is, and the existing spend pre-flight. Not the function —
it is typed to `[FilingSuggestion]` and gated on `filingCloudRefineAvailable` ＋
`canRefineFilingSuggestions`, so "reuse" here means the same slot, the same words and the same
billing sentence over a different payload. Three things it adds:

- **An itemised payload disclosure** — folder paths and candidate vocabularies always; *up to 5 file
  names per folder* as a **toggle** (that is the evidence that settled I-129 vs I-539); file
  contents never.
- **A row-by-row diff against the user's mapping**, each proposal carrying a written justification.
  **`declined` must be a first-class rendered outcome** — a model that answers every row is guessing
  on some of them. A proposal that *reverses* another is shown adjacent and labelled, or a reviewer
  reads it as a bug.
- **No path to the disk that skips the manifest.** Accepting a row edits the mapping; the plan is
  re-derived and reviewed exactly as before.

Deliberately last: a paid pass must not be the only way to get a good answer.

### 5.7 The two states this adds — no work of its own, but they need their own words

The lens's existing three states are distinct on purpose and **none borrows another's words** — *no
profile* means the detectors have nothing to read, *no findings* means they ran and the tree agrees,
a list means it does not. Two more arrive with the work above, and they ship with §5.1 and §5.5
respectively rather than as an item:

- **Planned, not applied.** The finding card carries the plan's ledger inline and its trigger reads
  `Review N operations`. A drafted plan survives the sheet closing **and a re-survey** — it lives in
  the store's `drafts`, keyed on `kind × family`, and an Apply of *another* plan replays its manifest
  onto that key like any other (§5.0). What it does not survive is its family ceasing to exist,
  which the card says.
- **Applied.** *N folders renamed, N files moved, N carried, N collisions kept*, plus `Undo this
  reorganisation` backed by the inverse in the ledger. **The finding is gone because the tree was
  re-read** — §5.5 step 6 re-derives the profile and `filingFolderProfile`'s `didSet` drops the
  cache — never because it was marked done. Those are different states and only one of them is
  true, and with the decision taken the true one is now buildable. If step 6 fails (the walk was
  refused, the write failed) the card says *applied; the survey could not be refreshed* and keeps
  the finding — a third sentence, not a borrowed one.
- **Undone.** A fourth, from the ledger: the inverse ran, the profile was re-pointed to
  `derivedFrom`, and the finding is back because it is true again. It shares the Applied card's
  shape with the verbs reversed and never pretends the tree was untouched: a file that had moved on
  and was skipped is named.

### 5.8 Where the code goes — so the first branch does not have to decide it

| Piece | Module / file | Notes |
|---|---|---|
| `FindingKind`, the composite `id`, the seven detectors | `Sync` — `StructureDivergence.swift` grows a sibling per detector (`StructureBacklog.swift`, `StructureDeadWeight.swift`, …) behind one `StructureDetectors.run(profile:scope:)` | `structureFindings` keeps its memo; the cache key gains the scope. Pure functions of the profile, like the one that ships. |
| `RestructureStore` (§5.0) | `Sync` — `RestructureStore.swift`, one file, `Codable`, atomic write, `schemaVersion` | Loaded where `PeopleStore` is loaded, in `MacApp/SyncCloudApp.swift`'s profile block. |
| `RestructureMapping`, `RestructureManifest`, `RestructureLedger` (§5.4) | `Sync` — `RestructurePlan.swift` | Mapping → manifest is a pure function; the ledger is a pure function of the manifest; the inverse is a pure function of the manifest. All three testable with no disk. |
| Apply, Undo, verify, re-derive, replay (§5.5) | `Sync` — `FileSyncManager+Restructure.swift`, beside `+FilingRename` | Uses the primitives named in Context; adds `FilingProfileStore.writeDerivedProfile(_:replacing:)` (new id, provenance, re-point, old kept) and `FolderProfile.derivedBy` / `derivedFrom` (optional, so every existing file decodes). |
| The cards, the plan sheet, the mapping editor, the removal sheet, the ledger card | `FileExplorer` — `RestructureLens.swift` (cards), `RestructurePlanSheet.swift`, `RestructureRemovalSheet.swift` | Same lens, same `OrganizeScope`; the sheet is modal over the lens. Extracted rules (`cleanTitle`, `revealTitle`, `surveyNoteText`) already show the pattern: pure static text rules, tested without a view. |
| Host wiring | `MacApp/ContentView…` — `onPlan`, `onApply`, `onUndo`, `onScaffold` beside `onReveal` | `MacApp` is compiled only by CI's second step and holds no unit tests of its own; keep every rule out of it and on the types. |
| Fixtures | `Modules/Sync/Tests/Sync/Fixtures/restructure-flagship.json`, `restructure-immigration-oracle.json` | Folder names and counts lifted from the live profile and the 6 Aug log; **no file names, no content**. In-repo, so CI runs them — the machine-pinned ground-truth suite is the wrong place for a release gate. |

---

## 6. The first survey, run in the background

**Why:** the router reads a folder profile the app has never been able to create. It has only ever
come from an out-of-repo script, so a machine that has never run one gets **no routing at all** —
and the guard that proves it is three lines:

```swift
guard let profileId = filingMemory?.profileId ?? filingFolderProfile?.profileId else {
    Logger.shared.info("No filing profile on this machine — nothing to re-survey")
    return .none
}
```

`Modules/Sync/Sources/Sync/FileSyncManager+FilingSurvey.swift:74`. The re-survey refreshes the half
the app owns and cannot produce the half it does not. §4.2 shipped the derivation and the write;
this is the **run**.

**Two halves, and 5.0 builds one of them for another reason.** Read carefully, this item was
conflating two things a fresh machine lacks. The **folder profile** is a *walk*: names, counts, the
roster and the jurisdiction values — `buildTree` then `FolderSurveyBuilder.build`, seconds, no PDF
opened — and it is all Restructure reads. The **document survey** — the corpus and the memory the
*router* wants — is the hours-long, PDFKit-serial, checkpointed pass everything below describes.
§5.5 step 6 ships the first half as an app code path (walk → build → write under a new id → re-point),
so after 5.0 what a fresh machine lacks for **Restructure** is the setup dialog's three answers and
a button, and what it lacks for **routing** is this whole section. When §6 is picked up its first
sheet should offer the walk on its own — *Learn your folders* — and the document survey as the
second, longer step, because a lens that can answer in seconds should not wait forty minutes for a
corpus it does not read. Not scheduled for 5.0 (decisions block); shaped here so it is not designed
twice.

**What it is:** an OS-indexer-shaped pass. The user agrees once, in a dialog, and then it runs in the
background — non-blocking, resumable across quits, throttled behind their own work. **It is
acceptable for this to take a long time; it is not acceptable for it to make the app feel slow.**
Every constraint below is that sentence taken literally.

### The setup dialog — Fig. 25

Asks only what a walk cannot compute, and nothing else:

- **The tree root.** What the profile records as the tree it describes. `FolderSurveyBuilder.build`
  takes it as a parameter, never touches it on disk and never parses it, so this is a plain folder
  choice with no inference behind it.
- **The household roster.** The person axis and the `person-bucket` role are read off
  `PersonRegistry`, and with no roster both are simply absent — no folder is misattributed for want
  of one, but none is attributed either. Reuses the People list Settings already ships
  (`PeopleSettingsTab` / `PeopleList`, `Modules/Settings/Sources/Settings/SettingsView.swift:2255`)
  and the `people.json` `PeopleStore` already writes. No second roster UI, no second file.
- **The jurisdiction values — inferred and confirmed.** `JurisdictionCandidates.propose` supplies
  the list *with its evidence*: the distinct parents each value appears under, and the number of
  folders it would change. The user ticks the real ones. **Nothing is pre-ticked** — the rule is
  tuned to offer `HPE` rather than to be right about it — and there is a free-text row to **add**
  one, because that is the only way `Singapore` can ever be recorded (§4.2).

Fig. 25 is that dialog as a sheet over Organize: the tree at the top and the household under it,
both stated rather than asked, each with a quiet *Change…* / *Edit…* — they are confirmations of
what the app already holds. Then the one thing it cannot decide alone, under the heading *Places*:
the proposals as tick chips, `US` and `IN` ticked and `HPE`, `IT` and `PRD` not, with an *Add…*
for the value the rule cannot reach. Pre-ticking is the point — the user is correcting a list, not
composing one, and the line beneath says what leaving one unticked costs, which is nothing but the
axis. Two buttons: *Not now*, and *Start in background*, which is the whole bargain in three words.

### What the code decides about how it runs

Read out of the code on **2026-08-13**.

| Fact | Where | Consequence |
|---|---|---|
| **Every PDFKit parse in the process takes one lane.** `PDFKitSerialAccess` is a single serial `DispatchQueue`, shared by Filing's page-1 reader and the duplicate scan's fingerprint. | `Modules/Sync/Sources/Sync/PDFKitSerialAccess.swift:18–20`; `MacApp/ContentSignalExtractor.swift:192` | **Raising the survey's concurrency buys nothing on the PDF half** — the extra workers queue. Budget it as serial and spend the effort on not reading anything twice. What makes serial affordable is the **early stop**: this reader stops at 600 characters of page 1 (`enoughFromOnePage`), and on a full-tree cold pass that is 78 s serial against 39 s six-at-a-time, where reading all five pages — as `v2.x` still does — is 198 s serial against 106 s. The concurrency is what is unavailable; the early stop is what pays for losing it. |
| **Driving PDFKit concurrently changes the text it returns.** Through this reader over a real 10,286-document tree, six at a time, **0.83% of documents came back with different text than a serial pass**, and concurrent passes disagreed with each other. One mortgage statement: 30 serial reads produced **one** text; adding 180 concurrent reads produced **18 distinct texts**, one of them 1,341 characters against 2,616, and **7 different first-400-character windows** among them. Two *serial* queues race the same way — **4.5–6.3% of documents flapped** with a second serial queue reading alongside, against 0% with the lane to itself. | `MacApp/ContentSignalExtractor.swift:166–191`; `PDFKitSerialAccess.swift:8–10` | The survey takes the lane; it never opens a queue of its own. A corpus built off unstable text is a corpus whose tokens differ between runs, under a verdict key that cannot see the question changed. Non-PDF work (Vision, plain text) stays on `ContentSignalExtractor.workQueue` and is where concurrency is still worth having. |
| **`FileSyncManager` is `@MainActor`.** | `Modules/Sync/Sources/Sync/FileSyncManager.swift:8` | The three expensive steps must be **hoisted off it** — `FilingSurvey.merge`, `FilingSurvey.buildMemory` and `FilingSurveyStore.write`, plus `FolderSurveyBuilder.build`, which is already pure of `FileManager`, `Date()` and defaults precisely so it can run detached. Only publication (`filingMemory`, `filingArtifactFingerprint`, the lifecycle's status) comes back to the actor. |
| **`surveyedRegion` is derived from the corpus, and `documentsToRead` scopes on it.** The region is every ancestor of every surveyed document, closed upwards; `documentsToRead` skips anything outside it. Empty means unscoped, which is the only sensible first run. | `Modules/Sync/Sources/Sync/FilingSurvey.swift:172–186`, `:205–213` | **The sharpest constraint here.** A checkpointed *partial* corpus makes the region cover only what has been read, so a resumed survey **skips the rest of the tree permanently** and reports "0 documents read" — indistinguishable from a settled tree. The same failure is already written down one file over for the empty-tree case (`FileSyncManager+FilingSurvey.swift:96–100`). So progress is checkpointed to a **separate file that `FilingSurveyStore.corpus(id:in:)` never reads**, and `filing-corpus.json` is written once, whole, at the end. `surveyedRegion` stays a pure function of a complete corpus. |
| **The memory is a full rebuild, every time, and its bytes are hashed into the fingerprint.** IDF is corpus-wide: a partial rebuild weighs a new folder's anchors on a different denominator from its neighbours'. And `write` skips an unchanged memory on purpose, because the memory is part of `FilingProfileStore.fingerprint(id:in:)`, which is part of every cached classification's key. | `FilingSurvey.swift:15–17`; `FilingSurveyStore.swift:41–46`; `FileSyncManager+FilingSurvey.swift:195` | **Write the memory once, at the end, from the full corpus.** A mid-survey write would not merely be wasted work: it moves `filingArtifactFingerprint` and throws away every cached verdict — once per checkpoint. |
| **Anti-clobber already has a backstop, and it is not the check.** `writeProfile` throws `WriteRefusal.profileExists` and re-points `profiles.json` only when nothing is active; `resurveyFilingMemory` refuses to run twice over itself. | `FilingProfileStore.swift` (`writeProfile`); `FileSyncManager+FilingSurvey.swift:63` | Refuse to **start** where a profile or a memory exists — a survey that runs for an hour and is refused at the store has wasted the hour. Mint a fresh profile id for the run. Keep the store's refusal anyway: it is what makes the check's absence a bug rather than a disaster. |
| **The signals to throttle on already exist.** `isVerifyAllRunning` and `activeFileOperationsCount` on the manager, and six `ScanLifecycle.isRunning` flags — duplicates, storage lens, names, filing, filing survey, automations dry run. | `FileSyncManager.swift:1565`, `:1624`, and `:367`, `:415`, `:448`, `:493`, `:504`, `:678` | Yield to all of them, and **pause rather than cancel** — the corpus is checkpointed, so resuming costs nothing and cancelling costs everything already read. Note what does *not* exist: `ScanLifecycle` has `isRunning`, `status` and `hasCompleted` and **no paused state**, so paused is either a status string or the one field this adds. Thermal and low-power are genuinely new surface — **nothing in the repo reads `ProcessInfo.thermalState` or `isLowPowerModeEnabled`** (grepped 2026-08-13, zero hits). |

Fig. 26 is the running state, and it is drawn from Organize with a lens open rather than from the
setup card: the pane navigates, the lens is usable, nothing is disabled and no sheet is up. The
survey reports where every other pass reports — a status line reading *Learning your folders*, a
count of documents read against the total, and *Pause · Stop*. Fig. 27 is the same frame with the
duplicate scan running: the count frozen at what it reached, the line replaced by *Paused while
Duplicates scans*, and *Resumes on its own · Resume now*. That pairing is the honest one to
illustrate — the survey and the duplicate scan are the two heavy readers of the same serial PDFKit
lane, so they would queue into each other and the user's scan is the one that must win. It yields to
`isVerifyAllRunning` and `activeFileOperationsCount` the same way. The two figures differ only in
that strip, deliberately — a paused survey must not look like a stalled one.

### What it costs, measured on the reference tree

A first survey is the unscoped one — with no corpus and no memory the region is empty and
`isInScope` admits everything, which is the only thing it could sensibly do — so it reads **page 1
of ~11,019 files**. That is `FilingSurvey.readableExtensions` (`pdf`, `txt`, `csv`, `jpg`, `jpeg`,
`png`) applied to the reference tree, and it is **93.1% of what the offline builder read**. The
other **816** are Office formats — `.docx`, `.pptx`, `.xlsx`, which go through a helper this app
does not carry — and that is the **largest single loss in a derived survey**: it leaves **143 of
2,306 learned folders with no content at all**. The list is deliberately no *wider* than the
generator's either; adding `.md` looked free and would have queued 1,700 markdown files into the
same IDF.

**~13.8% of reads yield nothing** and are stamped blank so they are never opened again. That blank
entry is not a wasted row; it is the only thing that stops the next survey paying for the same file.

Fig. 28 is the payoff, at one folder, before and after: on the left the shipping `noProfileState`
setup card, samples and all, with **no trigger** — *this tree has no folder survey yet, so there is
nothing to compare* — and on the right the same folder's findings list once the survey has landed.
Fig. 29 is the completion summary: folders profiled, documents read, documents that yielded nothing,
the jurisdiction values that were confirmed, and — stated plainly — the Office formats that were not
read and the folders left without content, because a summary that reports only what it managed reads
as complete when it is not.

### Size — large

Two new files in `Sync` (the run's state machine and its checkpoint, which is the file
`corpus(id:in:)` must never read), one setup sheet in `FileExplorer`, and wiring in
`FileSyncManager`, `RestructureLens` and `ScanLifecycle`. ~900 lines, and **none of it is
derivation** — that shipped. The state machine is the work: pause, resume across a quit, and a
checkpoint that cannot be mistaken for a corpus.

---


## Order

**§§4–6 are not three projects:** they are the storage under one lens, the plan surface that lens
was shipped without, and the survey without which it has nothing to read — so they run in that
dependency's order. Carried over from `ROADMAP_V4.md` with its §3 and §1 steps removed; those items
stayed with the 4.x line and are not blocked on anything here, nor anything here on them.

**The build order, under the decisions block.** 1–5 are the release; 6 ships if it is done when 5
is; 7 is after the tag.

1. **§5.0** — the kind in `StructureFinding.id` and `restructure.json` with its four sections.
   Small, and everything below keys on it; the stale *two divergent families* in
   `StructureDivergence`'s doc goes in the same commit.
2. **§5.1 + §5.2** — the scoped read, the crowding strip with all three filters, the remaining
   detectors one at a time (**§4.3 is one of them**), and the **backlog scaffold** with its To File
   hand-off. Pure reporting off a survey already in memory, plus the one Apply that creates and
   never moves — which makes it the right first landing to prove `enqueueFileOperation`, the ledger
   and ⌘Z on before anything destructive exists.
3. **§4.1, last surveyed** — small, self-contained, and the only item on this page that improves a
   screen v4.0 ships. Schedulable against anything above or below it.
4. **§5.4 up to `Export plan…`** — the whole plan surface, merges included, with the 6 Aug oracle
   test green before the sheet is wired to anything that writes. Drafts persist from here.
5. **§5.5 in its three stages** — renames and `create-dir`, then moves and merges, then the removal
   step (which also takes the 20 pre-existing empties from §5.2's filter). Every stage ends with
   step 6 — re-derive — and step 7 — replay onto the corpus, memory and store; the first stage is
   the one that proves those two on the real tree. `Undo this reorganisation` ships with stage one.
6. **§5.6, Claude on the mapping** — last of the release, deliberately; a paid pass must not be the
   only way to get a good answer. **§5.3, Ask findings**, sits beside it: not release-gating, its
   store already exists, one finding on this tree.
7. **§6, the first survey** — after the tag, and smaller than it was: its profile half is §5.5 step
   6 with a dialog in front (see §6, "Two halves"). It cannot fire on this machine, which has a
   profile; nothing in 1–6 is blocked on it.

**What "ready for implementation" means for each of 1–5**: the item names its files, its store
key, its proof, and the number it will print — and where the number was measured rather than
designed, the measurement is dated. An item that fails that bar goes back to this file before it
goes to a branch.

---

## Open questions

- **§6: stopgap or replacement?** Settled further than it was: the derivation is not a degraded
  stopgap — role, anchors and axes agree at .997–1.000 and Restructure cannot tell the two profiles
  apart. What stays hand-built is `naming`, `folderSemantics` and the jurisdiction *vocabulary*, and
  the last of those is answered by asking rather than by mining. The open half is whether that is
  enough to stop maintaining the offline builder at all, which only a second tree can answer.
- **§6: should the survey offer itself unprompted on a large unsurveyed tree?** A machine with no
  profile gets no routing and no Restructure, and nothing on screen says why until someone opens the
  lens. Against that: an hours-long background pass that the user did not ask for is exactly the
  thing the *"never make the app feel slow"* rule exists to protect, and the dialog needs three
  answers it cannot guess. Recommendation: offer it in the lens and in Organize's overview, never
  start it.
- **§6: what should the Organize overview ledger count while a survey is running?** Making
  Restructure runnable changes `countedLenses` and `pendingPasses`
  (`Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift:418`, `:468`), and a lens that
  is *going to be* runnable in forty minutes is neither of the two states those were written for. A
  badge that appears mid-survey and a pass card that offers a button pointing at an unfinished
  answer are both worse than counting nothing until the survey lands.
- ~~**§5.4: merges.**~~ **Decided 2026-08-16: designed in** — see the decisions block and §5.4's
  definition. Struck rather than deleted because the measurement that forced it is the useful part:
  the flagship family cannot converge without one in either direction, the 6 Aug run performed
  three, and §5.2's one real echo-name hit is a merge.
- ~~**§5.4 / §5.5: can an applied manifest be replayed against the profile?**~~ **Decided
  2026-08-16: the profile is re-derived from a walk after every landing, two judgement fields
  carried over, old file kept, new id, `profiles.json` re-pointed** — §5.5 step 6, with the costs
  written down under it. Replay was rejected because a model of the disk drifts from a tree that is
  edited while work is open; the manifest *is* replayed, but onto the corpus, memory and store keys,
  where there is nothing to walk.
- ~~**§5.4: does a drafted plan survive a re-survey?**~~ **Decided: yes** — it lives in
  `restructure.json`'s `drafts`, keyed on `kind × family`, and the profile can be swapped under it.
  The mockups' *does not survive a re-survey* line is stale; §5.7 carries the new sentence.
- **§5.2: does the crowding strip render in the clean state?** *The tree agrees with itself* and
  *this scope has 86 pass-through folders* are both true at once; the mockups show both. **Leaning
  yes**: the seal answers *shape*, the strip answers *crowding*, and a strip that vanished on a clean
  tree would make the empties filter — the one with a Trash path — unreachable exactly when it is
  the only thing left to do. Decide by rendering it and reading it back, not by argument.
- ~~**§5.2: what happens to the 20 already-empty folders?**~~ **Decided: the third crowding filter,
  §5.5's removal sheet, the 6 Aug date-bucket / category split** — §5.2. Nothing is pre-ticked
  that has a category name; nothing is deleted; folders go to the Trash.
- **§5.5: what does the verifier do on a mismatch?** It reports and does not roll back on its own,
  because a verifier that says everything is broken is usually itself broken (invariant 6, from the
  day it happened). Whether a mismatch should *offer* the inverse on the card, one click away, is
  open — leaning yes, since the inverse is already on disk and offering it costs nothing but a
  button; deciding it needs the first real mismatch to look at.
- **§5.2: should the backlog scaffold create the folders, or only offer To File a plan of them?**
  Written above as *create then hand off*, because an empty scaffold is what the family's other
  members already look like and it is the cheapest possible landing to undo. The alternative — To
  File proposes the destinations without them existing yet — needs To File to create folders on
  accept, which it does not do today. Settle it when the hand-off is wired.
