# Vault — technical debt brief

A prompt for the session that pays this down. It covers what is inside the Vault: storage, the data
model, the model and panel code, the readers, logging, tests, privacy and security. What the user sees
and the feature roadmap (VF…, VB…, VQ…) are in the mockup artifact,
<https://claude.ai/code/artifact/60d12ecd-c5f3-4945-a098-2f0a9fc8c2a4>, and ROADMAP item 25.

**The goal:** when this list is worked through, the Vault's code is the best implementation in the most
efficient way, **with no lost function, no change in what the user sees or does, and no change to the
visual design.** Internals only. An item that would change behaviour says **owner's call**: ask before
doing it, or do only its internal half.

First written at `3f953608b` (2026-11-20). **Re-reviewed end to end at `0409895c8` (2026-11-21)**, after
18 Vault commits (VF4, VF6, VF8, VF9, VF12, VF21, VF22 and three rounds of reader fixes): five reviewers
by area (store and security, model, panel, readers, tests), each finding re-read at the cited lines, plus
what the three sessions working on the Vault said they changed, plan and left behind. Line numbers are at
`0409895c8`; re-find by symbol. **Refreshed at `710b5aaa3` (2026-11-21)** after nine more Vault commits
(Read from This Copy, the Updating line, the restore fixes, the whole-card wash, People's tidier
section, name roles): one reviewer on the new code, one on how files are picked, each finding re-read;
new items VT99–VT107; VT108 came from a third review (2026-11-21). IDs (`VT…`) are stable: never renumber, cite them in commit bodies. Next free:
**VT109** (VT61 and VT62 were never used). **Checked** means the lines were read and the claim holds; **plausible** means inferred.

## Read first

- `CLAUDE.md`, `COMMIT.md`, and the memory file `testing-laws.md`.
- **The Vault has never shipped** (first commit `e4990837e`, 2026-11-18, after `v7.1`). The only sealed
  files in existence are the owner's, so a one-time format migration is cheap now and expensive after the
  next release cut.
- **Never log, print or assert on a number in full.** Bump `VaultReading.version` whenever a reader's
  output changes; it raises the Read Again banner.
- **Proof for every refactor** (`CLAUDE.md` §5). For the Vault, that means the same rows, the same sealed
  JSON (decrypted and key-sorted) and the same log lines on a fixture folder, before and after. For a
  reader, add the count-only hash harness on the owner's folder: memory
  `vault-reader-changes-check-on-real-papers` (the consent dialog and Vision's missing model are its
  traps).
- **Do not split a file because it is long.** Every item below names a capability, a bug, a cost or a
  missing test as its reason.

### Other work on the Vault (2026-11-21)

- **Everything in flight has landed** (`16beb2712`, `d1e29f8c8`, `5e33b3c47`, `b3e4e3009`,
  `774f315bd`, `28fa32dcb`, `29517d0ef`, `ac5eb5539`, `710b5aaa3`), and no other session has Vault work
  open. "Go Back to an Earlier Save" (VF6) can now read `VaultStore.backups`; VF7 (key tied to Touch ID,
  which is VT31) is deferred by the owner.

## Order

1. ~~Wait for the branches in flight to land.~~ Done.
2. ~~**Safety net:** VT55, VT20, VT21, VT30, VT24.~~ Done (see Closed). A format change from here on
   adds a fixture beside the old ones (`VaultFormatTests`, `VAULT_WRITE_FORMAT_FILES=1`).
3. ~~**Internal bugs:** VT58, VT52, VT54, VT73 (a, c).~~ Done in batch 3. VT100, VT108 and VT73 (b) are the owner's call.
4. ~~**Efficiency.**~~ Done in batches 4 and 6, but for VT10's held key and `keyState()`, which go with VT31,
   and VT85, measured out.
5. **Tests and logging:** batch 5 did VT94, VT105, VT95, VT26, VT96, VT97, VT71, VT28 and half of VT29.
   Left: VT98, VT29's lock table, VT27, VT22, VT23, VT25.
6. **Structure:** VT8, VT7, VT69 (the first step of VT1), VT1, VT2, VT3, VT6, VT4, VT50, VT87, VT75,
   VT76, VT103, VT106, VT79, VT80.
7. **Security:** VT34, VT35; VT31 when VF7 is unblocked.
8. **Reader accuracy** (section H): each changes what is read, so each is its own owner's call.

### Closed since the first review (removed from the body)

