# Vault — technical debt brief

A prompt for the session that pays this down. It covers what is inside the Vault: the data model,
complexity, reader bugs, logging, tests, privacy and security. What the user sees and the feature
roadmap (VF1–VF20, VB1–VB14, VQ1–VQ6) are in the mockup artifact:
<https://claude.ai/code/artifact/60d12ecd-c5f3-4945-a098-2f0a9fc8c2a4>.

Reviewed at `3f953608b` (2026-11-20). Line numbers are from that commit; re-find by symbol.
IDs here (`VT…`) are stable: never renumber, and cite them in commit bodies.

## Read first

- `CLAUDE.md`, `COMMIT.md`, and the memory file `testing-laws.md`.
- **A parallel session is changing the Vault.** Worktree `.claude/worktrees/vault-overlay`, branch
  `vault-countdown`: custom kinds (`VaultKinds.swift`, `VaultCardID`, per-folder lessons), a countdown
  shown only in the last ten seconds, a blur under the Touch ID prompt. It edits `VaultPanel`,
  `VaultModel`, `VaultEntry`, `VaultFacts`, `VaultReading`. Do not start VT1–VT6 until it lands; then
  rebase and re-read those files. VT20–VT33 (logging, tests, store) touch other code and can go first.
- **The Vault has never shipped.** Its first commit is `e4990837e` (2026-11-18), after tag `v7.1`.
  The only sealed file in existence is the owner's. That makes a one-time format migration cheap now
  and expensive after the next release cut.
- Never log, print or assert on a number in full. Bump `VaultReading.version` whenever a reader's
  output changes (it raises the Read Again banner). Each refactor needs the behaviour-preservation
  proof from `CLAUDE.md` §5; for the Vault that means: same rows, same sealed JSON (decrypted and
  key-sorted) and same log lines on a fixture folder, before and after.
- Do not split a file because it is long. Every item below names a capability, a bug class or a
  missing test as its reason.

## Order

1. **Safety net** — VT20, VT21, VT30 (rolling backups, golden-file test, tolerant decoding). Nothing
   else changes the format until these are in.
2. **Bugs** — VT46 and VT47 (readers; VT40–VT45 are closed, see section G) and VB2, VB4–VB7 from
   the artifact.
3. **Logging and tests** — VT22–VT29.
4. **Security** — VT31–VT36.
5. **Model** — VT1–VT6, which unblock VF10–VF14.
6. **Reader clean-up** — VT48–VT51.

---

## A. Data model: one number per entry cannot hold what forms ask

**VT1 — One record type with typed fields.** Today the same thing has five shapes, copied field by
field: `VaultEntry` (`VaultEntry.swift:9`), `VaultFind`, `VaultModel.Row` (`VaultModel.swift:243`),
`VaultModel.Draft` (`:68`) and the local `Item` (`:365`). Adding `geo` meant touching all five plus
`VaultChoice`, `add`, `update`, `rebuilt` and both `Draft` initialisers. An entry is `value` + `note`;
structured details (`VaultDetail`) exist only inside `VaultReadFacts`, so a typed entry can never have
an expiry date, a second number or an address.
*Done when:* a single `VaultRecord` holds `fields: [VaultField]` (`number`, `secret`, `text`, `date`,
`phone`, `address`; each with label, value, `isMain`, `hidesEnding`), an owner, an origin
(`typed` / `read(sources)`), a state (`saved` / `toConfirm`), pin and place. `Row` becomes a derived
view of it and `Draft` an editable copy. Readers emit records. A typed record can carry any field a
read one can.

**VT2 — Kinds as data.** A kind is spread over `VaultEntry.Kind` (six legacy cases), `VaultCategory`
(13 cases, `VaultFacts.swift:7`), `chosenCategory`, `facts.category`, `VaultGroups`, and now
`VaultCardID` / `readAs`. Each `VaultCategory` case is switched on in at least eight places (title,
singular, symbol, kind, `VaultCard.idLabel`, `rowTitle`, `VaultGeo.read`, the standing rules).
*Done when:* one `VaultKindSpec` table gives each kind its id, names, symbol, field template, masking
and grouping pattern (`VaultMask.printed`'s SSN 3-2-4 and PAN 5-4-1), validator (check digit, Luhn, ABA,
VIN, Verhoeff), default owner (person or household), default place and expiry rule. App kinds and the
household's own kinds are rows of the same table. Adding "Bank account" is one row plus a reader.

