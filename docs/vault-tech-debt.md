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

### The 2026-11-23 review of batches 1–13

Two cold reviews of every batch so far. Acted on: batch 13 reworked before landing (the record
protocol out, the one choice path kept); batch 14: kinds behind a switch the compiler checks and
places as enums again (#2), a daily backup kept 30 days (#3), a sealed file created owner-only and
the unused `allowingDrops` gone (#5). Owner's calls taken: #3's 30 days; #4, read-only for an older
build, goes into the pre-v7.2 rewrite with a version stamp, not built on today's format. Left, with reasons:
- **`sessionLine`** stays in production code: tests read the model's own session lines because the
  shared log capture sees sibling cases (`a-logcapture-sees-sibling-cases`).
- **The reader protocol's three levels** (`pages`, `reading`, `noted`) stay: 13 test fakes
  implement `pages` only, 2 `reading` and 1 `noted`, and a reader that cannot tell notes nothing
  by design. The middle level could go (the model asks `reading` once, for a card; two fakes
  would move to `noted`); not worth it alone.
- **VT84's unexplained difference** (letters made at first use changed three of the owner's account
  papers): the shipped code makes them with the page, which matched; finding the cause needs the
  real-papers harness with Vision answering, which it was not on 2026-11-23 (e5rt error 13).
- **Leftover `.writing-` files and set-aside files** are not swept: the first only on a volume with
  no replacement folder, the second may be the only readable copy of something.

### The 2026-11-23 thorough review (after batch 14)

Four cold reviews (storage and security, the model, the readers, the panel), 27 findings. Batch 15
fixed storage's and the model's small ones:
- a passphrase backup is never written over another, not even the same day's (`… 2.scvault`
  beside it); Back Up Now carries the typed contacts, as the weekly backup did;
- a sealed file is flushed to the disk (`F_FULLFSYNC`) before it is swapped in, and its folder
  after;
- the backups kept beyond the newest ten are the first of each of the 30 most recent days that
  have backups, not a window around today's date: a clock off by years costs none;
- a card's values, a number corrected by hand and the household's contact details print nothing
  they hold (`VaultPrivacyTests`);
- the backup passphrase is changed in place, so a refused change keeps the old one;
- a key made for a save that then wrote nothing (Replace on a Mac whose key was lost) goes
  again, with what was set aside for it;
- Forget What "…" Taught redraws at once; a Refresh with nothing to open keeps when it ran; the
  person registry is made once per rows rebuild, not per saved ID and copy; the never-read
  `showsOlderFinds` is gone.

Checked and not changed: a removed ID typed in over a waiting one's reading already has its
document's path (`VaultEntry`'s init takes it from the facts), so it is set aside. The activity
list's ninety days are counted from now: a clock set months ahead empties it as a three-month
break would, and the two cannot be told apart; it holds no ID.

Owner's calls taken (2026-11-23): a number the Vault copied is cleared from the clipboard when the
Vault locks, not when the panel closes (batch 16); People joins an unmatched person's spellings by
first and last name (batch 17).

Batch 16 fixed the panel's, two of them visible by the owner's choice (the clipboard at a lock,
and Clear… in the activity list asking first): the sheets and popovers that draw a number, a date
of birth or a document's name, and Quick Look's panel while it shows a Vault document, are kept
out of screen sharing (`keptFromCapture`), and no tooltip carries a number, a date of birth or an
unmasked document name; People's document names are masked unless the ID may be shown; the moved
ID's note works out its ending when drawn; VoiceOver hears a row's Updated and Expires badges and a
folded card's summary; use in Quick Look's panel keeps the Vault awake. Left: copies of a name, a
phone or an address are plain (VT35), so a lock leaves them; a popover that holds no secret is kept
out of capture too, with the setting on.

Batch 17 fixed the model's: a read works out what corrected IDs' documents read for them and the
files an ID was taken off (Not for This ID) again before each file whenever the IDs changed
meanwhile, so a choice made during a read holds for the files it has yet to open; a waiting ID is
worked out again from its copies when People or a name corrected everywhere changes, as a saved
one is at every rows rebuild, so the member's own card speaks for it and a confirm keeps the right
person; People gives a name nobody in People answers to one section by first and last name,
titled with the spelling taken for the legal one, as its Name tile leads (two different people
whose first and last words match, neither in People, show together until one is added: a
hyphenated or suffixed name counts by its first and last words); and Confirm, when the editor
names a person the waiting ID was not given (Add to People re-splits it under the editor), works it
out for that person first, so the saved name, person and documents agree. The notes are worked out
again once the file being read has given its pages, so a choice about that very file holds too.

