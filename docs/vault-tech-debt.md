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
`0409895c8`; re-find by symbol. IDs (`VT…`) are stable: never renumber, cite them in commit bodies. Next
free: **VT99** (VT61 and VT62 were never used). **Checked** means the lines were read and the claim holds; **plausible** means inferred.

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

- **Landing today, not on `main` at `0409895c8`.** Rebase over them and re-find symbols before starting:
  - `vault-source-themed` `3e266c2b9`, "Read from This Copy". Adds `VaultReadFacts.spokenBy`,
    `VaultEntry`/`VaultFind.chosenSource`, `VaultChoice.source`, `VaultCopies.sameCopy/ordered/choices`,
    a longer `supersedes` key, and archived-by-every-top-copy. Optional fields only; no version bump.
    Touches VaultModel, VaultFacts, VaultReading, VaultEntry, VaultPanel.
  - `vault-read-again-line-themed` `448fe7543`: a refresh keeps its Updating line
    (`ReadingProgress.init` loses its `scope` default). Touches VaultModel.
  - `vault-whole-card-themed` `0d9244712`: whole-card color wash and the row lift. Touches VaultPanel,
    VaultCardColors.
- **Parked, this brief's own session.** Checkpoint `11b5a7218` on `claude/vault-tech-debt-590b19`
  holds VT20, VT21, VT24 and VT30. It was built before VaultBackup and VaultActivity existed, so it
  needs the corrections those items now carry.
- **None of the three sessions plans more Vault code** after these land. "Go Back to an Earlier Save"
  (VF6) waits on VT20; VF7 (key tied to Touch ID, which is VT31) is deferred by the owner.

## Order

1. **Wait for the three branches above to land**, then rebase.
2. **Safety net:** VT55 (one sealed-file writer), then VT20, VT21, VT30, VT24 (resume `11b5a7218`).
   Nothing else changes a sealed format until these are in.
3. **Internal bugs:** VT58 (the main-actor half), VT63, VT68, VT52, VT54, VT59, VT73 (a, c).
4. **Efficiency:** VT9, VT10, VT65, VT66, VT67, VT82, VT83, VT84, VT85, VT77, VT78.
5. **Tests and logging:** VT94, VT98, VT95, VT29, VT96, VT97, VT71, VT26, VT27, VT28, VT22, VT23, VT25.
6. **Structure:** VT8, VT7, VT69 (the first step of VT1), VT1, VT2, VT3, VT6, VT4, VT50, VT87, VT75,
   VT76, VT79, VT80, VT11.
7. **Security:** VT34, VT35; VT31 when VF7 is unblocked.
8. **Reader accuracy** (section H): each changes what is read, so each is its own owner's call.

### Closed since the first review (removed from the body)

| ID | Closed by | Left over |
|---|---|---|
| VT32 decrypt after proof, let go at lock | `c4e9b6a7c` (VF4) | VT60: the lock-off route and a dead `settingsChanged()` |
| VT33 a way out of an unreadable Vault | `95510e947` (VF6) | VT56, VT57 |
| VT36 screen capture | `7131333ca` (VF9) | VT73 |
| VT40–VT43, VT45 reader bugs | `97e4f41ce`, redone `f7e441a7a` (v16) and `fd0377535` (v17) | VT88–VT92 |
| VT44 EXIF orientation | not a defect, measured 2026-11-20: do not re-propose | none |

---

## A. Storage and format

**VT55 — One sealed-file writer.** *Duplication; checked.*
- **The problem.** There are now four sealed families:
  - `vault.sealed` (`SCVAULT1`);
  - `vault-reading.sealed` (`SCVREAD1`);
  - `vault-activity.sealed` (`SCVACTV1`);
  - the weekly `.scvault` backups (`SCVBACK1`), plus `*.set-aside-<stamp>` files.

  The first three share `VaultFile.seal/open` (`VaultStore.swift:111`, `:122`). The backup
  re-implements the encoder and AES-GCM (`VaultBackup.swift:87–95`, `:111`). The tail is copied four
  times: make the folder, `.atomic` write, `try?` 0600, warning (`VaultStore.swift:184`, `:215`,
  `VaultActivity.swift:111`, `VaultBackup.swift:244`). Two more defects:
  - `VaultActivityStore` hard-codes `FileManager.default`, so no test can fail its write.
  - The 0600 is set after the rename, and a failed chmod is silent.