**VT3 — Drop shims for builds that never shipped.** `VaultEntry.older`, `VaultEntry.Kind`,
`VaultCategory.from(kind:title:)` (sniffs "passport" out of a title), `Draft.init(title:value:…kind:)`
and the `usVisa` raw value kept "from when it held US visas alone" exist for sealed files only this
Mac has. *Done when:* one migration rewrites the owner's file (after VT20's backup) and the shims and
their tests are gone.

**VT4 — Places as data.** `VaultGeo` is `us | india | anywhere`; `elsewhere` and `elsewhereKinds`
compute "the other country" as `geoFilter == .us ? .india : .us` (`VaultModel.swift:523`, `:565`);
`countryCode` hard-codes two accessibility names (`VaultPanel.swift:703`). *Done when:* a place is an
ISO code or `anywhere`, the Where filter lists the places present, and nothing assumes two.

**VT5 — An assurance level on every read.** There is no confidence value: a passport number that
passed three check digits and a utility number found beside a label both land as "To confirm".
*Done when:* each read carries `checked` (a check digit or checksum agreed), `labelled` or `inferred`,
set by its reader, sealed, shown in the row, and available to VF16's "add all checked" and to VQ4.

**VT6 — Fewer homes for state.** What the Vault knows about a number lives in `vault.sealed`
(entries), `vault-reading.sealed` (finds, read index, mentions, copies, choices, `needsReadAgain`, and
lessons when the parallel session lands), `UserDefaults` (set-aside fingerprints and generation, read
folders, filters, folded cards, groups, own kinds, lock settings, lock-off seal) and the Keychain.
Two sealed files are written one after the other (`confirm` → `add` writes one, then `saveReading`
the other), and `load()` (`VaultModel.swift:896`) does not drop a find whose number is already saved,
so a crash between the writes shows the number twice, and a later read keeps the stale find
(`take` rebuilds an existing find before it looks at the entries).
*Done when:* saved records and waiting records share one sealed document written in one atomic swap
(the read index may stay separate: it is a cache); set-aside fingerprints move inside it; `load()`
reconciles; UserDefaults keeps view preferences and lock settings only.

## B. Model and panel

**VT7 — `VaultModel` does four jobs.** 1,512 lines holding the lock session, record CRUD, the
filter → rows → cards derivation, and Read Documents. The bugs fixed in `637c08706` (Remove saving an
empty Vault after an awaited proof, Edit crashing on a stale index) came from lock state and CRUD
interleaving in one object. `readDocuments` (`:1144`–`:1323`) is 180 lines with four nested functions
and five local dictionaries of account-settling state that belong with `VaultReadPlan`.
*Done when:* (a) `VaultSession` owns lock, epoch, proof and release; (b) the record store owns load,
write and reconcile; (c) a `VaultReadRun` value owns the walk, the settle rules and the tally, and is
tested with no model; (d) rows and cards are a pure function `(records, people, filters, now) → cards`.

**VT8 — Display rules live in the view, untested.** `rowTitle`, `rowSubtitle`, `detailLede`,
`idLabel`, `largeTypeLines`, `foldedSummary`, the esc layering (`escape`), and `save()`'s branch into
the Add-to-People question are in `VaultCard` (`VaultPanel.swift:120`–`:1991`), which has about twenty
`@State` values and no test. *Done when:* each is a pure function on the row in `Sync`, with tests;
the view only lays out.

**VT9 — The whole panel redraws every second.** `tick()` publishes `now` once a second
(`VaultPanel.swift:216`); `VaultCard.body` observes the model, and `cards` → `visibleRows` filters and
sorts on every call (only `rows` is cached), several times per draw. *Done when:* the countdown is its
own small view, the lock's expiry is a scheduled event, and `visibleRows` / `cards` are cached on the
same key as `rows` plus the filters. Re-check after the parallel session's countdown change.