| ID | Closed by | Left over |
|---|---|---|
| VT32 decrypt after proof, let go at lock | `c4e9b6a7c` (VF4) | VT60: the lock-off route and a dead `settingsChanged()` |
| VT33 a way out of an unreadable Vault | `95510e947` (VF6) | VT56, VT57, both closed below |
| VT36 screen capture | `7131333ca` (VF9) | VT73 |
| VT40–VT43, VT45 reader bugs | `97e4f41ce`, redone `f7e441a7a` (v16) and `fd0377535` (v17) | VT88–VT92 |
| VT44 EXIF orientation | not a defect, measured 2026-11-20: do not re-propose | none |
| VT55 one sealed-file writer | `deb831324`, hardened by two reviews (2026-11-21): `SealedFile.write` makes the file owner-only before the swap, logs a refused chmod, writes through a link to the file and replaces a dangling one, and falls back to a temporary file beside it (no leading dot) on a volume with no replacement folder; the store, backups, reading file and activity list use their injected `FileManager` (the app passes `.default`); the backup seals through `VaultFile.sealPlain` with its header as the marker | a crash mid-write on a volume with no replacement folder leaves its `<name>.writing-<UUID>` behind, unswept |
| VT20 rolling backups | `deb831324`, then three reviews: ten `vault-backup-<count>-<UTC time>.sealed` beside the Vault's, ordered by a count that only grows (a clock put back cannot prune the newest; `deb831324`'s `vault-backup-<time>-NNN.sealed` names sort as the oldest), pruned only after the new file is in, and not written again when the newest already holds those bytes; only a whole name of either shape counts as a backup (a Finder copy is not), so nothing else is ever pruned; a save removing more than one *ID* throws `wouldDrop` unless `allowingDrops`. Set It Aside and Start New takes the backups with the Vault (for a damaged file they may be the only readable copies); Replace keeps them and first keeps the Vault as it stood, so Go Back reaches past it; a new key is made only after a lost key's backups, reading file and activity list are set aside, and they go back if the Keychain refuses the key | VF6 reads `store.backups` |
| VT21 golden files | `deb831324` and review 1: `Fixtures/Vault/` holds the Vault (formats 1, 2), the reading file (1, 2), a backup and the activity list, each pinned by SHA-256 so one made again by a later build fails; the backup's resealed JSON is compared too | a fixture per later format change |
| VT30 one bad record | `deb831324`, then three reviews: records decode one by one and a later build's go back untouched (`VaultRecords.newer`, `newerRecords` on the model); a record holding a later field at any depth is sealed back as stored while it is unchanged, and an edited one keeps its top-level later fields (`VaultEntry.storedKeys`); the reading file keeps its later top-level fields (`laterFields`) and the user's own fields a later build stored in a shape this one cannot read (`unreadFields`); a backup restores what it can read (`laterRecords`) and one made here carries the later records; the activity list keeps a later kind's words and a later event as its JSON | not kept: a later field nested in a record edited here, or in the reading file below its top level, or on an activity event this build reads. Owner's call: a later field outlives an edit made here (a field derived from `value` would then disagree with it). A panel line for `newerRecords` is new copy |
| VT24 silent failures | `deb831324`, then three reviews: both failures logged with size and marker only; a damaged reading file, one with no key, or one that is there but will not read is renamed aside under a name of its own (`UnreadableSetAside`), never reset, and the panel starts fresh as it did before (no banner: the next Refresh or Read finds what was waiting); one that will not move, or whose key the Keychain withholds for now (`ReadingLoad.keyRefused`), holds every seal that run, and Everywhere then keeps the typed name on the ID itself; opening the panel makes no key | while held nothing read that run is sealed, People's Misread and roles chosen are lost at the next open, and nothing says so but the log: a line for it is new copy, owner's call. Where `names`, `nameRoles`, `lessons` live is VT6 |
| VT56 Replace sets aside first | `5e33b3c47`: a failed save puts what was set aside back | sealing before the set-aside is not done: on a Mac whose key is gone it would make the new key while the old file is still in place, turning "key missing" into "wrong key" if the set-aside then failed |
| VT57 Add Missing duplicates an id | `5e33b3c47`: `VaultEntry.reissued()`, `id` is `private(set)` | none |
| VT99 a role change publishes nothing | "Vault: a chosen name role shows at once" (2026-11-21): `names` and `nameRoles` are `@Published`; Also used, Misread and its undo each tell the view | none |
| VT101 a role change rebuilds every row | the same commit: `nameRoles` no longer moves `rowsRevision`, which tests can now read | none |
| VT63 a name correction sealed before its save | `976b30712`: `storedName` returns the correction and `apply(_:)` makes and seals it only after `write`, for Confirm and Edit alike (the old code sealed it inside `storedName`, before the save) | none |
| VT68 Stop loses up to 24 files' reads | `f95e61078` and two reviews: `readDocuments` seals on every way out (a no-op when nothing changed or the numbers were let go), and a Vault save seals what is waiting; during a refresh the saved IDs' own documents are marked read only once it has worked out Keep Mine or Use the New Reading, so a Stop, a lock, a quit or the seal every 25 files before then leaves them to be opened, and asked about, again | a stopped refresh's "Updated" marks for what it had opened are not shown by the next one |
| VT59 set-aside leaves the activity file | two reviews (2026-11-21): the activity list is set aside with a lost key's other files before a new key is made (`keyForWriting`), stays in place on a Set Aside or Replace under the same key, and one this Mac cannot open is set aside by its next entry, never sealed over; `setAside` and its kin live in `VaultStore.swift` and use the store's own `FileManager` | none |
| VT104 waiting finds merged again at every open | not done, measured 2026-11-21 (a throwaway timing test, not kept): 200 finds × 6 copies merge in ~60 ms per open (Debug; Release unmeasured, lower). The rebuild is what carries a merge change made without a `VaultReading.version` bump (as `vault-source` was) onto waiting IDs; skipping "already merged" finds would freeze the next such change. If a profile ever shows it: key the rebuild on the build that sealed the file (an automatic identity such as the executable's LC_UUID, kept in the reading state), never on a hand-bumped number | none |
| VT58 backup key derivation | the bound: `5e33b3c47`; off the main actor (batches 3–4): `VaultBackup.write` and `read` derive in a detached task (the weekly backup, made one at a time, Back Up Now, Restore ▸ Choose and the passphrase sheet, whose Cancel stops it), pinned by a test that records where sealing and opening run; the backup tests derive at `leastRounds`, and the bound tests check one past each edge | none |
| VT52 Read Documents outside the PDFKit lane | batches 3–4: every PDFKit call in `VaultFolderReader` takes a turn in `PDFKitSerialAccess.run`, the document is let go of in one, its bytes are read before it (an evicted iCloud file downloads outside the lane), and Vision runs outside; files are read on a queue of their own; pinned by a test that holds the lane (nothing is recognised meanwhile) and checks Vision never runs on the lane's queue | the count-only harness on the owner's folder was not run: the reader's output logic is unchanged |
| VT54 a file with a page left out stamped read | batches 3–4: `VaultDocumentReading.reading(_:)` says whether every page meant to be read was; such a file gives what it gave, asks no Keep Mine question, and is opened once more as it stands, then marked read until it changes | a page that never reads is not read until its file changes |
| VT73 (a, c) screen-capture gaps | batch 3: a date of birth People draws in full counts as an ID drawn in full (`VaultCard.drawsAnIDInFull`), and a window that arrives after the panel first decided is set as it arrives (`VaultActivityWatch.exposed`) | (b), the Quick Look panel of a Vault document, is the owner's call |
| VT102 `expiresSoon` repeats `hasRunOut` | batch 4: one `VaultReading.daysLeft`, which both use, on calendars kept (UTC, and the zone last asked); pinned against the old rule and the old count over 121 hours in three zones | none |
| VT65 one action, one seal | batch 4: Confirm, Add and Edit run inside `sealingOnce`, so the reading file is sealed once at their end (Confirm with Everywhere sealed it up to four times), and a release inside one still seals first; pinned for all three by a disk that counts the seals | none |
| VT94 leaked test plists | batch 5 (2026-11-21), the goal changed by decision: each Vault test's defaults suite is recorded with the shared ledger (`vaultScratchSuite`), whose sweep at a later test run's start, or the hourly sweep of stale scratch plists, deletes it (2,358 had piled up). Never wiped per test: that waits on cfprefsd under a global lock on the main actor (testing laws). The trade: cfprefsd keeps those domains cached until it restarts, as bare suites always did | no test can tell the ledger record was dropped (the hourly sweep cleans up anyway) |
| VT105 name-role tests | batch 5: the lock is taken in the test that says so, the passport test requires its spelling, the repeat is gone, and roles are shown to outlive a change of reader rules (a later shape: VT30's `unreadFields`) | none |
| VT95 tests that cannot fail | batch 5: the activity bounds each tested alone (on stored events too), the clipboard's time on settings of its own and the app's path the same, the banner test's unused render gone, the People titles pinned to the one list given, the backup test and doc comment saying what they can show (a changed salt or work factor derives another key; the test changes the salt) | `drawn(_:)` is VT80's dead code |
| VT26 a log test | batch 5: `VaultLogTests` walks a whole life (seven documents read; confirm, show, copy, edit, add, remove, back up, lock, restore) and asserts lines no other case logs (seven read, four backed up and restored) and that no number, holder's name or document name is in the log, nor in the suite's own preferences, which then hold a set-aside fingerprint | the model's every line asserted one by one |
| VT96 the backup's purpose | batch 5: a backup opened on another Mac asks for its passphrase, refuses a wrong one, opens with the right one and replaces that Vault; an old backup keeps its old passphrase | the Settings side (`showActivity`, the offer's wording) |
| VT97 the swatch test | batch 5: it waits on the click's answer, not a fixed sleep, and its window sits beneath every other | none |
| VT71 the rows cache | batch 5: `VaultRowsCacheTests` makes the changes the rows are made of, as the app does (people, owner, pin, country, kind, Read from This Copy, a name corrected, a Misread, Not This, Remove, a document gone, a kind added, renamed and removed), and checks the cached rows equal rows worked out afresh | the hand bumps in `readFrom` and `setKinds` are redundant (their changes also move `entries` or `finds`); a read-folder change |
| VT28 privacy tests | batch 5: `VaultDetail.Value`, `VaultChange`, `VaultPersonSection` and its names and dates of birth print no number in full, no name and no date; the privacy test covers them, `VaultReadingState`, `VaultChoice` and `VaultFind`, `dump` included, and the whole-life test checks the log and preferences | `MachineZone`, `Row` and `VaultReadTally` in the privacy test; `VaultMask.fileName`'s property test; the read folders and kind and group names are the user's own, in the clear |
| VT78 allocations per draw | batch 6: the eight colors are made once, each drawing the shade of whichever appearance it is drawn in (pinned light after dark, dark after light) | the swatch image stays one per draw, on purpose: a review probe showed SwiftUI never draws a held `Image(nsImage:)` again when the appearance changes, so a cached one kept the other appearance's shade |
| VT77 masonry measures twice | batch 6: `VaultMasonry` and `VaultTwoUp` keep a pass's measurements by width, emptied in `updateCache`, which SwiftUI calls when a card grows on its own with no change to which cards there are (pinned: a no-op `updateCache` goes red) | none |
| VT85 regexes per line | measured out (2026-11-21, by hand with a throwaway program, not kept): Foundation keeps a pattern's compiled form, so `range(of:options: .regularExpression)` costs 0.3 µs a line against 3.6 µs compiled each time, and a `static let` saves 0.1 µs. `labelledName`'s stop set is now made once | none; do not re-propose |
| VT84 label search | batch 6: each line's letters and where they sit are worked out once per page (`PrintedPage.lettered`) and compared without a copy per try; a page's group number, holder, subscriber and issuer once per page, not per number (`AccountPageFacts`) | each label is still squeezed per call: a few letters. The letters stay made with the page: made at first use (tried after review), three of the owner's account papers read differently, the cause not found |
| VT83 a page through the readers five times | batch 6: a colored page's two readings are kept from the weighing and not read again; `wantsSharperRead` asks once whether a page is a Social Security card. The other reads are of other lines (the typed layer, the file's pages together) | none |
| VT82 renders per page | batch 6: `PageRenders` makes each render once per page and scale and reads each once per scale, so the ink-alone read takes the 2400-pixel render, and a card-size page, the same image at 2400 and 4000, goes through Vision once (pinned, counted) | a page read sharper holds its 2400-pixel render while the sharper one is made, two at once where one was: up to about 130 MB for a large square page, whose 2400 render is clamped near 4000 pixels |
| VT66 rows rebuild per row | batch 4 (one registry, no regex), batch 6: `primary` in one pass with each placement worked out once (pinned equal to the ordered list's first over 75 orders and speakers), and one merge per set of copies per rebuild (`MergeMemo`, counted) | none |
| VT67 stats on the main actor | batch 6: the read plan's dates, each file's size and stamp (in one pass before the first file, so a read of unchanged files does not give the panel a redraw per file) and the check for documents saved IDs point at run off the main actor (pinned by a reader that notes any question asked on the main thread). Measured by hand on the owner's `~/Documents` (a throwaway program, not kept): exists and stamp for 500 PDFs, 46 ms | an evicted iCloud file was not shown: none of his 10,991 PDFs was evicted on 2026-11-21. Size, date and existence read metadata only |
| VT9 the panel recomputes every second | batch 4 (the lists cached on what they are made of), batch 6: `now` and `lock` publish only when what the panel draws from them changes (`Clockface`: open or shut, the last ten seconds, the number shown, the day, how long ago the last Refresh and Discover were in the steps their wording turns on: half minutes in the first hour, half hours to a day, then days); pinned: a hundred seconds of use redraw nothing, the countdown once a second, a locked day with no Refresh or Discover yet nothing until midnight and then once, a shown number's seconds nothing and its end once. Large Type also closes when its row leaves the list, not only at a tick. A Stop during the last check of documents saved IDs point at now ends the read there, as a lock during its last file would | `rows` reads its folders from UserDefaults per access and `elsewhere(card)` and the counts run per draw: now per real redraw only, and a stored copy would miss a change made outside the app |

---

## A. Storage and format

**VT108 — Two app processes on one Vault.** *Risk; checked by review 3; owner's call.*
- **The problem.** One process holds one `VaultModel` (the single `Window` scene), but the installed
  app and a worktree build can run at once. If one adds an ID and the other then saves from the list it
  loaded earlier, the short-list guard allows that one drop: the added ID is gone but for a backup copy.
  Two or more give "That change would have removed N IDs at once".
- **Fix.** `save` compares the file on disk with what this process last loaded or wrote, and on a
  difference reloads and refuses. *Owner's call:* a refused save is new behaviour, and what the panel
  says then is new copy.

**VT6 — Fewer homes for state.** *Open, and worse.*
- **The problem.** What the Vault knows now lives in:
  - four sealed families, plus the ten copies kept before each save (VT20);
  - UserDefaults keys, which hold:
    - set-aside fingerprints and their generation;
    - read folders, filters, folded cards, groups and group names;
    - custom kinds, card colors, backup folder and last backup;
    - lock and sharing settings, refresh-automatic, activity-keeps and the lock-off seal;
  - the Keychain (the key, the backup passphrase, the lock-off secret).

  Two hazards come with it:
  - **Two sealed files are written one after the other** (`confirm` → `add` → `write` at
    `VaultModel.swift:1644` → `dropFinds`/`saveReading` at `:1698`). `load()` (`:1466–1514`) does not
    drop a waiting find whose number is saved, and `take` (`:2102`) rebuilds a waiting find before it
    looks at the entries. A crash between the writes shows the number twice for good.
  - **A new path reaches the same state with no crash:** Restore ▸ Add What's Missing checks only saved
    entries (`VaultBackup.swift:301–304`), so a restored number that is also waiting in To Confirm shows
    twice.
  - **The user's own choices live in the reading file:** `names`, `nameRoles` (since `710b5aaa3`) and
    `lessons`. `VaultBackupContents` holds `entries` only, so none of them is ever backed up, and Set
    Aside and Restore ▸ Replace move them away with the file. A damaged reading file is now renamed
    aside, never reset (VT24, closed), so nothing is lost silently, but nothing brings them back either.
- **Done when:**
  - `load()` reconciles: a waiting find whose number is saved is dropped, and a test seeds both files;
  - saved and waiting records, set-aside fingerprints, `names`, `nameRoles` and `lessons` share one
    sealed document, which the passphrase backup also carries (a backup format change: add a fixture),
    written in one atomic swap through `SealedFile.write` (the read index may stay apart: it is a cache);
  - UserDefaults keeps view preferences and settings only.

**VT3 — Drop shims for builds that never shipped.** *Open.*
- **The problem.** These remain:
  - `VaultEntry.Kind` (`VaultEntry.swift:11`), `older` (`:55`), `kind` still encoded (`:107`) and kept
    by the `category` setter (`:97`);
  - `VaultCategory.from(kind:title:)` (`VaultFacts.swift:90`, sniffing the title);
  - `Draft.init(…kind:)` (`VaultModel.swift:119`) and `VaultFind.init(…kind:…sourcePath:)`
    (`VaultReading.swift:44`).

  `Draft.kind` (`:98`) and `VaultFind.kind` (`:59`) have no production reader. `VaultEntry.dated` and
  `sourcePath` duplicate `facts.dated` and `facts.primary.path` (`:121–124`).
- **Done when:** one migration rewrites the owner's file, and the shims and their tests are gone.
  Unblocked: VT20's backups and VT21's fixtures are in, and `chosenSource` has landed in the same
  `CodingKeys`. The migration saves with `allowingDrops: false` (it drops nothing), adds a new
  fixture format, and keeps `vault-format-1` opening. A key taken out of `CodingKeys` is no longer one this build reads, so
  `VaultFile.openRecords` would keep it as a later build's field and seal it back: the migration
  strips the retired keys (`kind`, `older`, `dated`, `sourcePath`) itself, and drops
  `VaultRecords.stored` for them: an unchanged record is otherwise sealed back as it was stored,
  retired keys and all.

## B. The model

**VT1 — One record type with typed fields.** *Open, and worse.*
- **The problem.** One record has seven shapes:
  - `VaultEntry` (`VaultEntry.swift:9`);
  - `VaultFind` (`VaultReading.swift:9`);
  - `VaultChoice` (`:1143`);
  - `Draft` (`VaultModel.swift:73`);
  - `Row` (`:310`);
  - the local `Item` (`:458`);
  - `VaultStandingInput` (`VaultFacts.swift:327`).

  The user's choices (pin, assignment, geo, card) are copied field by field at `VaultModel.swift:125–149`,
  `:493–508`, `:584–592`, `:1639–1643`, `:1663–1671`, `:1943–1945`, `:2120–2121` and
  `VaultReading.swift:1158`. Examples of the cost:
  - `vault-source` threads `chosenSource` through 11 sites in 4 files, and `Draft` still does not carry
    it.
  - `holderName` touches `Draft`, `Row`, `Item`, `add`, `update`, `storedName` and `prepared`.
- **Done when:**
  - a single `VaultRecord` holds `fields: [VaultField]` (number, secret, text, date, phone, address;
    each with label, value, `isMain`, `hidesEnding`), plus:
    - an owner;
    - an origin (typed, or read from sources);
    - a state (saved, or to confirm);
    - the user's choices;
  - `Row` is a derived view of it and `Draft` an editable copy;
  - readers emit records.

  VT69 is the behaviour-preserving first step.

**VT69 — The user's choices as one value.** *Duplication; checked. The first step of VT1.*
- **The problem.** The two hand-written `VaultFind(...)` re-makes (`VaultModel.swift:2053`, `:2232` at
  `710b5aaa3`) are where a forgotten new field silently drops a choice on every re-read; `vault-source`
  had to patch both. `Draft` still lacks `chosenSource`, so `add` takes `chosenSource:` and
  `readHolder:` as loose parameters (`:1727`). `Item` (`:458–476`) mirrors `Row` (`:310–360`) field for field.
- **Fix.**
  - One `VaultChoices` (pin, assignment, geo, card, chosenSource) embedded in `VaultEntry`,
    `VaultFind`, `VaultChoice` and `Draft`, with `Codable` that keeps the JSON keys flat.
  - `find.keepingChoices(of:)` replaces both re-makes.
  - Build `Row`s directly in place of `Item`.
- **Done when:**
  - a new choice touches one type;
  - the sealed JSON, decrypted and key-sorted, is byte-identical before and after.

**VT2 — Kinds as data.** *Open.*
- **The problem.** `VaultCategory` is switched on in 11 functions in `Sync`:
  - six in `VaultFacts.swift:10–110`;
  - `placement` (`:173`) and the standings group key (`:589`);
  - `VaultGeo.read` (`VaultFilters.swift:26`);
  - `VaultPersonText.paper` (`VaultPeopleView.swift:128`);
  - `VaultMask.printed` (`VaultEntry.swift:266`).

  Two more are in `VaultPanel.swift` (`:1726`, `:2417`). Parallel lists sit beside them:
  - `mainView`/`typedIn` (`VaultFacts.swift:647–650`);
  - `VaultGroups.default.groupOf` (`VaultFilters.swift:96`);
  - `VaultColors.appGroups`;
  - `VaultKinds.changeable` (`VaultKinds.swift:77`) and `VaultReading.accountCategories`
    (`VaultAccountReading.swift:14`), which are the same four kinds.
- **Done when:**
  - one `VaultKindSpec` table gives each kind its id, names, symbol, field template, masking and
    grouping pattern, validator, default owner, place, group and expiry rule;
  - app kinds and the household's own kinds (`VaultCustomKind`) are rows of it;
  - adding "Bank account" is one row plus a reader.

**VT4 — Places as data.** *Open.*
- **The problem.** "The other country" is computed as `geoFilter == .us ? .india : .us`
  (`VaultModel.swift:657`, `:699`), and two accessibility names are hard-coded (`VaultPanel.swift:794`).
- **Done when:**
  - a place is an ISO code or `anywhere`;
  - nothing assumes two places;
  - with the owner's two places, the panel is unchanged.

**VT7 — `VaultModel` does four jobs.** *Open, and worse.*
- **The problem.** At 2,270 lines it holds the lock session, record CRUD, the rows → cards → people
  derivation, and Read Documents. `readDocuments` runs `:1759`–`:2062` (about 300 lines), with four
  nested functions and eleven locals. Within it:
  - The refresh tail (`:1979–2016`) and the discover tail (`:2023–2061`) repeat the same steps:
    `readingChanged`, `saveReading`, `lastReading`, the log line, `record`, and the selection fix-up.
  - "Advance progress, then continue" is written four times (at `710b5aaa3`: `:2015`, `:2021`, `:2031`,
    `:2080`). One copy dropping `scope` was the bug `d1e29f8c8` fixed by making `scope` required, which
    closes that bug class; the four copies remain.
- **Done when:**
  - (a) `VaultSession` owns lock, epoch, proof and release;
  - (b) the record store owns load, write and reconcile;
  - (c) a `VaultReadRun` value owns the walk, the settle rules and the tally, with one per-step advance
    and one `finish(scope:)`, tested with no model;
  - (d) rows, cards and people are a pure function of (records, people, filters, now).

**VT10 — Keychain round trips.** *Part done in batches 3–4: an activity entry reads the key once (it was twice), and `isDue` asks the Keychain only once a week has passed. Open, with VT31: the key held from a load until `release()` (it changes the key's lifetime), and `keyState()` for the probe (an attributes-only query cannot tell a key the Keychain withholds for now, which today opens to its notice at once, from one it releases: the panel would ask for a proof first). Indexed finds judged in batch 6 not worth it: the scans run per action, and a read's per-file account check is about 680,000 normalisations (1,356 files by about 500 finds, estimated, not timed), well under a six-minute read.*
- **The problem.** With the lock on, open plus unlock reads the Vault key five times:
  - `fingerprint("")`, a probe by side effect that tells a missing key from a present one
    (`VaultModel.swift:1191`);
  - `record(.unlocked)` → `append`, twice (`VaultActivity.swift:89`, `:97`, `:106–107`);
  - `store.load` and `loadReading`.

  It also reads the passphrase twice (`backUpIfDue` → `isDue` → `hasPassphrase`, from both
  `VaultPanel.swift:244` and `:261`), and two more for the seal when the lock is off. More reads:
  - Confirm: five. Copy: two.
  - `isNew` and `remember`: one per find (`:2229`, `:2217`).

  On a locked login keychain each read logs the same warning. Separately, finds and copies are scanned
  linearly with `normalized` recomputed, at `:1630`, `:1693`, `:1880` (`accountNumbers`), `:1929`,
  `:1938`, `:1994–2000`, `:2102`, `:2107` and `:2127` (`forgetSource`).
- **Done when:**
  - the `SymmetricKey` from a successful load is held until `release()` and passed to the store and the
    activity store;
  - `store.keyState()` replaces the probe;
  - `isDue` checks `lastBackup` before the Keychain;
  - a counting `KeychainStore` sees one read per open plus unlock and none per later action;
  - finds are indexed by normalised number, and copies by path.

  VT31 makes this mandatory, since every read would then prompt.

**VT64 — A removed ID's number lives on in the reading file.** *Privacy; checked.*
- **The problem.** `delete` (`:1705–1721`) leaves `copies[number]` (whole `VaultFind`s, value included)
  and the mentions `dropFinds` moved there (`:1695`). Set Aside (`:2208`), Confirm (`:2193`) and Edit
  (`:1681`) all clear them. As a result:
  - `refreshSources` (`:1410`) keeps opening the removed ID's documents;
  - typing the number back in re-attaches stale copies.
- **Fix.** `delete` drops `copies[key]` and those mentions, and seals.
- **Done when:** the sealed state holds no key for a removed number.
- **Owner's call (small):** the Refresh document count drops to the right number.

**VT70 — "Whose is it" is worked out in two places.** *Duplication; checked; owner's call.*
- **The problem.** The editor matches the name as read (`Draft(find, people:)`, `:136–143`). The row uses
  the corrected name and three inference passes: birth date, passport, folder (`computedRows`,
  `:498–564`). Confirm's save patches this only for a nil person (`VaultPanel.swift:2511`).
- **Owner's call.** One shared function is internal only if each caller keeps its own inputs. Letting
  the editor take the row's inferred person changes what Confirm offers.

**VT72 — Activity titles are cut at their last slash.** *Bug; checked.*
- **The problem.** `record` masks with `VaultMask.fileName(what)` (`VaultModel.swift:1262`), which takes
  `lastPathComponent` first (`VaultEntry.swift:168`). "Chase / Mortgage" is listed as "Removed
  Mortgage"; a proof reason "show H-1B / I-797" becomes " I-797".
- **Fix.** A public `VaultMask.text(_:)` that masks the whole string.
- **Done when:** a test uses a title with a slash. The fix makes a wrong line right.

**VT100 — Two spellings can share one role key.** *Bug; checked; owner's call.*
- **The problem.** People merges printed names with `caseInsensitiveCompare` (`peopleSections`,
  `VaultPeopleView.swift`), but roles are keyed by `spellingKey`, letters only
  (`VaultReading.swift:172`). "Anna-Maria Eriksson" and "Anna Maria Eriksson" are two chips with one
  key; `roled` finds the key with `keys.firstIndex(of:)` (`VaultPeopleView.swift:130ff`). Legal on the
  second chip marks the first; Misread on it corrects nothing (`VaultNames.swift:103–105`).
- **Owner's call.** Merging chips by `spellingKey` makes one of the two disappear. The internal half:
  key every role lookup by the chip's own index, so each chip acts on itself.

**VT22 — Session lines.** *Partly.*
- **The problem.** The activity list records `unlocked` and `proofRefused` (`:1535–1543`). The log gets
  nothing for open, lock, release or a proof discarded because `lockEpoch` moved (`:1530`).
- **Done when:** INFO lines carry:
  - opened, with lock mode and counts by state;
  - proof asked, and its outcome or discard;
  - locked, and why;
  - released.

  Never a title.

**VT23 — Record lines.** *Partly.*
- **Today.** `record` (`:1259`, `:1266`) is the one function, and it covers add, edit, remove, confirm,
  set aside, show and copy.
- **Not recorded:**
  - pin, assign, place, kind, name correction and Read from This Copy;
  - `copyPerson(numbers: true)`, which copies every ID in full and records nothing (`:869–879`);
  - its proof (`for: nil`) records "Unlocked" even under "For every number";
  - `copyBirth` is listed as "Copied A detail of <first ID>" (`:886`);
  - not yet confirmed: whether Large Type and Quick Look of a scan record a show;
  - nothing goes to the log.
- **Owner's call:** each addition is a new line in Activity. Whether log INFO lines mirror Activity is
  also his call.

## C. The panel and the app side

**VT8 — Display rules live in the view, untested.** *Open.*
- **The problem.** These are in `VaultPanel.swift`:
  - `rowTitle` (`:1720`), `rowSubtitle` (`:1741`), `detailLede` (`:1900`), `idLabel` (`:2414`);
  - `largeTypeLines` (`:2612`), `foldedSummary` (`:1096`), `kindTitle` (`:1432`), `kindNote`
    (`:1612`);
  - the Large Type heading (`:228`), `rowSpoken` (`:2451`), `belongsTag` (`:1691`), `escape`
    (`:2464`), `save()`'s Add-to-People branch (`:2497`);
  - and now `exposesAnID` (`:155`), the screen-capture decision.

  Only `changeLine`, the footer strings and `spokenNumber` are tested.
- **Done when:**
  - each is a pure function in `Sync`, or a static on the row, with literal-value tests;
  - the view only lays out;
  - `exposesAnID` is `VaultModel.exposesAnID(editing:largeType:)`.

**VT73 — Screen-capture gaps.** *Privacy; (a) and (c) closed in batch 3; (b) is the owner's call.*
- (b) *Plausible.* Quick Look of a scan is `.quickLookPreview` (`ContentView.swift:1345`), its own
  panel. Only the main window's `sharingType` is set. Making the panel follow the setting while it
  shows a Vault document is the setting's intent, but changes what a share shows.

**VT74 — Render tests can run the panel's live side effects.** *Tests and privacy; plausible.*
- **The problem.** `VaultCard`'s `.task` calls `model.backUpIfDue(using: VaultBackup.live())`
  (`:244`, `:261`) and reads `VaultReadFolders.folders()` from `.standard` (`:237`).
  `VaultPanelRenderTests` hosts the real `VaultCard`. With a backup passphrase set, a render test could
  write the made-up IDs into his real backup folder and move `lastBackup` a week. None is set today.
- **Done when:** `VaultCard` takes its backup and folders as injected values (live from `ContentView`,
  nil in tests).

**VT75 — Duplicated view code.** *Duplication; checked.*
- **The duplicates.**
  - The standing and Remove menu items, written twice (`:1469–1482`, `:1977–1989`).
  - The "Nothing here for these choices" state, copied twice (`:963–975`, `:1154–1166`) and missing from
    the List layout (`:1113`).
  - "N More in …" (`:989`, `:1048`); the card chrome (`:1068–1071`, `:1272–1273`).
  - The " case" strip, which duplicates `kindTitle` (`:1790`); the holder heading (`:228`, `:1901`).
  - `PersonRegistry(...).detect`, built twice in one menu (`:1507`, `:1521`).
  - The "Copied" timer, written three times (`:1292`, `:2593`, `:2694`).
  - The folder `NSOpenPanel`, here and in `VaultSettings.swift:187`.
  - `actionBar` using `first(where:)` where `selectedEntry`/`selectedFind` exist.
  - Two pickers for one choice: `VaultColorPicker` in Customize Groups and `VaultColorPopover`.
- **Done when:** each is one view or function.
- **Owner's call:** giving the List layout the same empty state as the others.

**VT76 — View state that duplicates the model's.** *Complexity; checked.*
- **The problem.**
  - The layout sits in `@AppStorage` and is copied into `model.layout` by hand (`:240`, `:602`).
  - People are held both as the `people` prop and as `model.people`, and `addPerson` updates only the
    second (`:1658`).
  - `readFolders` is re-read in four places.
  - `largeType`/`largeTypeLine`, `namingKindFor`/`newKindName` and `copied`/`copiedDetail` exist only as
    pairs.
- **Done when:**
  - the model owns the layout key;
  - the view reads `model.people`;
  - each pair is one optional (19 → 16 `@State`).

**VT79 — A process-wide retroactive conformance.** *Complexity; checked.*
- **The problem.** `extension URL: @retroactive Identifiable` (`VaultSettings.swift:452`) exists for one
  `.sheet(item:)`.
- **Done when:** the URL is wrapped in a small `Identifiable` struct.

**VT81 — Size and type caps apply to Discover only.** *Checked; owner's call.*
- **The problem.** `largestFile` and `extensions` are enforced in `walk()` (`VaultDocumentReader.swift:55–57`).
  Refresh opens `refreshSources` directly, so a source that grew past 60 MB is still read.
- **Fix.** Check both in `pages(in:)`.
- **Owner's call:** this changes what Refresh reads, for files over 60 MB only.

**VT103 — People's groups use their name as the `ForEach` id.** *Plausible.*
- **The problem.** `ForEach(section.groups, id: \.name)` (`VaultPanel.swift:1245`): a group the user
  names "Other" collides with the made-up "Other" for kinds in no group (`grouped`,
  `VaultPeopleView.swift:153`). `grouped`'s sort also calls `cards.firstIndex(of:)` twice per comparison.
- **Fix.** `id: \.id` (nil is the made-up group's, unique); an index dictionary for the sort.

**VT106 — Small duplications from the People work.** *Checked.*
- The popover `Binding(get: x == key, set: …)` is written in `namePopover` and `birthSources` beside the
  older `isColoring` (`VaultPanel.swift:1112`): one generic helper.
- `(row.facts?.primary?.path).map { lastPathComponent }` three times (`sourceLabel`, `sourceHelp`,
  `sourcesList`).
- The doc reference ``sourceChoices(of:speaker:chosen:)`` (`VaultModel.swift:512`) names an old
  signature; it is `(of:shown:chosen:)`.

**VT11 — Stale comment.** *Closed in batch 3: the comment went with VT73's change.* `VaultActivityWatch` says "every window has a Vault of its own"
(`VaultPanel.swift:3105` at `710b5aaa3`); the app is one `Window` scene (`SyncCloudApp.swift:553`).

**VT25 — Reader skips.** *Partly.*
- **Today.** Too-large files and unreachable folders are counted at INFO (`VaultDocumentReader.swift:61–66`).
- **Still missing.**
  - Locked PDFs, unopenable PDFs and unrecognised pages are per-file DEBUG lines (`:103`, `:107`,
    `:115`), never summed.
  - `pages(in:)` returns `[]` for all of them, so the model cannot tell them apart.
  - Refresh skips `walk()` and logs no size skips at all.
- **Done when:**
  - `pages(in:)` returns a skip reason;
  - both summaries count each cause: too large, locked, unopenable, page unrecognised, read from the
    picture, ink-only, sharper render.

## D. Tests

There were **416** `@Test`s at `0409895c8`: 374 in 30 `Sync` files and 42 in 8 `SyncCloudTests` files (since then `VaultFormatTests`, with 46, and more in `VaultBackupTests`, `VaultRefreshTests`, `VaultNameCorrectionTests`, `VaultPeopleViewTests`, `VaultReadDocumentsTests`, `VaultReadingTests` and `VaultKindsTests`). None is
parameterised. Three are machine-pinned to text recognition and skip on hosted CI
(`VaultFolderReaderTests.swift:257`, `:277`, `:291`).

**VT98 — One Vault test kit.** *Duplication; checked.*
- **The problem.**
  - `Rig` and `Clock` live in `VaultLockTests.swift:170–205`, `VaultFakeKeychain` in
    `VaultStoreTests.swift:9`, `VaultFakeDocuments` in `VaultToConfirmTests.swift:8`, and
    `PlannedDocuments` in `VaultAccountsTests.swift:442`.
  - About 200 references go across suites; `VaultFixtures.swift` forwards only three.
  - There are seven `VaultDocumentReading` fakes in `Sync`; the app's `Shelf`
    (`VaultRefreshPanelTests.swift:68`) is a subset of `VaultRefreshTests.swift:12`.
  - The keychain fake exists twice, and there are four proof fakes.
- **Done when:** one `VaultTestKit.swift` (Rig, Clock, FakeKeychain, FakeProof, Shelf), compiled into
  `SyncCloudTests` the way `project.yml` does for `EventsTestSupport`.

**VT29 — Lock under time.** *Half done in batch 5: `VaultLockedRoutesTests` runs every route above once the numbers are let go: none succeeds, none asks for a proof, nothing reaches the clipboard, neither file changes by a byte; and a proof answered after the Vault locked meanwhile opens nothing (Copy, Edit, Copy a person's IDs). The guards in `write`, `saveReading` and the routes' own looks after a proof are not reached first by any route (each finds no ID, or no person, first): defence only. Open: the lock-state table.*
- **The problem.**
  - Lock behaviour is spread over 19 cases in `VaultModelTests`, 8 in `VaultSealedShutTests` and 6 in
    `VaultProofTests`, with no table.
  - On a locked model, these routes are never run with both files' bytes compared: assign, pin, setGeo,
    setKind, update, delete, keepSaved, useReread, confirm, setAside, copyPerson, copyBirth,
    copy(detail). Only copy is.
  - No test holds a stale list while `contents != .loaded`, so deleting the guards in `write`
    (`VaultModel.swift:1728`) or `saveReading` (`:2166`) most likely survives.
- **Done when:**
  - one table test covers every `Ask` × `Relock` × event (open, use, idle past the limit, close, reopen,
    sleep, Lock Now, a proof answered after `lockEpoch` moved), asserting `isOpen` and what is loaded;
  - a second table runs every route above sealed shut, asserting no proof is asked, nothing is returned
    and both files are byte-identical.

**VT27 — App-side tests.** *Partly.*
- **Today.** Eight app-target files with 42 tests now cover the masonry, colors and popover, window
  privacy, People, the locked panel, the refresh footer and the folder reader.
- **Still untested:**
  - `VaultPasteboard` (`VaultHost.swift:120`): markers, `.currentHostOnly`, clearing only when the
    change count is unchanged, and on quit;
  - `VaultCardSize.fitted` (`VaultPanel.swift:7`);
  - `VaultActivityWatch` window scoping (`:2715`);
  - in `VaultDocumentReader.swift`: `largestFile` (`:28`), `pagesPerDocument` (`:25`) and the
    locked-PDF guard (`:106`);
  - whatever VT8 leaves in the view.

## E. Security and privacy

What is sound and should stay:
- **Sealing.** AES-256-GCM with the marker as authenticated data; a random key, never synchronised; 0600
  files; "never write over a file this Mac cannot open".
- **Keyed fingerprints.** HMAC-keyed set-aside fingerprints and the lock-off seal.
- **The lock.** `lockEpoch` discarding late proofs, and nothing loaded before a proof (VF4).
- **What prints.** Masked `description`s and empty mirrors.
- **The clipboard.** A concealed, host-only copy, cleared after the set time and on quit.
- **The backup.** PBKDF2-HMAC-SHA256 at 600,000 rounds, its header authenticated, a published-vector test.
- **The activity list.** Bounded and sealed.
- **Sending.** Nothing goes to Claude.

**VT31 — The lock is the app's, not the key's.** *Open; blocked with VF7.*
- **The problem.** `VaultKeychain.create` (`VaultStore.swift:73`) stores the key in the file-based
  login keychain. There `kSecAttrAccessibleWhenUnlocked` has no effect, and any read by this app
  succeeds without the user present. The backup passphrase sits beside it, on purpose, so the weekly
  backup runs unattended.
- **Done when:**
  - on a signed install, the key lives in the data-protection keychain under
    `SecAccessControl(.userPresence)`;
  - the unlock passes its `LAContext` as `kSecUseAuthenticationContext`;
  - VT10 is done first.

  This needs a keychain access group, which needs a provisioning profile (storing fails with −34018
  today); VQ5 picks `.userPresence`.

**VT34 — Endings are secrets for some kinds.** *Partly.*
- **Today.** `hidesEnding` exists (`VaultFacts.swift:69`) and rows, VoiceOver and People use it.
- **Still keeping four:**
  - `description`s (`VaultEntry.swift:133`, `VaultRedaction.swift:53`);
  - activity titles (`VaultModel.swift:1262`);
  - the re-read banner (`VaultPanel.swift:1871`).
- **Done when:** all of them follow `hidesEnding`.
- **Owner's call:** the banner is drawn, so it is a visible change.

**VT35 — One copy path.** *Partly.*
- **Today.** Numbers, detail numbers, Copy Summary and birth dates go through `copyToPasteboard`.
- **Still direct.** Two writes still go straight to `NSPasteboard.general`: a name in People
  (`VaultPanel.swift:1227–1228`) and a non-number detail (`copyDetail`, `:2700–2701`). They are plain,
  never cleared, and relayed by Universal Clipboard. The data in them is drawn in clear.
- **Done when:**
  - every write is in `VaultPasteboard` (a `copyPlain` beside `copyConcealed`);
  - a source scan finds no `NSPasteboard` in `VaultPanel.swift`.
- **Owner's call:** whether names and dates are concealed and cleared too.

**VT60 — Lock routes left after VF4.** *Checked.*
- **The problem.**
  - With the lock off, nothing ever lets the numbers go.
  - `settingsChanged()` (`VaultModel.swift:2242`) has no app caller: Settings and the Vault cannot be open
    together (`ContentView.swift:1326`, `:2568`), and `opened()` re-reads the settings. It is kept alive
    only by `VaultLockTests.swift:446`.
  - Turning the lock off sets `requiresAuthentication = false` without checking that `sealOff` worked
    (`VaultSettings.swift:445–447`; `VaultLock.swift:240` returns silently). After a Keychain refusal,
    Settings shows the lock off while the Vault still asks.
  - The lock is scoped by whether anything was sealed when the panel opened, which keeps about 35
    older tests' meaning: an ID typed into a Vault that opened empty stays loaded until close ("Added.
    Unlock to see it."). Nobody has checked for a path that draws such a row before a proof.
- **Done when:**
  - `settingsChanged()` and its test are gone;
  - VT29's table covers a sitting that starts with nothing sealed;
  - `sealOff` returns `Bool`;
  - a test pins that a lock-off Vault releases at close.
- **Owner's call:** what Settings says when sealing fails, and whether a lock-off Vault lets go at close.

**Smaller.** Under "For every number", `assign`, `pin`, `setGeo`, `setAside` and `confirm` need no proof;
whether a locked Vault is read-only is the owner's call. The 30 s display time (`VaultLock.showFor`,
`VaultLock.swift:99`) is a constant; the clipboard time is a setting now.

## F. Readers: internals

Each item here preserves what is read unless it says otherwise. Prove a change with the hash harness.

**VT107 — Pick identity files before opening them.** *Steps 1 and 2 done in batch 4: a file whose bytes were read already in this read reuses its pages (`contentKey(of:)`, size and SHA-256, hashed off the main actor), and identity papers are opened originals first (`VaultReadPlan.originalsFirst`; packets of copies last wherever they are filed), with the same finds either way (`originalsFirstOrLastFindTheSame`). Steps 3–5 wait for the owner.* *Efficiency; checked; the owner asked for it
(2026-11-21): "knowing which file to pick is important."*
- **The problem.** Every file under Immigration or Legal is opened, file name unseen
  (`VaultReadPlan.swift:36–37`); Refresh uses `VaultReadPlan.every`, which passes nothing over
  (`:60–73`). Each opened PDF gives pages 1–3 (`VaultDocumentReader.swift:25`, `:119`), each page up to
  three Vision passes plus a barcode render (`VaultPageSource.swift:140–182`): about nine recognitions,
  roughly a second each. The walk sorts by path (`VaultDocumentReader.swift:67`), so
  `…/Supporting Documents/…` can come before `…/Passport/…`. The signals that tell an original from a
  copy already exist and are used only after reading:
  - `placement(for:)` scores the folder: the home folder +2; supporting, petition, application,
    evidence, exhibits, attachments, packet −2; archive −1 (`VaultFacts.swift:173–198`);
  - `VaultSource.rank` comes from what the page says ("Passport photo page" is 40,
    `VaultReading.swift:663–664`);
  - the read index skips a file whose size and date are unchanged (`VaultModel.swift:2019`).

  So a visa packet holding a passport copy is opened and read like the passport itself, although its
  number is already held from the passport's own folder. On his folder (harness, 2026-11-20, not
  re-measured): 11,299 files walked, 1,356 planned, 544 file-level finds for 129 numbers, about four
  files per number, a full read 339 s. The cost lands on the first read, Read Everything Again
  (`:1877`) and every `VaultReading.version` bump, which drops the read index and `copies`
  (`:1578–1594`), so Refresh then reopens every copy too.
- **Fix, safest first.**
  1. **Read a byte-identical file once.** Group planned files by size, then SHA-256, and call
     `pages(in:)` once per group; `VaultReading.read(pages:from:)` still runs per path, so each keeps
     its source, copy, date and placement. Internal. Measure the groups first with the harness.
  2. **Originals first.** Order identity steps by `placement` (home folder first, packets and archives
     last), then path. Internal: same rows, waiting list and `copies` in either order (a model test
     reads one fixture both ways); a stopped read then has the original before its copies.
  3. **Pass over a supporting copy whose numbers are all held from a home-folder source.** Keep the
     file → numbers map across a version bump so this is known before opening. *Owner's call:* the copy
     leaves the row's documents and the Read from choice, a detail or later date only it has is lost
     (`supersedes`, `VaultFacts.swift:702`), and a number new rules would find in it is missed. A packet
     can be the only copy of a spouse's passport or an I-797, so "all its numbers held" is the test,
     never the folder alone.
  4. **Refresh reopens only the file each ID is read from**; other sources get the size-and-date check,
     and a changed one sets `needsDiscover`. *Owner's call:* a changed copy shows later.
  5. **Keep Vision's page text, sealed, by file stamp, page and render size**, so a version bump re-runs
     the rules, not the OCR. *Owner's call:* it stores document text.
  6. Not recommended: stop paging at the first number. An OCI card's back has its issue date; a visa
     foil can sit on page 2.
- **Done when:** (1) and (2) are in with the harness showing the same numbers, sources and counts and
  fewer `pages(in:)` calls; (3)–(5) each wait for the owner. Relates to VT82–VT85 (cost per page),
  VT67 (stats), VT81 (caps) and VT54 (stamping), none of which chooses files.

**VT50 — Duplicated toolkit.** *Open; references corrected.*
- **Squeezing.** `VaultReading.squeezed` (`VaultIDReading.swift:41`) equals `PrintedPage.squeezed`
  (`VaultPrintedPage.swift:32`). It is recomputed seven times per page per pass (`:198`, `:261`, `:368`,
  `:416`, `:561`, `:689`, `:747`). On top of that:
  - `page.joined` (`:562`, `:690`);
  - `noticeKind` lowercases the text four times (`VaultReading.swift:252`, `:280`, `:387`, `:436`);
  - `sections` builds N throwaway `PrintedPage`s (`:629`).
- **Dates.** `datePattern` (`VaultIDReading.swift:57`) is identical to `PrintedPage.numeric`
  (`VaultPrintedPage.swift:47`). `spelledDates` (`:517`) is a stricter twin of `spelledMonthFirst`
  (`:44`): keep it, in `PrintedPage`.
- **Title-casing.** `readingOrder` (`VaultReading.swift:245`) and `printedName` (`:365`) equal
  `titleCased` (`VaultIDReading.swift:90`). `printedName`'s word split (`:363`) equals `spellingKey`
  (`:169`).
- **Archive folders,** listed three times:
  - `VaultReading.isArchiveName` (`:552`);
  - inline in `placement` (`VaultFacts.swift:195`);
  - `VaultReadPlan.recordFolders`, "archive" only (`VaultReadPlan.swift:122`).

  `supersedes` (`VaultFacts.swift:676`) and `vault-source`'s `sameCopy` call `isArchivePath` without the
  read folders, unlike the standings (`:488`).
- **Done when:**
  - identity readers take the per-page `PrintedPage` (`VaultReading.swift:139`);
  - each page is lowered and squeezed once per pass;
  - one `archiveNames` constant is shared;
  - `VaultCopies` takes the read folders;
  - a fixture's rows are unchanged.
- **Owner's call:** making `recordFolders` match. Account papers in `…/Archive/` are skipped today while
  `…/Archived/` and `…/Old/` are read.

**VT51 — Zone recovery proves less than it says.** *Checked.*
- **The problem.** The four layers are at `VaultReading.swift:794–919`. The weights 7, 3 and 1 are coprime
  to 10, so for one unknown in a checked field exactly one digit always passes: "only one fill passes" is
  a tautology. The passport's overall check re-tests the same residues, so it is not a second witness. A
  recovered date is constrained only by being a valid calendar date. `readWithPrintedNumber` (`:899`) is
  the one layer with an independent witness. No test reaches `readWithSwaps`' pairs branch (`:876–890`).
- **Done when:**
  - `MachineZone` carries how it was recovered (fill, swap or printed), and the caller logs a count;
  - the pairs branch and a G-series case have tests;
  - (**owner's call**) a recovered zone needs the printed number or date to agree, or is marked
    inferred (VT5).

**VT86 — Magic numbers and misleading names.** *Checked.*
- **Magic numbers.**
  - Render sizes 2400 and 4000, in three files' code and comments (`VaultDocumentReader.swift:125–126`,
    `:213`), and the clamp 2/6 (`:215`).
  - Ink and color thresholds 140/70 and 50/120/400 (`:300`, `:310`, `:319`).
  - Two unrelated `+ 15`s (`VaultReading.swift:485`, `:973`).
  - `10 * 365 * 86_400` (`VaultIDReading.swift:451`) and "ten years" twice (`VaultPrintedPage.swift:321`,
    `:337`).
- **Misleading name.** "Knows more" reuses `inkKeepsEverything`, a name that describes only the ink-only
  pass.
- **Done when:** each is a named constant and the shared rule has a neutral name.

**VT87 — `accountValue` as a tokenizer.** *Complexity; checked.*
- **The problem.** `accountValue` (`VaultAccountReading.swift:57–74`) is one hand-built regex with five
  lookaheads, and each of the last two reviews made it longer. VT89 lists what it still misses.
- **Done when:** a tokenizer (groups, separators, words; then the rules VT41 states) gives identical
  output on the test corpus and on the hash harness. Only then fix VT89's misses on it.

**VT80 — Dead code.** *Checked.*
- **Unreachable or unused:**
  - `"94"` in the form exclusion (`VaultReading.swift:260`) is unreachable: `formPattern` needs three
    digits.
  - The letter-keyed half of `numberSwaps` (`:841`) is unreachable.
  - `VaultFind.init(…sourcePath:)` (`:45–56`) is public and test-only.
  - `drawn(_ entry:)`/`drawn(_ find:)` (`VaultModel.swift:1112`, `:1118`) are test-only.
  - `settingsChanged()` (VT60).
  - `owner(of:)` and `subtitle(of:)` (`VaultPanel.swift:2322–2329`).
  - `readDocuments(again:)`'s `again` (`:2537`) is never passed.
- **Checks that always hold.** `VaultDocumentPreview.swift:90`: `shown` and `wanted == path` always hold,
  and `.onChange(of: shown)` (`:93`) repeats the task's own nil branch.
- **Done when:** these are gone, and the tests point at `masked(row)` and `opened()`.

**Vision's compiled model, missing.** Seen three times on 2026-11-20 while checking readers on the
owner's folder. For two to three minutes every text request failed, on the CPU as well:
`E5RT … create_precompiled_compute_operation … (Code: 13)`, after `Missing E5 bundle resource … Must
re-compile the E5` under `~/Library/Caches/com.abhishekgirish.SyncCloud/com.apple.e5rt.e5bundlecache`.
418 of 1,356 files came back unread in one run. Each time, a differently signed build (a test host, then
the signed one) had just made its first request; every build with the bundle ID shares that cache.
Read Documents inside such a spell reads no scan. Those files are not marked read, and the next read
takes them. The CPU fallback in `VaultFolderReader.recognised` helps only when the
Neural Engine alone refuses.

## G. Not internal: features that live in the roadmap

Kept so they are not lost; each changes what the user gets, so none is debt to pay down here.
- **VT5, an assurance level on every read** (checked, labelled or inferred): wants a visible mark (VF16,
  VQ4).
- **VT48, the read plan is tied to five folder names** (`VaultReadPlan.swift:77–78`, also inherited by
  `VaultKinds.teaches`, `VaultKinds.swift:174`). There is no Luhn, ABA, IBAN or routing reader, so the
  owner's `Finance/US` and `Insurance` are not read for accounts (VF20). Never read a card's security
  code.
- **VT49, fields the readers see and drop:**
  - date of birth, offered for no ID (now read on account rows too, since `996396e0b`);
  - the zone's surname and given names, flattened into `holder` (`VaultReading.swift:584–598`);
  - AAMVA address elements;
  - A-number, green card, EAD and SEVIS numbers;
  - pages past the third (`VaultDocumentReader.swift:25`).

  These become VT1's fields (VF10).

## H. Reader accuracy

Each row fixes a misread, so it changes what is read: each is an owner's call, needs a made-up page that
fails before the fix, a `VaultReading.version` bump and the hash harness.

| ID | Where | Defect | Status |
|---|---|---|---|
| VT46 | `VaultReading.swift:810–812`, `:840`, `:859–863` | A letter and the digit 10, 20 or 30 below its value add the same to every 7-3-1 check, so G↔6, L↔1 and U↔0 can never fail; a line with no unknown returns before the "eight digits + IND" rule runs. `G1234567` is accepted as `61234567`; the fixture's own `U5054030` (`VaultReadingTests.swift:120`) passes as `05054030`; `numberSwaps["6"] = ["G"]` and `"1"`'s `L` are inert, so G- and L-series Indian passports cannot be recovered. *Done when:* an IND zone of eight digits and `<` at position 8 is read with the letter that keeps the check. | **checked** by arithmetic |
| VT47 | `VaultReading.swift:819` | `fills = "0123456789<"`: with one unknown in the number field exactly one digit passes, so `Z` read as `Ž` becomes `5`. Letters in the fills make every single-unknown fill ambiguous (5, F, P, Z all pass), so it is rejected and left to `readWithPrintedNumber`: fewer numbers offered. Measure with the harness. | **checked** |
| VT53 | `VaultFacts.swift:670` (`supersedes`) | Two readings of one number under different kinds are ranked by date, detail count and file order, never by which kind is more specific; `vault-source` lengthens the key but adds no kind. A mortgage number a cover sheet labels "Account Number" (Other) on page 1 and "Loan Number" on page 2 is given as Other. | seen on the owner's folder |
| VT88 | VT40's remainder | A full page of typed text that gives a number is trusted where its scan holds more (11 of 203 pages); where both readings give one number alike, the picture's words speak for it (a misread name over a typed one); a page kept both ways makes a one-page file's sources say "page 1", and a zone from the second reading is numbered past the last page; scans stored as inline images or annotations are not seen; ink-only is read at 2400 px where the first read needed 4000; `zeroed` applies to Vision's lines only and takes `Ø` beside any digit (`Ø12 mm` → `012 mm`). | open |
| VT89 | VT41's remainder | A second run of three or more digits (`12345 987654321`); a last group of one or two digits before a word (`1234 5678 90 Due`) or a suffix before a name (`123456789 01 ANNA`); a last group holding a letter (`1234 5678 A1`); two groups that look like a phone number (`123456 7890`); non-ASCII dashes or spaces. After VT87. | open |
| VT90 | VT42's remainder, `VaultIDReading.swift:569` | `card = … \|\| ePAN`: any page that mentions an e-PAN is ranked as the card (`attach a copy of PAN card / e-PAN`). | open |
| VT91 | VT43's remainder | An Indian school or university that prints "Enrolment No" over fourteen or sixteen digits of its own. | open |
| VT92 | VT45's remainder | A checklist printing "Social Security card" alone above a number; a form number a scan broke (`Form W 4`, `Forms W-2 and W-4`) under the sheet's heading. `sheetCues`, `looseSheetCues` and `cardCues` are phrase lists on squeezed text, brittle to OCR drops. | open |
| VT93 | six minor rows, now **checked** | A state ID is titled a license unless `DAQ` rides the header line, and any other element there is dropped (`VaultIDReading.swift:109–116`); every receipt number on a page shares one form and holder (`:258–263`, `:282`); a barcode `DAQ` holding a space or dash is cut at it (`:157`); a mask of fewer than three X's reads as a full number (`VaultAccountReading.swift:131`); a garbled holder line on an unlabelled PAN card makes the father the holder (`panHolder`, `VaultIDReading.swift:607–621`); `admissionPattern` is case-insensitive, so lower-case s, d, l, g, b, o before ten digits can form an I-94 (`VaultReading.swift:315`). | open |

## Not debt

Do not "fix" these:
- search never matching the digits of a hidden number (extend it to last fours only, which are already
  drawn);
- numbers not being selectable text;
- no Trash for a removed number;
- Read Documents needing no proof;
- the Vault telling Ask Claude only that it is open;
- `window.sharingType = .none` hiding the whole window (VF9's design);
- a flat card-title menu (a SwiftUI submenu inside `.contextMenu` closes when rows change under it,
  measured);
- EXIF orientation (VT44).