- **Fix.**
  - One `SealedFile.write(_:to:fileManager:)` with the permissions set on the temporary file.
  - `VaultFile.sealPlain(_:aad:key:)` used by the backup, with its header as the AAD.
- **Done when:**
  - every sealed write goes through the one path;
  - the injected file manager is used everywhere;
  - a failed chmod is logged;
  - decrypting before and after gives the same JSON.

**VT20 — Rolling backups before every write.** *Open on `main`; built in `11b5a7218`.*
- **The problem.** `VaultStore.save` (`VaultStore.swift:182`) swaps the file and keeps nothing. A logic
  bug that writes a short list cannot be recovered from (one happened in development, `637c08706`), and
  a typed entry cannot be re-read from documents. The weekly passphrase backup does not cover the days
  between.
- **Done when:**
  - each save keeps the previous ten sealed files as one documented family beside the Vault's file,
    written through VT55's writer;
  - a save that drops more than one record at once is refused unless explicitly allowed;
  - a test shows the drop guard never blocks Restore: Replace saves after `setAside`, onto no file, and
    Add only adds;
  - `store.backups`, newest first, is what VF6's Go Back to an Earlier Save reads.

**VT21 — Golden sealed files.** *Open on `main`; two of four built in `11b5a7218`.*
- **The problem.** No test pins an on-disk format. The backup is the one format that must open in a
  later build on another Mac.
- **Done when:** committed fixtures for all four formats, each opened by every later build and
  re-sealed to the same decrypted JSON:
  - the Vault file and the reading file, under a fixed key;
  - a backup at `leastRounds` with a fixed salt and passphrase, where `VaultBackupFile.open` returns
    literal contents;
  - the activity list.

  Add a new fixture per format change and keep the old ones. `vault-source`'s optional fields need no
  new fixture: nil is not encoded.

**VT30 — One bad record must not close the Vault.** *Open on `main`; built in `11b5a7218`.*
- **The problem.** `[VaultEntry]` decodes as one array. An unknown `VaultCategory`, `VaultGeo` or
  `VaultPin` raw value from a later build throws, and the whole file reads as `unreadableFile`. Two more
  places share the failure:
  - `VaultBackupContents.entries` (`VaultBackup.swift:113`): one unknown value makes a whole backup
    "not a backup".
  - The activity list decodes an unknown kind as `.other` and re-seals it as `"other"`
    (`VaultActivity.swift:16`, `:107`), so a later build's kind is lost on the first append. Its test
    checks decoding, not preservation (`VaultActivityTests.swift:97`).