**VT10 — Keychain round trips in loops.** `isNew` calls `store.fingerprint` for each read
(`VaultModel.swift:1471`), which reads the Keychain each time, as does every `save` and
`saveReading`; `take`, `accountNumbers` and `dropFinds` scan `finds` linearly with `normalized`
recomputed per comparison. *Done when:* a read holds the key for its duration (or VT31 makes the
question moot), and finds are indexed by normalised number.

**VT11 — Stale comment.** `VaultActivityWatch` says "every window has a Vault of its own"
(`VaultPanel.swift:2001`); the app is a single-window `Window` scene (`SyncCloudApp.swift:549`).

## C. Logging

Today the Vault logs Keychain refusals, write failures and Read Documents counts. It is silent on
everything else, which makes "it asked twice" or "my number vanished" impossible to diagnose.

**VT22 — Session lines** (INFO): opened (lock mode, counts by state, never titles), proof asked and
its outcome (`allowed` / `cancelled` / `failed` / `unavailable`, and whether it was discarded by a
moved `lockEpoch`), locked and why (idle, close, Lock Now, sleep, screen lock, settings), numbers
released from memory.

**VT23 — Record lines** (INFO): add, edit, remove, confirm, set aside, pin, assign, place: the kind
and whether it was read or typed. Shown and copied: the kind and field label only. These are also the
source for VF8's Activity view, so write them through one function that the view can read back.

**VT24 — Failures that leave no trace.** `VaultStore.load` throws `unreadableFile` /
`wrongKeyOrDamaged` and `VaultModel.load` (`:924`) swallows them with no log line.
`loadReading` (`VaultStore.swift:205`) returns nil for a damaged reading file: To Confirm and every
choice made on it disappear silently and `needsReadAgain` is not raised. Log both at WARNING with the
file's size and marker bytes, and raise the banner for the second.

**VT25 — Reader skips.** `VaultFolderReader` logs counts for oversized files and unopenable PDFs at
DEBUG only. Add to the read summary: files skipped by cause (too large, locked, unreadable, text layer
used, image OCR used, past page 3).

**VT26 — A log test.** One test runs open → read → confirm → show → copy → edit → remove → lock on a
fixture with a `LogCapture`, and asserts every line above appears and no fixture number, holder name
or file name does. Assert a sentence unique to the case (see the memory `a-logcapture-sees-sibling-cases`).

## D. Tests

254 `@Test`s cover `Sync`'s Vault code. Gaps:

**VT21 — Golden sealed files.** No test pins the on-disk format. Commit a sealed file and a reading
file made by this build with a fixed test key; assert every later build opens them and re-seals to the
same decrypted JSON. Add one per format change.

**VT27 — `MacApp/Vault` has no tests** (2,900 lines). At least: `VaultPasteboard` (concealed and
transient markers present, `currentHostOnly`, cleared after the interval only when the change count is
unchanged, cleared on quit); `VaultFolderReader` (60 MB cap, three-page cap, locked PDF; the
text-layer rule is now `VaultPageSource` in `Sync` with `VaultPageSourceTests`, and
`VaultFolderReaderTests` covers the scan check and one stamped scan read with Vision); `VaultCardSize.fitted`; `VaultActivityWatch` window scoping;
whatever VT8 leaves in the view.

**VT28 — Privacy tests are two.** Add: nothing in `UserDefaults` under any `vault*` key contains a
fixture number after a full flow; `vaultReadFolders` paths are the one exception and are documented as
such (a folder named after a number sits there in the clear; consider sealing the list);
`String(describing:)`, `dump` and `Mirror` of every Vault type that holds a number (`VaultFind`,
`VaultReadFacts`, `VaultDetail`, `Row`, `Draft`, `VaultReadingState`) print none; `VaultMask.fileName`
property test over generated numbers and separators.

**VT29 — Lock under time.** A table test over every `Ask` × `Relock` × event (open, use, idle past the
limit, close, reopen, sleep, settings change, proof answered after `lockEpoch` moved) asserting
`isOpen`, what is loaded in memory, and what a late proof may do. Today these are spread over 30 cases
with no matrix, so a new setting has no checklist.

## E. Store and recovery

**VT20 — Rolling backups before every write.** `VaultStore.save` (`VaultStore.swift:182`) swaps the
file atomically and keeps nothing. A logic bug that writes a short list (it happened once, in
development: `637c08706`) is unrecoverable, and typed entries cannot be re-read from documents.
*Done when:* each save keeps the previous N sealed files (same key, same folder, 0600) and refuses,
without an explicit flag, a write that drops more than one record at once.