Batch 18 fixed the readers': a scan whose picture Vision refused keeps its text layer's number but
is not marked read, so the picture is tried again (`Reading.pictureUnread`); a page render and an
ink-alone copy stop at 4,000 pixels on the long side (a photo saved as a 72-dpi PDF was drawn at
8,064, about 195 MB a render); a sliver of an image no longer asks for gigabytes to sample its
color; the reading rules run off the main actor; and, by the owner's choice, a license barcode's
number is taken from right after its subfile type only ("DAQ" inside a name no longer hides it)
and a picture file of several pages (a faxed TIFF) is read up to three, as a PDF is.
`VaultReading.version` is 22: the waiting IDs are let go and the panel offers Read Documents again;
Refresh then reads the documents IDs came from, and Discover More the rest (where the license and
TIFF fixes find what was missed). Checked on the owner's read folder with the count-only harness
(1,356 files, Vision answering throughout): the same 544 numbers and mentions and the same 12 empty
files; the recognised text of 5 files changed with the new sizes, not one number (that run brought
the ink-alone copy down past 4,000 pixels; after review it is brought down only past 6,000, so a
phone photo's ink is judged as before). Left: a failed barcode decode or sharper read still looks like "nothing more" (no unread
mark); a test that the rules run off the main actor; a picture file's every frame counts as a
page (an animated GIF's too, at a Vision read each).

## Owed before the next cut

Read by [`RELEASE.md`](../RELEASE.md) §4 before a release is cut from `main`.
- **v7.2: VT3**, the migration that drops the never-shipped shims. The owner asked that it land
  before v7.2 (2026-11-22); it rewrites his sealed file once, so say so in the ask.
  VT1's stored shape (one record with typed fields) and VT6 (one sealed document) go into that
  same rewrite (owner, 2026-11-23), so his file changes once, not three times.
  The rewrite also stamps the file with the format version that wrote it, and a build that meets
  a higher one opens the Vault read-only, with a line saying a newer SyncCloud saved it; VT30's
  merging of a later build's records and fields then goes (owner, 2026-11-23, the review's #4).

## Order

1. ~~Wait for the branches in flight to land.~~ Done.
2. ~~**Safety net:** VT55, VT20, VT21, VT30, VT24.~~ Done (see Closed). A format change from here on
   adds a fixture beside the old ones (`VaultFormatTests`, `VAULT_WRITE_FORMAT_FILES=1`).
3. ~~**Internal bugs:** VT58, VT52, VT54, VT73 (a, c).~~ Done in batch 3. VT100, VT108 and VT73 (b) are the owner's call.
4. ~~**Efficiency.**~~ Done in batches 4 and 6, but for VT10's held key and `keyState()`, which go with VT31,
   and VT85, measured out.
5. ~~**Tests and logging.**~~ Done in batches 5 and 7, but for VT23, whose every addition is a new
   Activity line: the owner's call.
6. **Structure:** ~~VT8~~, VT7 (part, batches 9 and 10), ~~VT69~~ (the first step of VT1), VT1 (part, batch 13; the stored shape with VT3 and VT6), ~~VT2 with VT4~~, VT3 (before the v7.2 cut), VT6 (with VT3), ~~VT50~~ (batch 19), ~~VT87~~ (batch 20), VT75, VT76 (part, batch 11), ~~VT103~~, ~~VT106~~, ~~VT79~~, ~~VT80~~.
7. **Security:** VT34 (part, batch 19; the rest is drawn, the owner's call), ~~VT35~~ (batch 19); VT31 when VF7 is unblocked.
8. **Reader accuracy** (section H): each changes what is read, so each is its own owner's call.

### Closed since the first review (removed from the body)

| ID | Closed by | Left over |
|---|---|---|
| VT32 decrypt after proof, let go at lock | `c4e9b6a7c` (VF4) | VT60: the lock-off route (its dead `settingsChanged()` went in batch 11) |
| VT33 a way out of an unreadable Vault | `95510e947` (VF6) | VT56, VT57, both closed below |
| VT36 screen capture | `7131333ca` (VF9) | VT73 |
| VT40–VT43, VT45 reader bugs | `97e4f41ce`, redone `f7e441a7a` (v16) and `fd0377535` (v17) | VT88–VT92 |
| VT44 EXIF orientation | not a defect, measured 2026-11-20: do not re-propose | none |
| VT55 one sealed-file writer | `deb831324`, hardened by two reviews (2026-11-21): `SealedFile.write` makes the file owner-only before the swap (batch 14: creates it owner-only, `O_EXCL` at 0600, so no chmod is needed first), logs a refused chmod, writes through a link to the file and replaces a dangling one, and falls back to a temporary file beside it (no leading dot) on a volume with no replacement folder; the store, backups, reading file and activity list use their injected `FileManager` (the app passes `.default`); the backup seals through `VaultFile.sealPlain` with its header as the marker | a crash mid-write on a volume with no replacement folder leaves its `<name>.writing-<UUID>` behind, unswept |
| VT20 rolling backups | `deb831324`, then three reviews: ten `vault-backup-<count>-<UTC time>.sealed` beside the Vault's (batch 14: and the first backup made on each of 30 days, the Vault as the day began, so a busy day cannot push every older copy out; owner, 2026-11-23. Batch 14 counted the days around the newest backup's date; since batch 15 they are the 30 most recent days that have backups, so a wrong clock costs none), ordered by a count that only grows (a clock put back cannot prune the newest; `deb831324`'s `vault-backup-<time>-NNN.sealed` names sort as the oldest), pruned only after the new file is in, and not written again when the newest already holds those bytes; only a whole name of either shape counts as a backup (a Finder copy is not), so nothing else is ever pruned; a save removing more than one *ID* throws `wouldDrop` (the `allowingDrops` escape nothing used went in batch 14). Set It Aside and Start New takes the backups with the Vault (for a damaged file they may be the only readable copies); Replace keeps them and first keeps the Vault as it stood, so Go Back reaches past it; a new key is made only after a lost key's backups, reading file and activity list are set aside, and they go back if the Keychain refuses the key | VF6 reads `store.backups` |
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
| VT73 (a, c) screen-capture gaps | batch 3: a date of birth People draws in full counts as an ID drawn in full (`VaultModel.drawsAnIDInFull`), and a window that arrives after the panel first decided is set as it arrives (`VaultActivityWatch.exposed`) | (b), the Quick Look panel of a Vault document, is the owner's call |
| VT102 `expiresSoon` repeats `hasRunOut` | batch 4: one `VaultReading.daysLeft`, which both use, on calendars kept (UTC, and the zone last asked); pinned against the old rule and the old count over 121 hours in three zones | none |
| VT65 one action, one seal | batch 4: Confirm, Add and Edit run inside `sealingOnce`, so the reading file is sealed once at their end (Confirm with Everywhere sealed it up to four times), and a release inside one still seals first; pinned for all three by a disk that counts the seals | none |
| VT94 leaked test plists | batch 5 (2026-11-21), the goal changed by decision: each Vault test's defaults suite is recorded with the shared ledger (`vaultScratchSuite`), whose sweep at a later test run's start, or the hourly sweep of stale scratch plists, deletes it (2,358 had piled up). Never wiped per test: that waits on cfprefsd under a global lock on the main actor (testing laws). The trade: cfprefsd keeps those domains cached until it restarts, as bare suites always did | no test can tell the ledger record was dropped (the hourly sweep cleans up anyway) |
| VT105 name-role tests | batch 5: the lock is taken in the test that says so, the passport test requires its spelling, the repeat is gone, and roles are shown to outlive a change of reader rules (a later shape: VT30's `unreadFields`) | none |
| VT95 tests that cannot fail | batch 5: the activity bounds each tested alone (on stored events too), the clipboard's time on settings of its own and the app's path the same, the banner test's unused render gone, the People titles pinned to the one list given, the backup test and doc comment saying what they can show (a changed salt or work factor derives another key; the test changes the salt) | none (`drawn(_:)` went with VT80, batch 11) |
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
| VT98 one Vault test kit | batch 7: `VaultTestKit.swift` holds the fake keychain and proof, the scratch folder and defaults suite, the clock, the rig and the shelf; Sync's suites use it through their old names, and `project.yml` compiles it into the app's tests, whose own keychain, proof and shelf fakes are gone | the narrower document fakes stay with the suites they serve |
| VT29 lock under time | batch 5 (every route sealed shut, files byte-compared), batch 7: `VaultLockTableTests` runs every Ask × Relock setting against open, use, idle past the limit, close, reopen, sleep, Lock Now and a proof answered after a lock, 88 rows with the lock off, asserting open, loaded and proofs asked against limits and close rules written out in the test (a rule changed in the settings goes red); under "For every number" the proof answered after a lock is a number's own | a change of lock settings while open is not a row |
| VT27 app-side tests | batch 7: copying a number (its markers, cleared when its time is up, never once something else was copied, cleared on quit; on a pasteboard of the test's own, never the user's), the card's size, which window's use counts (`VaultActivityWatch.belongs`), and the reader's 60 MB limit, three pages and locked PDFs | whatever VT8 leaves in the view |
| VT22 session lines | batch 7: INFO lines for loaded (saved and waiting counts, how the lock is set), each proof (to unlock, for one ID, for a person's IDs) and its answer or its setting aside after a close or lock, each lock of an open Vault under "As soon as Vault opens" and why (Lock Now, sleep or the window closing, closed, idle, idle while closed, settings, restore), said once, and the numbers let go; never a title. Tests read the model's own lines (`sessionLine`), not the shared log capture | none |
| VT25 reader skips | batch 7: `VaultReadNotes` counts locked, unopenable and unrecognised, and pages read from their picture, rendered sharper or taken in their ink alone; `VaultDocumentReading.noted(_:)` returns them, and both read summaries end with what is not zero | too-large files stay counted in the walk's own INFO line, not in the summaries; a refresh still opens a known document whatever its size, as before |
| VT8 display rules in the view | batch 8: the row's title and line under it, the detail's lede, its kind's name and note, its number's label, what VoiceOver says, the folded summary, the Belongs To tag and Large Type's heading are public in `VaultRowText.swift`, on the row and beside it (`VaultMask.spoken`, `VaultAssignment.tag`), and the screen-capture rule is `VaultModel.drawsAnIDInFull(layout:editing:)`. Proof: each moved body reviewed against `origin/main` line by line; `VaultRowTextTests` pinned their literal output on the view's own functions first (Large Type's heading after) and passed unchanged on the moved ones, and `VaultRowTextBranchTests` covers the labels, titles and dates the app's test does not reach. Sync's two other " case" strips now use `kindTitle` | Escape's order and `save()`'s Add-to-People branch stay in the view, which owns that state; Large Type's lines map onto a view type |
| VT69 the user's choices as one value | batch 9: `VaultChoices` (pin, whose, used in, card, copy read from) is stored in `VaultFind` and `VaultChoice`, flat under the keys each always used (a find's copy `chosenSource`, a waiting choice's `source`); `VaultEntry.choices` and `Draft.choices` read and set it over their own fields; both re-makes are `keepingChoices(of:)`; a typed-in number takes what was chosen while it waited with `or(_:)`; `confirm` hands the copy read from and the name read in the `Draft`, so `add` takes neither loose; `Item` is gone, the rows are built as `Row`s. Proof: a throwaway harness encoded 432 finds, their waiting choices and entries (every choice set and unset), a reading state, and stored shapes (an older build's `older`, the household, a later build's card) decoded and sealed again, on `origin/main` and this tree: key-sorted, byte-identical (key order unsorted varies run to run, the unchanged `VaultEntry` too); a wrong-typed choice still fails to decode. `VaultChoicesTests` fails when a choice is left out of any record | `VaultEntry` keeps its fields, whose stored keys (`older`, `household`, `personID`) are not the choices' shape: a new choice is one field there and one line in its `choices` |
| VT79 a process-wide retroactive conformance | batch 11: Restore's passphrase sheet takes a `BackupFile` (`Identifiable`, by the file's address); `URL` is `Identifiable` nowhere | none |
| VT103 People's groups by name | batch 11: each person's kinds are keyed by person and group id (`PersonKind.ID`), the made-up group for kinds in no group being the one nil; the sort looks each card's place up once (`VaultRowFilterTests` pins a group named "Other" beside it) | none |
| VT106 small duplications from the People work | batch 11: `VaultCard.isShown(_:at:)` is every keyed popover's binding (Color, a name, a birth date); `fileName(_:)` is the row's document's name for the three places that said it; the stale doc reference went in batch 10 | none |
| VT80 dead code | batch 11: gone are the `"94"` the form pattern cannot match, the letter-keyed half of `numberSwaps` (only a leading digit is looked up), the test-only `drawn(_:)` pair and `settingsChanged()` (their tests check `canShow` and `masked(row)`, and the setting change through `opened()`), the unused `owner(of:)`/`subtitle(of:)`, the panel's never-passed `again`, and `VaultDocumentPreview`'s two checks that always hold | `VaultFind.init(…sourcePath:)` goes with VT3; the preview's `.onChange(of: shown)` stays: it lets the rendered scan go the moment the number hides, before the task runs |
| VT2 kinds as data | batch 12: `VaultKindSpec.all` is one row per kind, in the main view's order: its names, symbol, People's name for its paper, whether its ending is hidden, how its number is printed, its home folders, its starting group, whether it is an account, whether one read with no name is the household's (its default owner), the words of its row's line and Large Type label, where it is used, what it is weighed against, and what becomes of the newest of its group (a run-out visa and a decided case to Archive). `VaultCategory` stays the stored id (`spec`); `mainView`, `changeable`, `accountCategories` and `VaultGroups.default.groupOf` are made from the rows, the app's groups and their colors from `VaultGroupSpec.all`, and a household's card's title and symbol through `VaultKindSpec.custom(_:)`. Proof: a throwaway harness wrote every kind's every rule (titles, symbols, printing, placement over 13 paths, where used over 35 sets of facts, a row's title, line, label, spoken and lede over 12, standings over 16 inputs per kind and all kinds together) and, with batch 10's rows harness, every row, view, count, card and People section across each tab, person and country, on `origin/main` and this tree: identical (1,507 and 1,369 lines; two rules mutated, 18 lines differ); and the panel in each layout under six person and country choices, byte-identical PNGs (18, all distinct). `VaultKindSpecTests` pins each row's words, places, account and household kinds, groups and how a newer one replaces another | a new kind is a case, a row and a reader; since batch 14 `VaultKindSpec.of(_:)` is a switch, so a case with no row does not compile (it was a dictionary lookup that stopped at first use). Validators stay in the readers, which check what they read. Left in code: the readers' own kinds (`VaultReading`), the rules that join kinds (a visa in an older passport, a visa read with no name taking its passport's person, an ITIN given way to an SSN, a license's address), and `VaultEntry.Kind` with `from(kind:title:)`, which go with VT3. A field template is VT1's |
| VT4 places as data | batch 12: `VaultGeo` has a country's two-letter code or none for anywhere, stored by the names it always was (`us`, `india`, `anywhere`; an unknown one still fails to decode); batch 14 made it and `VaultGeoFilter` enums again, whose switches the compiler checks and which take a byte (the batch 12 structs held three strings); `VaultGeo.countries` is the list the Where and Used In choices, "N more in …" and "spans countries" go by, and `VaultGeo.home` where the household's addresses are used; `VaultGeoFilter` is one country or all (`showing(_:)` a country's); "N more in …" takes the first other country in the Where choice's order with any, "spans countries" is two or more, and the country chip's spoken name is the country's title. Proof: as VT2's, with each country's view in the rows harness and the panel shots | which country a paper is used in is still its kind's rule: a visa's and a license's by their issuer's three letters (USA, IND), each kind with its own words. A third country takes a `VaultGeo` case with its code and title, its place in `countries`, a `VaultGeoFilter` case (a test checks each country has one) and those rules; no test has one |

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

**VT6 — Fewer homes for state.** *Open, and worse; goes into the one rewrite of the owner's file before the v7.2 cut, with VT3 and VT1's stored shape (owner, 2026-11-23).*
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

**VT3 — Drop shims for builds that never shipped.** *Open; owed before the v7.2 cut (owner, 2026-11-22), in one rewrite of his file with VT1's stored shape and VT6 (owner, 2026-11-23).* Held back until near the cut: a build made before the migration reads none of the rewritten records and shows the Vault empty, with nothing saying why, until it is rebuilt.
- **The problem.** These remain:
  - `VaultEntry.Kind` (`VaultEntry.swift:11`), `older` (`:55`), `kind` still encoded (`:107`) and kept
    by the `category` setter (`:97`);
  - `VaultCategory.from(kind:title:)` (`VaultFacts.swift:90`, sniffing the title);
  - `Draft.init(…kind:)` (`VaultModel.swift:119`) and `VaultFind.init(…kind:…sourcePath:)`
    (`VaultReading.swift:44`).

  `Draft.kind` (`:98`) and `VaultFind.kind` (`:59`) have no production reader. `VaultEntry.dated` and
  `sourcePath` duplicate `facts.dated` and `facts.primary.path` (`:121–124`).
- **Done when:** one migration rewrites the owner's file, and the shims and their tests are gone.
  That same migration writes VT1's one record with typed fields and VT6's one sealed document, so
  the file changes once.
  Unblocked: VT20's backups and VT21's fixtures are in, and `chosenSource` has landed in the same
  `CodingKeys`. The migration saves with the short-list guard in force (it drops nothing; `allowingDrops`, which nothing passed, went in batch 14), adds a new
  fixture format, and keeps `vault-format-1` opening. A key taken out of `CodingKeys` is no longer one this build reads, so
  `VaultFile.openRecords` would keep it as a later build's field and seal it back: the migration
  strips the retired keys (`kind`, `older`, `dated`, `sourcePath`) itself, and drops
  `VaultRecords.stored` for them: an unchanged record is otherwise sealed back as it was stored,
  retired keys and all.

## B. The model

**VT1 — One record type with typed fields.** *Part done in batches 9 and 13, over the stored shapes; open: the record itself and its stored shape, which go into the one rewrite of the owner's file before the v7.2 cut with VT3 and VT6 (owner, 2026-11-23: the file changes once). Batch 13: the panel's five choices (Move to Current or Archive, Belongs To, Used In, Kind, Read from This Copy) are each one `VaultChoiceChange` set by one `choose(_:for:sealingWaiting:)` on a saved ID or a waiting one (`VaultChoosing`, the five fields both already have); it was first built over a `VaultRecord` protocol for rows and drafts too, which a review found was scaffolding the rewrite would replace, so that was taken out before landing. Proof: batch 10's rows harness, with the sealed Vault and reading file (key-sorted), the redraw count and every ID's drafts added after each of its 27 steps (every panel choice on a saved ID, a waiting one and an id that is nobody's, and an editor Save), and an older build's marks (`older`, a person beside `household`) through each, on `origin/main` and this tree: identical. `VaultChoosingTests` pins one seal for Kind on a waiting ID and nothing done after a refused save.*
- **The problem** (as first found; `Item` is gone, and the panel's choices are one path).
  One record had seven shapes:
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

  VT69 (Closed, batch 9) was the behaviour-preserving first step.

**VT7 — `VaultModel` does four jobs.** *Part done in batches 9 and 10; open: the walk and the read plan, which stay in `readDocuments`. Batch 9, (c): `VaultReadRun` holds a read's progress, its settle rules and its tally (`VaultReadRunTests`); the loop body is one `look(at:)` with one advance after it, and the refresh and discover tails end in one `finishRead`. Batch 10, (a), (b), (d): `VaultSession` holds the lock, its epoch, whether the panel is up and whether a read holds the numbers past a lock, and decides what each end of access does (`VaultSessionTests`); `VaultReadingState.opened(generation:people:)` is what a load takes from the reading file, which the model holds (`hold`) and seals again (`sealedReading`) (`VaultReadingFileTests`); `VaultRowSource.rows()` works the rows out from the numbers, readings, corrections, lessons, kinds, folders and day, with `VaultHolders` (whose a paper is) shared with a waiting number's rebuild (`VaultRowSourceTests`); `VaultRowFilter` works out the visible rows, cards, counts and People's sections from the rows and the search, tab and choices (`VaultRowFilterTests`). Each is tested with no model, but for one round trip through a model (what it took is what it seals). Proof: a throwaway harness drove five made-up scenarios (27 steps, every row field, each tab, filter and search), seven reading-file variants (state and the file sealed after), the five lock settings through 32 steps, and six reads across a close, a reopen, the Mac locking, a restore and a card read around Lock Now under three relock settings (state, log lines, redraw count) on `origin/main` and this tree: identical, custom kinds' random ids numbered, but for one redraw signal fewer as a load sets its waiting numbers once, not twice, in one call. The walk stays: it is awaits with a lock check between each, and moving it changes where a read can stop.*
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

**VT75 — Duplicated view code.** *Part done in batch 8: the "Nothing here for these choices" state is one view (`hiddenByChoicesState`), the panel's " case" strip is `Row.kindTitle`, and the standing and Remove menu items went with the ⋯ menu (`e17c98c3a`); the 30 panel renders the app's tests make were compared byte for byte before and after, by hand (a throwaway run, not kept); none of them shows that empty state, which is identical by reading. Open below: "N More in …" (two stylings), the card chrome, the holder heading (now `largeTypeHeading` and `detailLede`, side by side in `VaultRowText.swift`), the registry built twice, the Copied timer in Large Type, the folder panel, `actionBar`'s lookups, and the two color pickers.*
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

**VT76 — View state that duplicates the model's.** *Part done in batch 11: the model keeps the layout (`vaultLayout`; the older `vaultShowsList` read, not saved over) and follows a change to it while the app runs, such as Reset All, without saving it back; Large Type's ID and lit line are one optional.*
- **Open.**
  - People are held both as the panel's `people` prop and as `model.people`. The prop is fresh from the
    host every frame; `model.people` is set only once the panel's task runs, after its first frame.
    Drawing from the model's needs the host to set it before every way the Vault opens.
  - `namingKindFor`/`newKindName` and `copied`/`copiedDetail` stay pairs: one optional would blank the
    name field as its sheet slides away, and copying an ID then one of its details shows both
    "Copied" for their two seconds today.
  - `readFolders` is re-read in four places.

**VT81 — Size and type caps apply to Discover only.** *Checked; owner's call.*
- **The problem.** `largestFile` and `extensions` are enforced in `walk()` (`VaultDocumentReader.swift:55–57`).
  Refresh opens `refreshSources` directly, so a source that grew past 60 MB is still read.
- **Fix.** Check both in `pages(in:)`.
- **Owner's call:** this changes what Refresh reads, for files over 60 MB only.

**VT11 — Stale comment.** *Closed in batch 3: the comment went with VT73's change.* `VaultActivityWatch` says "every window has a Vault of its own"
(`VaultPanel.swift:3105` at `710b5aaa3`); the app is one `Window` scene (`SyncCloudApp.swift:553`).

## D. Tests

There were **416** `@Test`s at `0409895c8`: 374 in 30 `Sync` files and 42 in 8 `SyncCloudTests` files (since then `VaultFormatTests`, with 46, and more in `VaultBackupTests`, `VaultRefreshTests`, `VaultNameCorrectionTests`, `VaultPeopleViewTests`, `VaultReadDocumentsTests`, `VaultReadingTests` and `VaultKindsTests`). None is
parameterised. Three are machine-pinned to text recognition and skip on hosted CI
(`VaultFolderReaderTests.swift:257`, `:277`, `:291`).

## E. Security and privacy

What is sound and should stay:
- **Sealing.** AES-256-GCM with the marker as authenticated data; a random key, never synchronised; 0600
  files; "never write over a file this Mac cannot open".
- **Keyed fingerprints.** HMAC-keyed set-aside fingerprints and the lock-off seal.
- **The lock.** The session's epoch (`VaultSession`) discarding late proofs, and nothing loaded before a proof (VF4).
- **What prints.** Masked `description`s and empty mirrors.
- **The clipboard.** A concealed, host-only copy, cleared after the set time, at a lock and on quit
  (closing the panel keeps it, so a copy can be pasted after: owner, 2026-11-23).
- **Screen capture.** The Vault's window while an ID is drawn in full, and the sheets, popovers and
  Quick Look panel that draw a number, a date of birth or a document's name; no tooltip carries
  one (batch 16).
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

**VT34 — Endings are secrets for some kinds.** *Part done in batch 19: every description that knows
its kind (`VaultEntry`, `VaultFind`, `VaultMention`, `VaultStandingInput`, `VaultModel.Row`,
`VaultModel.Draft`) prints a Social Security number or an Aadhaar hidden whole
(`VaultMask.described(_:as:)`), as its row draws it locked; one that knows no kind and can hold one
(`VaultReadAs`, `VaultCardValue`, a detail's number) prints none of it; a correction prints no file
name, and a page's reading (`VaultPageSource.Reading`, `PrintedPage`) no line (`VaultPrivacyTests`). A draft whose Kind was changed in the editor prints as its new kind. Open, the owner's
call, as each is drawn: an activity line's title, which `VaultModel.record` cuts to its ending as a
file's name is cut, and the note that a document reads differently now (`VaultPanel.swift`,
"Its document reads differently now").*

**VT35 — One copy path.** *Done in batch 19 as it was: the panel's two plain copies (`copyString`: a name
in People, a contact card's phone, email or address; and a detail that is not a number) go through `VaultPasteboard.copyPlain`, the same write as before:
neither concealed nor cleared, relayed by Universal Clipboard. A source scan finds no `NSPasteboard`
in `VaultPanel.swift` (`VaultAppPiecesTests`).*
- **Owner's call:** whether names and dates are concealed and cleared too.

**VT60 — Lock routes left after VF4.** *Checked.*
- **The problem.**
  - With the lock off, nothing ever lets the numbers go.
  - ~~`settingsChanged()` had no app caller~~ (Settings and the Vault are never open together, and
    `opened()` re-reads the settings): gone in batch 11.
  - Turning the lock off sets `requiresAuthentication = false` without checking that `sealOff` worked
    (`VaultSettings.swift:445–447`; `VaultLock.swift:240` returns silently). After a Keychain refusal,
    Settings shows the lock off while the Vault still asks.
  - The lock is scoped by whether anything was sealed when the panel opened, which keeps about 35
    older tests' meaning: an ID typed into a Vault that opened empty stays loaded until close ("Added.
    Unlock to see it."). Nobody has checked for a path that draws such a row before a proof.
- **Done when:**
  - ~~`settingsChanged()` and its test are gone~~ (batch 11, VT80: the test checks `opened()`);
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

**VT50 — Duplicated toolkit.** *Done in batch 19, but for two changes that change what is read.*
- **Done.**
  - The identity readers take the page's `PrintedPage`, made once per page in `VaultReading.read`
    and shared with the zone, receipt, admission, travel and account readers; its `text` and
    `spacedSqueezed` replace five joins and seven squeezes a page, and the five `PrintedPage`s
    readers made of their own. `spacedSqueezed` joins the lines by a space, as the identity
    readers always have; `squeezed`, which the other readers use, by a line break. A line that
    starts with a combining mark or a joiner, or ends with a prepended sign, squeezes differently
    in the two (a review found it), so each reader keeps its own. `wantsSharperRead` now makes a whole `PrintedPage`, one pass more per
    page than its squeezes. `MachineZone.sections` repeats the one page; `noticeKind` takes the text lowered.
  - The dates: one `PrintedPage.numeric`; the full-month rule (`fullMonthDates`) lives in
    `PrintedPage`.
  - The names: `titleCased` in `readingOrder` and `printedName`; one `letterWords` for
    `spellingKey`, `printedName`, `nameKey` and the born-name grouping.
  - The archive folders: one `VaultReading.archiveNames`.
- **Proof.** The count-only harness read the owner's 1,356 files on `origin/main` and this tree,
  hashing each page's lines and each find's title, number, note and every fact (JSON, key-sorted):
  identical, but for five files' recognised text, which Vision varies from run to run (no number
  changed). Sync's 850 Vault tests pass.
- **Owner's call, both change what is read:**
  - `VaultCopies` (`supersedes`, `sameCopy`) taking the read folders: a read folder that is
    itself in an Archive folder makes every copy there count as archived today.
  - `recordFolders` matching: account papers in `…/Archive/` are skipped today while `…/Archived/`
    and `…/Old/` are read.

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

**VT86 — Magic numbers and misleading names.** *Done in batch 19.* The render sizes and their scales
(`VaultFolderReader.readRender`, `largestRender`, `scales`), the ink and color thresholds
(`inkDarkest`, `inkGreyest`, `coloredApart`, `coloredBrightest`, `sampleWidth`), the two `+ 15`s
(`yearsAheadInName`, `zoneYearsAhead`), the ITIN birth gap (`bornBeforeNotice`) and the ten years
(`PrintedPage.longestTerm`) are named; `inkKeepsEverything` is `keepsEverything`: a text layer's reading
against its picture's uses it too. Tests keep their literal sizes, so a change of a constant goes red.

**VT87 — `accountValue` as a tokenizer.** *Done in batch 20.* `VaultAccountValue` reads the number a
label's line starts with run by run: the first group, then up to six more, each joined by one space or
dash, with a check for each thing that ends a number (a date, a phone number, a count, an
ordinal, an amount, a rate). `PrintedPage`'s label lookups take such a reader as well as a pattern. Its
letters are the old pattern's, ſ and K (Kelvin) included, as ICU's case-blind `[A-Z]` matched them.
Proof: a throwaway test ran the old pattern and the reader on 5,000,000 random strings of digits,
letters, ordinals, separators, combining marks and non-ASCII dashes and spaces, and 5,000,000 more
built from the shapes of dates, phone numbers, counts, ordinals and amounts, near misses included:
identical, and each of fifteen changes to the reader's rules turned it red. A review's own search of
about 270 million inputs found no difference either, and the harness on the owner's 1,356 files gave
identical finds. VT89's misses come next, on it.

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
| VT89 | VT41's remainder | *Done in batch 21.* A dash or space set in another character (an en dash, a minus, a no-break or thin space) reads as one, between the label and the number too; one or two digits before a word end the number when they count it (a unit of time or of what a bill measures, a time of day, a currency, "of", a month) or are tied to it; else they are its own when a suffix's "01" or the end of a number already in groups (`123456789 01 ANNA`, `1234 5678 90 Due`), and otherwise still end it (`12345678 12 Main St`; a prefix of letters is no group, and a lettered group never counts toward its own digits); `123456 7890` is no phone number beside a label (its area code is not set apart), though a line with no label keeps the looser check; a row's birth date is found after a number read with an en dash (still the value's first place on the line, as before). Left as they were, with reasons: a second run of three or more digits stays joined (all 28 such numbers on the owner's papers recur whole on another paper, their first part alone never); a last group holding a letter stays off (a plan's "5G", a rate's "E1", a term's "30Y", a date's "12JAN2025"). The owner's 1,356 files read identically before and after, so `VaultReading.version` is not raised. | done |
| VT90 | VT42's remainder, `VaultIDReading.swift:569` | `card = … \|\| ePAN`: any page that mentions an e-PAN is ranked as the card (`attach a copy of PAN card / e-PAN`). | open |
| VT91 | VT43's remainder | An Indian school or university that prints "Enrolment No" over fourteen or sixteen digits of its own. | open |
| VT92 | VT45's remainder | A checklist printing "Social Security card" alone above a number; a form number a scan broke (`Form W 4`, `Forms W-2 and W-4`) under the sheet's heading. `sheetCues`, `looseSheetCues` and `cardCues` are phrase lists on squeezed text, brittle to OCR drops. | open |
| VT93 | six minor rows, now **checked** | A state ID is titled a license unless `DAQ` rides the header line, and any other element there is dropped (`VaultIDReading.swift:109–116`); every receipt number on a page shares one form and holder (`:258–263`, `:282`); a barcode `DAQ` holding a space or dash is cut at it (`:157`); a mask of fewer than three X's reads as a full number (`VaultReading.accountNumber(_:)`); a garbled holder line on an unlabelled PAN card makes the father the holder (`panHolder`, `VaultIDReading.swift:607–621`); `admissionPattern` is case-insensitive, so lower-case s, d, l, g, b, o before ten digits can form an I-94 (`VaultReading.swift:315`). | open |

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