- **Done when:**
  - records decode one by one, and an undecodable one is kept as its JSON and written back untouched;
  - a backup restores every record it can read;
  - the activity list keeps an unknown kind's raw string;
  - the model exposes how many records need a newer SyncCloud (a panel line saying so is new copy:
    owner's call).

**VT24 — Failures that leave no trace.** *Open on `main`; built in `11b5a7218`, which needs one
correction.*
- **The problem.**
  - `VaultModel.load` catches the store's error without a log line (`VaultModel.swift:1506`).
  - `loadReading` answers `try? … nil` for a damaged reading file (`VaultStore.swift:205`), and
    `VaultFile.open` drops the `DecodingError` (`:132`).
- **The correction.** The reading file is **no longer disposable.** Since VF22 and `8e5613a50` it holds
  the owner's own decisions: `names` (name corrections) and `lessons` (Kind lessons)
  (`VaultReading.swift:1054–1101`). Its doc comment, "nothing in it is the user's own" (`:1051`), is now
  false. So a damaged reading file must be set aside, never reset, and the panel must not imply
  everything comes back with Read Again.
- **Done when:**
  - both failures are logged at WARNING with the file's size and marker only;
  - a damaged reading file is renamed aside, which never deletes, and raises the banner;
  - the doc comment says what the file holds;
  - VT6 decides where `names` and `lessons` should live.

**VT6 — Fewer homes for state.** *Open, and worse.*
- **The problem.** What the Vault knows now lives in:
  - four sealed files;
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
- **Done when:**
  - `load()` reconciles: a waiting find whose number is saved is dropped, and a test seeds both files;
  - saved and waiting records, set-aside fingerprints, `names` and `lessons` share one sealed document
    written in one atomic swap (the read index may stay apart: it is a cache);
  - UserDefaults keeps view preferences and settings only.

**VT56 — Restore ▸ Replace sets the Vault aside before it knows it can write.** *Bug; fixed
2026-11-21 by putting it back: `moveAside` answers what it moved and a failed save calls `putBack`
(`aReplaceThatCannotBeWrittenLeavesTheVaultInPlace`). Sealing before setting aside still waits on
VT55's one writer.*
- **The problem.** `store.setAside` runs (`VaultBackup.swift:306`), then `store.save` (`:310`). A
  refused Keychain or disk leaves the Vault renamed away. Settings then says nothing was changed
  (`VaultSettings.swift:420`), no `didRestore` is posted, and a model still holding the old list can
  write it back on its next add.
- **Fix.** Get the key and seal the bytes first: split `save` into seal and write. Then set aside, then
  write.
- **Done when:** a test with a refusing `KeychainStore` leaves `vault.sealed` in place. No behaviour
  change on success.

**VT57 — Restore ▸ Add What's Missing can bring back a second record with the same id.** *Bug;
fixed 2026-11-21: `VaultEntry.reissued()`, and `id` is `private(set)`
(`whatIsAddedNeverSharesAnIDWithARecordAlreadyHere`).*
- **The problem.** `held + contents.entries.filter { new number }` keeps each backup entry's `id`
  (`VaultBackup.swift:304`). Back up, fix a typo in a number, then Add Missing: the old number returns
  under the same id. After that:
  - `delete` (`VaultModel.swift:1720`, by id) removes both;
  - `update` edits the first;
  - `ForEach` sees duplicate ids.
- **Fix.** Give a restored entry whose id is held a fresh `UUID()`.
- **Done when:** a test covers it.

**VT58 — Backup key derivation: no upper bound, and on the main actor.** *Security and efficiency;
checked. The bound is in since 2026-11-21 (`VaultBackupFile.mostRounds`, eight times `rounds`;
`aFileThatAsksForAbsurdWorkIsRefusedBeforeAnyIsDone`); the main actor and the tests' full-strength
derivations are open.*
- **The problem.**
  - `VaultBackupFile.open` checks only `rounds >= leastRounds` (`VaultBackup.swift:104`). A `.scvault`
    whose header claims `UInt32.max` rounds runs PBKDF2 on the main actor. At 600,000 rounds ≈ 0.7 s,
    that is about 80 minutes of a frozen app; a backup folder may be a synced one.
  - The weekly backup derives at 600,000 rounds on the main actor as the panel opens
    (`backUpIfDue`, `VaultModel.swift:1310`, called from `VaultPanel.swift:244`, `:261`), and Restore ▸
    Choose does the same (`VaultSettings.swift:265`, `:377`).
  - The backup tests run five full-strength derivations through `VaultBackup.write` although their
    comment says they avoid it (`VaultBackupTests.swift:14`).
- **Fix.**
  - Refuse a header above a cap (e.g. 10 × `rounds`) as `notABackup`.
  - Derive in a detached task and await it.
  - Give `VaultBackup` an internal `rounds` parameter that tests set to `leastRounds`.
- **Done when:**
  - a 4-billion-round header is refused before any derivation;
  - no PBKDF2 call runs on the main actor.

**VT59 — Set-aside: the activity file is left behind, and the code lives in the wrong file.**
*Checked.*
- **The problem.**
  - `VaultStore.setAside(at:fileManager:)` moves only the Vault's and the reading file
    (`VaultBackup.swift:331`). After a missing-key set-aside a new key is made, and the old activity file
    is overwritten on the next append (`VaultActivity.swift:107`). That breaks "kept for the day its key
    turns up".
  - It is an extension in `VaultBackup.swift` only because VaultStore was another session's at the
    time.
- **Done when:**
  - the activity file moves with the others;
  - `setAside` lives in `VaultStore.swift`.

**VT3 — Drop shims for builds that never shipped.** *Open.*
- **The problem.** These remain:
  - `VaultEntry.Kind` (`VaultEntry.swift:11`), `older` (`:55`), `kind` still encoded (`:107`) and kept
    by the `category` setter (`:97`);
  - `VaultCategory.from(kind:title:)` (`VaultFacts.swift:90`, sniffing the title);
  - `Draft.init(…kind:)` (`VaultModel.swift:119`) and `VaultFind.init(…kind:…sourcePath:)`
    (`VaultReading.swift:44`).

  `Draft.kind` (`:98`) and `VaultFind.kind` (`:59`) have no production reader. `VaultEntry.dated` and
  `sourcePath` duplicate `facts.dated` and `facts.primary.path` (`:121–124`).
- **Done when:** one migration rewrites the owner's file (after VT20's backup and VT21's fixture), and
  the shims and their tests are gone. Do it after `vault-source` lands: it adds `chosenSource` to the
  same `CodingKeys`.

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
- **The problem.** The two hand-written `VaultFind(...)` re-makes (`VaultModel.swift:1943`, `:2120`) are
  where a forgotten new field silently drops a choice on every re-read; `vault-source` had to patch
  both. `Item` (`:458–476`) mirrors `Row` (`:310–360`) field for field.
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
  - "Advance progress, then continue" is written four times (`:1907`, `:1913`, `:1923`, `:1972`). One
    copy dropping `scope` is the bug `448fe7543` fixes.
- **Done when:**
  - (a) `VaultSession` owns lock, epoch, proof and release;
  - (b) the record store owns load, write and reconcile;
  - (c) a `VaultReadRun` value owns the walk, the settle rules and the tally, with one per-step advance
    and one `finish(scope:)`, tested with no model;
  - (d) rows, cards and people are a pure function of (records, people, filters, now).

**VT9 — The whole panel recomputes every second.** *Open; the cost is now measured by reading.*
- **The problem.** `tick()` assigns `now` every second, and `lock.expire` mutates `lock`, both
  `@Published` (`VaultModel.swift:1336–1340`; driven at `VaultPanel.swift:248–252`). `panelActivity()` →
  `used()` changes `lock` again up to once a second while the pointer moves, so the comment at `:1352`
  ("does not redraw the panel") is wrong. `VaultOverlay` and `VaultCard` observe the whole model
  (`VaultPanel.swift:41`, `:121`).

  One draw runs `cards` → `visibleRows` (filter, then sort with `localizedStandardCompare`) about six
  times:
  - `allFolded` three times in `searchRow` (`:593–598`) and once per card header (`:1038`);
  - `cards` twice in `cardsView` (`:962`, `:980`).

  On top of that, one draw runs:
  - `count(in:)` eleven times, four of them in `controlRow`;
  - `refreshSources` twice, a fresh `Set` over every source each time (`:479`, `:481`);
  - `elsewhere(card)` per card;
  - `peopleSections` in full, uncached.

  The cached `rows` still read UserDefaults and build `Calendar` components for their key on every
  access (`VaultModel.swift:407`). `vault-whole-card` adds a second `tint(of:)` per card.
- **Done when:**
  - `now` and `lock` publish only when a time-dependent output changes: the lock state, the
    last-ten-seconds countdown, a shown number's expiry, the day, the "ago" minute;
  - `visibleRows`, `cards`, counts, `peopleSections` and `refreshSources` are cached on (rows revision,
    query, tab, filters, layout, folded, kinds, groups), with the read folders a stored property;
  - a counting test sees one `computedRows` and one sort per change and none per tick.

**VT10 — Keychain round trips.** *Open, and worse.*
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

**VT63 — An "everywhere" name correction is sealed before the save it belongs to.** *Bug; checked.*
- **The problem.** `storedName` changes `names` and calls `saveReading` before `write(entries)`
  (`VaultModel.swift:1643` → `:1644` in `add`; `:1671` → `:1675` in `update`). If the write is refused,
  the panel says the change wasn't kept, but the correction is sealed and already renames every other ID
  read under that name.
- **Fix.** `storedName` returns the pending change, which is applied and sealed only after `write`
  succeeds.
- **Done when:** a test with a failing store shows `names` unchanged.

**VT64 — A removed ID's number lives on in the reading file.** *Privacy; checked.*
- **The problem.** `delete` (`:1705–1721`) leaves `copies[number]` (whole `VaultFind`s, value included)
  and the mentions `dropFinds` moved there (`:1695`). Set Aside (`:2208`), Confirm (`:2193`) and Edit
  (`:1681`) all clear them. As a result:
  - `refreshSources` (`:1410`) keeps opening the removed ID's documents;
  - typing the number back in re-attaches stale copies.
- **Fix.** `delete` drops `copies[key]` and those mentions, and seals.
- **Done when:** the sealed state holds no key for a removed number.
- **Owner's call (small):** the Refresh document count drops to the right number.

**VT65 — One action seals the reading file once.** *Efficiency; checked.*
- **The problem.** Confirm seals the whole reading file two or three times: `storedName` (`:1018`),
  `dropFinds` (`:1698`), and `confirm` itself, unconditionally (`:2196–2197`). `update` can do the same
  (`:1683`, `:1685`). Each seal is a Keychain read plus re-encoding every find, copy and the read index.
- **Fix.** Public operations mark the state dirty and flush once at their end.
- **Done when:**
  - a counting store sees one reading write per action;
  - the final file is the same.

**VT66 — Rebuilding rows repeats work per row and per comparison.** *Efficiency; mechanism checked,
cost plausible.*
- **The problem.**
  - A `PersonRegistry`, which tokenises every person's names, is built per row (`person(named:)` `:383`,
    `person(inPath:)` `:394`).
  - `VaultReadFacts.primary` sorts every source, lowercasing and splitting paths inside the comparator
    (`VaultFacts.swift:229–238`). It is called several times per row (`:514`, `:560`, `:591`), twice per
    comparison in `merged`'s sort (`:674`, `:702`), and inside the standings comparator through
    `archived` (`:486`, `:548`).
  - `lessonFolder` compiles a regex per folder (`VaultKinds.swift:167`).
  - With `vault-source`, `merged` runs up to three times per row that has two or more copies
    (`readSince`, then the automatic and the chosen merges in `sourceChoices`).
  - Rows rebuild on every `finds` or `copies` change: about once per opened file during a read.