**VT30 — One bad record must not close the Vault.** `[VaultEntry]` is decoded as one array of
synthesized `Codable`s: an unknown `VaultCategory`, `VaultGeo` or `VaultPin` raw value from a later
build throws, and the whole file reads as `unreadableFile`. The parallel session's `VaultCardID`
already decodes tolerantly; nothing else does. *Done when:* records decode one by one, an
undecodable one is kept as opaque JSON and written back untouched, and the panel says "1 record needs
a newer SyncCloud".

**VT33 — A way out of an unreadable Vault** (the code half of VB2). `.unreadable` disables Add and
`write` refuses, correctly, but there is no supported path forward. Add `VaultStore.setAside()` (rename
both sealed files with a timestamp, never delete) and restore-from-backup (VF6).

## F. Security and privacy

What is sound and should stay: AES-256-GCM with the marker as authenticated data, a random key that is
never synchronised, 0600 files, "never write over a file this Mac cannot open", HMAC-keyed set-aside
fingerprints, the sealed lock-off switch, `lockEpoch` discarding late proofs, masked `description` and
empty mirrors, concealed host-only clipboard cleared after a minute and on quit, nothing sent to Claude.

**VT31 — The lock is the app's, not the key's.** `VaultKeychain.create` (`VaultStore.swift:73`) stores
the key in the file-based login keychain; `kSecAttrAccessibleWhenUnlocked` has no effect there, and any
read by this app succeeds without user presence. Touch ID gates drawing, not decryption. The code says
so itself. *Done when:* on a signed install the key lives in the data-protection keychain under
`SecAccessControl(.userPresence)`, and the unlock passes its `LAContext` as
`kSecUseAuthenticationContext` so one prompt both proves and releases. Ad-hoc builds and tests keep
today's path behind the same `KeychainStore` protocol. Needs the keychain-access-groups entitlement;
check `project.yml` and the `install-sync-cloud` skill's signing. Migrate by re-storing the same key,
after VT20. Decision VQ5 picks `.userPresence` (password fallback) over `.biometryCurrentSet`.

**VT32 — Decrypt after proof, and let go at lock.** `opened()` calls `load()` before `unlock()`
(`VaultModel.swift:779`, `:783`), so every number is in memory before anyone has proved anything, and
the locked list draws names, expiry dates and last fours from it (`VaultPanel.swift:1023`). When the
idle limit passes with the panel up, `tick()` expires the lock but `entries`, `finds`, `copies` and
`rowsCache` (four copies of each number) stay loaded until the panel closes. *Done when:* nothing is
loaded before a proof under "as soon as Vault opens"; locking by any route calls `release()`; the
locked screen is drawn from a small unsealed summary (record count only) or from nothing. Under "for
every number", titles need a decision (VQ2): either a second sealed index of titles, or accept loading.

**VT34 — Endings are secrets for some kinds.** `VaultMask.masked(keep: 4)` is used for every kind.
A Social Security number's last four is itself a credential. Add `hidesEnding` per kind (VT2) and use
it in rows, VoiceOver (`spokenNumber`), `description` and `VaultMask.fileName`.

**VT35 — One copy path.** `copyDetail` (`VaultPanel.swift:1977`) writes dates and text straight to
`NSPasteboard.general`: not concealed, not cleared, relayed by Universal Clipboard, and allowed while
locked. Route every Vault copy through `VaultPasteboard.copyConcealed` and the model's proof.

**VT36 — Screen capture.** Nothing sets `NSWindow.sharingType`. While any number is drawn in full
(detail, editor, Large Type, Quick Look of a scan), set the window to `.none` and restore after.

**Smaller:** changes that need no proof today (`assign`, `pin`, `setGeo`, `setAside`, `confirm`) can
be made by anyone at an unlocked Mac while the Vault is locked; decide whether a locked Vault is
read-only. The clipboard interval (60 s) and the per-number display time (30 s) are constants; make
them settings when VF8/VF9 add the Settings rows.

## G. Readers