- **Fix.**
  - One registry per rebuild.
  - `primary` as one O(s) pass, with placement worked out once per source.
  - The regex precompiled.
  - One merge per row, its result reused.
- **Done when:** a rows fixture gives byte-identical `Row`s and a counting test sees the work once.

**VT67 — Discover and Refresh stat files on the main actor, and Refresh stats everything at every
open.** *Efficiency; checked; cost unmeasured.*
- **The problem.**
  - `VaultReadPlan` is built on the main actor and calls `reader.modified` per account file, twice when
    the year comes from the date (`VaultReadPlan.swift:42`, `:166`).
  - `reader.stamp` runs per step (`VaultModel.swift:1910`) and `reader.exists` per path pointed at
    (`:2055`).
  - `refreshIfWanted` stats every source at every open. Its stats are off the main actor (`:1784`), but
    the cost on the owner's ~500 sources is unmeasured, and nobody has checked what happens to an iCloud
    file that is not downloaded: is it downloaded, or counted missing?
- **Done when:**
  - no stat runs on the main actor;
  - the open-time pass is measured on his folder;
  - a not-downloaded file is shown to be neither downloaded nor reported missing.

**VT68 — Stop and quit can lose up to 24 files' reads.** *Bug; checked.*
- **The problem.** State is sealed only every 25 opened files (`:1974`). `stopped(at:)` (`:1870`) and the
  `defer` (`:1817`) do not seal, and with the lock off nothing releases the model. Quitting after Stop
  therefore loses those finds and their stamps, although the comment at `:1387` says what was read is
  kept.
- **Done when:** a test that cancels at file 10 finds them on disk.

**VT70 — "Whose is it" is worked out in two places.** *Duplication; checked; owner's call.*
- **The problem.** The editor matches the name as read (`Draft(find, people:)`, `:136–143`). The row uses
  the corrected name and three inference passes: birth date, passport, folder (`computedRows`,
  `:498–564`). Confirm's save patches this only for a nil person (`VaultPanel.swift:2511`).
- **Owner's call.** One shared function is internal only if each caller keeps its own inputs. Letting
  the editor take the row's inferred person changes what Confirm offers.

**VT71 — Nothing pins the rows cache's invalidation.** *Tests; plausible.*
- **The problem.** Correctness depends on every input to `computedRows` bumping `rowsRevision`: `didSet`s
  at `:158`, `:237`, `:248`, `:304`, `:932`, `:984`, `:1109`, `:2151`, and by hand at `:730`, `:976`,
  `:1089`. `kinds` is `@Published` with no bump.
- **Done when:** one table test changes each input in turn and asserts the rows follow.

**VT72 — Activity titles are cut at their last slash.** *Bug; checked.*
- **The problem.** `record` masks with `VaultMask.fileName(what)` (`VaultModel.swift:1262`), which takes
  `lastPathComponent` first (`VaultEntry.swift:168`). "Chase / Mortgage" is listed as "Removed
  Mortgage"; a proof reason "show H-1B / I-797" becomes " I-797".