Found by a second reviewer reading `VaultReading`, `VaultIDReading`, `VaultAccountReading`,
`VaultTravelReading`, `VaultPrintedPage`, `VaultReadPlan` and `VaultDocumentReader` end to end.
**Checked** means I re-read the cited lines and agree; **relayed** means I did not. Each fix needs a
test with a made-up page that fails before it, and a `VaultReading.version` bump. VT40–VT43 and VT45
were fixed at version 13 and, after two adversarial reviews of those fixes, again at versions 16
and 17; VT46, VT47 and VT52–VT54 are open.

| ID | Where | Defect | Example | Status |
|---|---|---|---|---|
| VT40 | `VaultDocumentReader.swift:103` | A PDF page with more than 40 non-space characters of text layer is never sent to Vision. | A scanned passport page stamped with a DocuSign envelope ID yields only the stamp. | **fixed** 2026-11-20, widened after one review and reshaped after a second. The rule is `VaultPageSource` (`Sync`): a page that draws a scan is read from its picture too when its layer gives the readers no number, whatever its length, and when the layer is short (400 letters) and gives one. A reading says more than the other when it reads a number the other does not, names one the other never says, or knows more about one both read. Where only one says more, it is the page; where each does, both are kept, the second as a page of its own after the file's: never joined into one page (a stamp naming a form made the card under it a form) and neither dropped (two different numbers of one kind both wait to be confirmed). A typed page is rendered only for a license back's barcode, or when its whole text is forty letters or fewer; so few letters that give a number are a stamp, not stray marks. A scan whose picture cannot be read, under a layer that says nothing, is left out as a page with no layer is; a slashed zero Vision reads as `Ø` beside a digit is a zero; a request Vision refuses is made again on the CPU, which helps when only the Neural Engine refuses (`docs/flaky-tests.md`, "Vision's Neural Engine refuses text requests for hours") and not when its compiled model is missing (see below). On the owner's papers about 690 of 2,370 planned pages are read from their picture as well: against the readers before any of this, 44 more files gave a number, none fewer, and a full read went from 259 s to about 340 s. The second reshaping changed three files there: a PAN card whose layer only named its number is read as the card, and one health card's record number, which its scanner's text and Vision read three digits apart, waits to be confirmed both ways where the scanner's was trusted. Still open: a full page of text that gives a number is trusted even where its scan holds more (11 of 203 pages); where both readings give one number and know the same things about it, the picture's words speak for it when it is the page (a misread name over a typed one); a page kept both ways makes a one-page file's sources say "page 1", and a zone read from the second reading is numbered after the file's last page; scans stored as inline images or pasted as annotations are not seen; only three pages of a file are read; the ink-only read is made at 2400 pixels even where the first needed 4000; a card-size page's "sharper" render is no sharper (the scale is capped at 6); VT54. |
| VT41 | `VaultAccountReading.swift:44` | `accountValue` joins any following space-separated group that holds a digit. | `Student ID: 123456 5th Grade` → `123456 5th`; `Loan Number: 0123456789 30 Year Fixed` → `0123456789 30`. | **fixed** 2026-11-20, redone after two reviews (the first fix cut `123456 789012` to `123456` and lost a VIN printed with a space; the second still joined `30-Year Fixed`, `05-Jan-2025` and a toll-free number, and cut `01234 56 78U 7101 2` to `01234 56`). A space joins groups of digits, and a group holding a letter when digits follow it; one or two digits before a word, or tied to it by a dash or a slash, are its count or a date's day; a date (month in digits or spelled, slashes spaced or not; year first only with a real month and day), an amount, a rate and a phone number (toll-free too) end the number; an ordinal is the next word; a VIN has its own pattern, vetted by its check digit. Still open: a second run of three or more digits (`12345 987654321`); a last group of one or two digits before a word (`1234 5678 90 Due` loses the 90) or a suffix before a name (`123456789 01 ANNA` and `… 02 LIV` are one number); a last group holding a letter (`1234 5678 A1`, `1EG4 TE5 MK73`); a number in two groups that together look like a phone number (`123456 7890`); dashes or spaces that are not ASCII. |
| VT42 | `VaultIDReading.swift:487` | `contains("epan")` also matches "Employee PAN", "the PAN". | A tax notice is ranked a PAN card and offers the deductor's PAN. | **fixed** 2026-11-20, redone after two reviews (the first fix lost `e PAN Card`, `e-PANCard` and the word split over two lines; the second took `E - PAN of the deductor`, `e-Panchayat` and `i.e - PAN` for the card and lost `E PAN CARD` and an en dash). `ePANWord`: a small e tied to PAN by any dash; either e, spaced any way, when "card" follows or the line ends there; or `ePAN` run together. Still open: any page that mentions an e-PAN is ranked as the card (`attach a copy of PAN card / e-PAN`). |
| VT43 | `VaultIDReading.swift:571` | `contains("enrollmentno")` matches "Open Enrollment Notice" and waives the Aadhaar label. | A 12-digit member ID passing Verhoeff (1 in 10) becomes an Aadhaar number at rank 40. | **fixed** 2026-11-20, redone after two reviews (the first fix accepted a school's `Enrollment Number: 2024/00123` and lost a letter whose slash a scan read as `1`; the second still accepted the school's number when a helpline or a postcode followed it, and lost a letter whose slashes were read as gaps or dashes). `saysEnrolmentNumber` reads line by line: the label with UIDAI's three groups on its line or the one below. After UIDAI's own spelling, "Enrolment", the two slashes may be anything or nothing; after "Enrollment", only a slash or a bar. `uidai` counts as a word, also run into its address or spaced out: it is the middle of "Liquid Aid". Still open: an Indian school or university that prints "Enrolment No" over fourteen or sixteen digits of its own. |
| VT44 | `VaultDocumentReader.swift:78`, `:155` | Images are decoded and handed to Vision with no EXIF orientation. | A portrait iPhone photo of a card is read sideways. | **not a defect**, run 2026-11-20. Vision's accurate level read a made-up card and passport zone stored a quarter turn either way and upside down, with no orientation passed: every line, in order, at 30, 20 and 14 px type. The only differences were single characters (`O`/`0`, `I`/`T`), in both directions and upright too. Nothing changed. |
| VT45 | `VaultIDReading.swift:329` | The cue `socialsecuritycard` alone makes a page a card; only SS-5 and I-9 are excluded. | A W-4 or I-765 with the number on its own line is filed as a Social Security card. | **fixed** 2026-11-20, redone after two reviews (a list of form numbers never ends: N-400, FAFSA and `Form W–4` with an en dash all passed; then two of the sheet's cues, "do not carry" and "keep your card", turned out to be any benefits page's words, and "established for" a trust's). With none of the card's own print read, the words count only on the sheet a card is mailed on: its heading on a line of its own, one of the sentences only that sheet prints ("Sign this card in ink"), or two of those other cards' papers print too ("Do not laminate", "Keep your card in a safe place"); and no form or OMB number on the page. "Established for" counts with the rest of the card's sentence, or with the card's name or signature line. Still open: a checklist that prints "Social Security card" alone on a line above a number; a form number a scan broke (`Form W 4`, `Forms W-2 and W-4`) under the sheet's heading. |
| VT46 | `VaultReading.swift:800`, `:850` | A zone whose first letter was read as a digit can pass every check (G≡6, L≡1, U≡0 under 7-3-1); the "eight digits + IND" rule runs only after a failure. | Indian passport `G1234567` accepted as `61234567`. | relayed |
| VT47 | `VaultReading.swift:809` | An unreadable character in the number field is only ever filled with a digit or `<`. | `Z` read as `Ž` fills as `5` and passes. | relayed, plausible |
| VT52 | `VaultDocumentReader.swift` (`read`) | Read Documents opens PDFs, extracts their text and renders pages on its own detached task, outside `PDFKitSerialAccess`, the one lane every other PDFKit caller in the app goes through. | A Vault read running while filing or Ask Claude reads a PDF: two parses overlap, and PDFKit can return reordered or dropped text with no error. | by reading (found in the review of VT40; not new with it) |
| VT53 | `VaultFacts.swift` (`VaultCopies.supersedes`) | Two readings of one number under different kinds are ranked by date, detail count and file order, never by which kind says more. | A mortgage number an insurance cover sheet labels "Account Number" (Other) on page 1 and "Loan Number" on page 2: that file now gives it as Other. Across the owner's seven copies it still merges to Loans, by their dates. | seen on the owner's folder, 2026-11-20 (the VT40 check) |
| VT54 | `VaultModel.swift` (`readDocuments`), `VaultDocumentReader.swift` (`read`) | A file with one page left out (not rendered, or not recognised on either processor) and another read is stamped read: the page is not tried again until the file changes or the reader version does, and what it gave before is forgotten. Only a file with no page read at all is tried again. | A two-page packet whose license page fails once loses the license number. | by reading and a stand-in reader (the second review of VT40; older than it, and rare now that a refused read is made again on the CPU) |

**Vision's compiled model, missing.** Seen three times on 2026-11-20 while checking these on the owner's
folder: for two to three minutes every text request failed (`E5RT … create_precompiled_compute_operation
… (Code: 13)`, after `Missing E5 bundle resource … Must re-compile the E5` under
`~/Library/Caches/com.abhishekgirish.SyncCloud/com.apple.e5rt.e5bundlecache`), on the CPU as well: 418 of
1,356 files came back unread in one run. Each time a differently signed build of the app (a test host, then
the signed one) had just made its first request; the cache is one folder for every build with the app's bundle
ID. Read Documents inside such a spell reads no scan; those files are not marked read, and the next read
takes them (VT54 for the exception).

Relayed, minor: a state ID is titled a license when the barcode's first element is `DCA`
(`VaultIDReading.swift:109`); every receipt number on a page shares one form and holder
(`VaultReading.swift:272`); a barcode `DAQ` holding a space or dash is cut at it (`:157`); a mask of
fewer than three X's is read as a full number (`VaultAccountReading.swift:91`); a garbled holder line
on an unlabelled PAN card makes the father the holder (`VaultIDReading.swift:525`); a ten-digit number
after a word ending in s/d/l/g/b/o can form an I-94 (`VaultReading.swift:305`).

**VT48 — Read plan is tied to five folder names.** Whole-folder reads cover Immigration and Legal;
account reads cover Health, Home, Vehicles and School. This household files money under `Finance/US`
and policies under a top-level `Insurance`, so neither is read for accounts, and no reader exists for
bank account, routing, card, IBAN, SWIFT or IFSC numbers (no Luhn or ABA check is in the code).
*Done when:* the plan takes its areas from the filing profile, and a statement reader with ABA and
Luhn checks exists (VF20). Never read a card's security code from any document.

**VT49 — Fields the readers already see and drop.** Date of birth is read from the zone and used only
for person-matching, never offered; the passport zone's surname and given names are flattened into
`holder`; the AAMVA barcode's address elements are not parsed; a license class comes from the barcode
only. No reader for A-number, green card, EAD or SEVIS numbers although files named for them are
opened. Only the first three pages are read. With VT1 these become fields.

**VT50 — Duplicated toolkit.** Three date parsers (`VaultIDReading.swift:46`, `:459`;
`VaultPrintedPage.swift:41`; `VaultReading.swift:218`, `:338`); `squeezed` and title-casing
reimplemented (`VaultIDReading.swift:41` vs `VaultPrintedPage.swift:32`; inline at
`VaultReading.swift:235`, `:355`, `:974`); Archive folder names listed twice (`VaultReading.swift:543`,
`VaultFacts.swift:185`), and `VaultCopies.supersedes` calls `isArchivePath` without the read folders,
unlike the standings. One `PrintedPage` per page, built once and passed to every reader.

**VT51 — Zone recovery.** Four layers in `VaultReading.swift:784`–`:909`. A single unknown in a
checked field always has exactly one passing digit, so "only one fill passes" proves less than its
comment says. Either require a second independent witness (the printed number on the page) for any
recovered zone, or mark the read `inferred` (VT5).

**Dead code:** `"94"` in the form exclusion (`VaultReading.swift:250`) is unreachable;
`VaultFind.init(…sourcePath:)` guesses a category from a title for tests only;
`VaultDocumentReader.swift:107` renders a text-layer Social Security card at 4000 px for a barcode it
cannot have.

## Not debt

Do not "fix" these: search never matching the digits of a hidden number (extend it to last fours
only, which are already drawn); numbers not being selectable text; no Trash for a removed number;
Read Documents needing no proof; the Vault telling Ask Claude only that it is open.