- **Fix.** A public `VaultMask.text(_:)` that masks the whole string.
- **Done when:** a test uses a title with a slash. The fix makes a wrong line right.

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

**VT73 — Screen-capture gaps.** *Privacy; VT36's remainder.*
- **The gaps.**
  - (a) *Checked.* The People view's Show beside a birth date proves `section.rows.first`
    (`VaultPanel.swift:1246`), and `canShowBirth` (`VaultPeopleView.swift:95`) then draws the date in
    full. Under "For every number", `exposesAnID` checks only `selection`, which is usually another row,
    so the window stays shareable.
  - (b) *Plausible.* Quick Look of a scan is `.quickLookPreview` (`ContentView.swift:1345`), its own
    panel. Only the main window's `sharingType` is set.
  - (c) *Plausible.* `onChange(…, initial: true)` can fire before `VaultWindowReader.Probe` has a window
    (`:2748`). `apply` then does nothing, and nothing re-applies it.
- **Done when:**
  - (a) `exposesAnID` counts a birth date drawn in full;
  - (c) the sharing is re-applied when the window arrives;
  - (b) the Quick Look panel follows the setting while it shows a Vault document. (b) is the setting's
    intent but changes what a share shows: owner's call.

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

**VT77 — Masonry measures every card twice per layout pass.** *Efficiency; plausible.*
- **The problem.** `sizeThatFits` and `placeSubviews` both call `measure`, with `cache: ()`
  (`VaultMasonry.swift:64`, `:70`).
- **Done when:** `makeCache`/`updateCache` hold the sizes keyed by column width.

**VT78 — Small allocations per draw.** *Efficiency; checked.*
- **The problem.** `VaultTintPalette.swatch` builds a new `NSImage` on every draw (`VaultCardColors.swift:56`):
  once in `kindRow` and eight per picker in Customize Groups. `tint.color` builds a dynamic `NSColor`
  per call (`:75`).
- **Done when:** nine swatches and eight colors are held in static storage.

**VT79 — A process-wide retroactive conformance.** *Complexity; checked.*
- **The problem.** `extension URL: @retroactive Identifiable` (`VaultSettings.swift:452`) exists for one
  `.sheet(item:)`.
- **Done when:** the URL is wrapped in a small `Identifiable` struct.

**VT81 — Size and type caps apply to Discover only.** *Checked; owner's call.*
- **The problem.** `largestFile` and `extensions` are enforced in `walk()` (`VaultDocumentReader.swift:55–57`).
  Refresh opens `refreshSources` directly, so a source that grew past 60 MB is still read.
- **Fix.** Check both in `pages(in:)`.
- **Owner's call:** this changes what Refresh reads, for files over 60 MB only.

**VT11 — Stale comment.** *Open.* `VaultActivityWatch` says "every window has a Vault of its own"
(`VaultPanel.swift:2717–2719`); the app is one `Window` scene (`SyncCloudApp.swift:553`).

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

There are now **416** `@Test`s: 374 in 30 `Sync` files and 42 in 8 `SyncCloudTests` files. None is
parameterised. Three are machine-pinned to text recognition and skip on hosted CI
(`VaultFolderReaderTests.swift:257`, `:277`, `:291`).

**VT94 — The Vault rig leaks a defaults plist per test.** *Checked.*
- **The problem.** `VaultModelTests.Rig` uses a bare `UserDefaults(suiteName:)` torn down with
  `removePersistentDomain`, which empties the domain but leaves its file (`docs/flaky-tests.md`, "Leaked
  defaults suites"). `VaultColorsTests.swift:11`, `VaultSharingTests.swift:7` and
  `VaultKindsTests.swift:217` have no teardown at all. There are 134 `Rig()` call sites.
  `~/Library/Preferences` held **1,221** `vault-model-tests-*` plists on 2026-11-21.
- **Done when:**
  - `ScratchDefaults` is used in all four places;
  - a Sync run leaves no new `vault-*` plist.

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

**VT95 — Tests that cannot fail.** *Checked.* Each one needs a version that fails when its rule is
removed:
- `theListIsBoundedInCountAndAge` (`VaultActivityTests.swift:74–84`): the 91-day event is also past the
  count limit, so deleting the age filter (`VaultActivity.swift:108`) stays green. Needs two events, at
  91 days and at 1 day.
- `aCopyIsClearedAfterTheTimeTheSettingGives` (`SyncCloudTests/VaultWindowPrivacyTests.swift:31–36`)
  compares `clearAfter` with the same `clipboardSeconds()` it is built from, against his live defaults.
  The same shape is at `VaultPanel.swift:2345`. Needs injected defaults holding 30 and literal
  `.seconds(30)` and "…after 30 seconds."
- The backup's "header is authenticated" test (`VaultBackupTests.swift:33–35`) flips a salt byte, which
  changes the key, so removing `authenticating:` stays green. No test can do better: reword the test and
  the doc comment (`VaultBackup.swift:43–44`) to "a changed salt or work factor derives another key".
- `afterAnUpdateTheBannerOffersDiscoverMoreUntilNotNow` (`VaultRefreshPanelTests.swift:129`, `:144`)
  renders a view and discards it.
- `VaultPeopleViewTests.swift:64–65` accepts either of two section lists for a deterministic output: pin
  the one it gives.
- `drawn(_ entry:)` and `drawn(_ find:)` are tested (`VaultLockTests:222`, `:303`,
  `VaultToConfirmTests:77`) but used by no production code, and they ignore `hidesEnding` (VT80).

**VT29 — Lock under time.** *Open, and wider.*
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

**VT96 — The backup's purpose is untested.** *Checked.*
- **The problem.**
  - `read(_:passphrase:)` is never called with a passphrase. So these are untested: the `.noPassphrase`
    branch, a wrong typed passphrase, and an old backup opening only with its old passphrase after
    `setPassphrase`.
  - The Settings side is not driven by any test:
    - `showActivity` hard-codes `VaultDeviceOwnerProof()` and the real store (`VaultSettings.swift:294`);
    - `RestoreOffer.message` and `message(for:)` (`:306–433`) are pure but untested;
    - the `backedUp` and `restored` activity lines are never loaded by a test;
    - nothing tests `VaultDeviceOwnerProof`.
- **Done when:**
  - Rig A writes a backup. Rig B, with its own keychain and no passphrase, gets `.noPassphrase`, then
    `.wrongPassphrase`, then the contents; `restore(.replace)` leaves B loading A's entries;
  - "prove, then load" moves into `Sync` (e.g. `VaultActivityStore.load(provingWith:)`) and is tested
    with a refused proof;
  - the two backup lines and the offer wording are asserted;
  - a backup is read back once after it is written (today nothing checks it opens).

**VT97 — The swatch-click test sleeps and shows a window.** *Checked.*
- **The problem.** Each click is followed by a fixed 150 ms sleep and then an assertion
  (`SyncCloudTests/VaultCardColorsTests.swift:205`, `:209`). The borderless window at (0,0) is ordered
  front and never buried (`:186–193`).
- **Done when:** `waitUntil` replaces the sleeps, and the window sits at `.minimumWindow` level.

**VT26 — A log test.** *Open.*
- **The problem.** None of the 38 Vault test files uses `LogCapture`. The Vault has 33 `Logger.shared`
  call sites, none asserted.
- **Done when:**
  - one test runs open → read → confirm → show → copy → edit → remove → lock → back up → restore on a
    fixture with a `LogCapture`;
  - it asserts every VT22–VT24 line and the backup, restore and unsealable-activity lines;
  - it asserts that no fixture number, holder name or file name appears;
  - it asserts sentences unique to the case (memory `a-logcapture-sees-sibling-cases`).

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

**VT28 — Privacy tests.** *Partly.*
- **Today.** Redaction is tested for `VaultReadFacts`, `VaultSource`, `VaultDetail`, `VaultMention`,
  `VaultStandingInput` and `Draft` (`VaultPrivacyTests.swift:26`), for `VaultFind`
  (`VaultReadingTests.swift:340`) and for `VaultEntry` (`VaultStoreTests.swift:229`).
- **Untested.**
  - Redacted but never tested: `VaultReadingState`, `VaultChoice`, `MachineZone`, `Row` and
    `VaultReadTally` (`VaultRedaction.swift:34–64`).
  - **Not redacted at all** (*checked*): `VaultDetail.Value` (`.number(String)`, `VaultFacts.swift:114`),
    `VaultChange` (`VaultRefresh.swift:25`, held in `@Published changes`, which prints `was` and `now`
    in full) and `VaultPersonSection` (`VaultPeopleView.swift:14`, names and birth dates).
- **Done when:**
  - those three are redacted;
  - every type above is in the privacy test, `dump` included;
  - nothing under a `vault*` UserDefaults key holds a fixture number after a full flow;
  - `VaultMask.fileName` gets a property test over generated numbers and separators;
  - the user-typed exceptions are documented: read-folder paths, and custom kind and group names in the
    clear.

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

**VT52 — Read Documents bypasses the PDFKit lane.** *Checked.*
- **The problem.** `PDFDocument(url:)` (`VaultDocumentReader.swift:102`), `page.string` (`:128`),
  `drawsScan` and `thumbnail` (`:213`) run on a detached task outside `PDFKitSerialAccess`, the one lane
  every other PDFKit caller uses. A Vault read running while filing or Ask Claude reads a PDF can get
  reordered or dropped text with no error.
- **Done when:**
  - each PDFKit call runs inside `PDFKitSerialAccess.run`;
  - Vision runs outside the lane, as `ContentSignalExtractor.swift:97` does. Not the whole `reading(…)`,
    which would hold the lane through about 1 s of Vision.

**VT54 — A file with one page left out is stamped read.** *Checked.*
- **The problem.** `read` counts `unreadable` but returns only the pages (`VaultDocumentReader.swift:110–136`),
  and `readIndex[file.path] = stamp` is written regardless (`VaultModel.swift:~1965`). The page is not
  tried again until the file or the reader version changes.
- **Done when:**
  - `pages(in:)` reports an incomplete file;
  - its stamp is withheld.

**VT82 — Render each scanned page once per size.** *Efficiency; checked.*
- **The problem.**
  - `inkOnly: { render(page)… }` (`VaultDocumentReader.swift:127`) renders at 2400 px again after
    `read(false)` (`:125`) rendered and dropped the same image. That happens on every page read from its
    picture, since `coloredShare` needs the render (`VaultPageSource.swift:174`): about 690 extra renders
    per full read of the owner's papers.
  - For a card-size page the scale is clamped to 6 (`:215`), so the 2400 and 4000 renders are identical
    and the "sharper" read re-runs Vision, about 1 s, on the same image.
- **Fix.**
  - Memoise `render(page, longSide:)` per page.
  - Skip `read(true)` when the two scales are equal.
- **Done when:** a counting reader in `VaultFolderReaderTests` sees one render per page and size.

  Do it with VT52. Feeding ink-only from the 4000 render when the sharper read was taken is a reader
  change (VT88).

**VT83 — Each page goes through the reader suite up to five times.** *Efficiency; checked.*
- **The problem.**
  - The passes: the typed layer (`VaultPageSource.swift:96`), the picture (`:116`), two more on colored
    paper (`:175–176`), and the per-file read (`VaultModel.swift:1933`). On colored pages, `:116`
    repeats `:175` or `:176` exactly.
  - `wantsSharperRead` runs `isSocialSecurityCard` twice and the SSN reader once per call. It is called
    up to three times per page, once only to word a debug line (`:172`).
- **Done when:**
  - `look` returns the finds it computed;
  - `wantsSharperRead` is computed once per page;
  - the readers' output is unchanged.

**VT84 — Label search rebuilds every line's letters per label.** *Efficiency; mechanism checked.*
- **The problem.** This is the whole CPU cost of reading a typed account PDF.
  - `labelHit` (`VaultPrintedPage.swift:110–134`) allocates a `String` per character per line per label.
  - `values(preferring:)` (`:276`) scans the page once per label, and `accountNumbers` asks about 57
    labels per page.
  - `groupNumber` is computed again per find (`VaultAccountReading.swift:116`, `:228`), as are the
    holder (`:225`) and a `PersonRegistry` (`:260`).
- **Done when:**
  - each line's squeezed letters and index map are computed once in `PrintedPage.init`;
  - each label is squeezed once;
  - group, holder and registry are hoisted out of the per-find loop.

**VT85 — Regexes compiled per line.** *Efficiency; plausible (Foundation may cache).*
- **The problem.** `range(of:options: .regularExpression)` is called inside loops at
  `VaultIDReading.swift:102`, `:412`, `:471`, `:584`, `:613`, `:704`, `:707`, `:750` and
  `VaultAccountReading.swift:137–138`, `:207`, `:264`. `labelledName` rebuilds its stop set per call
  (`VaultIDReading.swift:309`).
- **Done when:** each is a `static let`.

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
takes them (VT54 is the exception). The CPU fallback in `VaultFolderReader.recognised` helps only when the
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
