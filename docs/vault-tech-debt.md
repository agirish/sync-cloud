# Vault — technical debt

What is inside the Vault: storage, the model, the panel code, the readers, tests, privacy and security.
What the user sees, and the feature roadmap (VF…, VB…, VQ…), are in the mockup artifact
<https://claude.ai/code/artifact/60d12ecd-c5f3-4945-a098-2f0a9fc8c2a4> and ROADMAP item 25.

**The goal:** internals only. No lost function, no change in what the user sees or does, no change to
the visual design. An item marked **owner's call** changes behaviour: ask first, or do only its
internal half.

**Rules.**
- IDs (`VT…`) are stable: never renumber; cite them in commit bodies. Next free: **VT114** (VT61 and VT62 were never used).
- **Never log, print or assert on a number in full.** Raise `VaultReading.version` when what a reader
  finds changes; it makes the next Read Documents read every file again.
- **Proof for every refactor** (`CLAUDE.md` §5): the same rows, sealed JSON (decrypted, key-sorted)
  and log lines before and after; renders byte for byte for the panel
  (`TEST_RUNNER_VAULT_PANEL_PNG`); for a reader, the count-only hash harness on the owner's folder
  (memory `vault-reader-changes-check-on-real-papers`).
- Do not split a file because it is long.
- The Vault has never shipped (first commit `e4990837e`, 2026-11-18): the owner's sealed file is the
  only one, so a format migration is cheap until the v7.2 cut.

## Owed before the next cut

Read by [`RELEASE.md`](../RELEASE.md) §4.
- **v7.2: one rewrite of the owner's sealed file** (owner, 2026-11-22 and 11-23), so it changes once:
  - **VT3**, drop the never-shipped shims: `VaultEntry.Kind`, `older`, the encoded `kind`,
    `VaultCategory.from(kind:title:)`, `Draft.init(…kind:)`, `VaultFind.init(…kind:…sourcePath:)`, and
    `dated`/`sourcePath` that repeat `facts`. The migration strips the retired keys itself (else
    `VaultFile.openRecords` keeps them as a later build's fields), saves under the short-list guard,
    adds a fixture format and keeps `vault-format-1` opening.
  - **VT1's stored shape**: one `VaultRecord` with typed `fields` (number, secret, text, date, phone,
    address), an owner, an origin, a state and the user's choices; `Row` derived, `Draft` a copy,
    readers emit records. (The choices already go one path, `VaultChoosing`, batches 9 and 13.)
  - **VT6**, one sealed document: saved and waiting records, set-aside fingerprints, `names`,
    `nameRoles` and `lessons` together, carried by the passphrase backup (a backup format change), in one
    atomic swap; `load()` drops a waiting find whose number is saved (today a crash between the two
    writes, or Restore ▸ Add What's Missing, shows it twice); UserDefaults keeps preferences only.
  - **A format version stamp**: a build that meets a higher one opens the Vault read-only and says a
    newer SyncCloud saved it; VT30's merging of a later build's records and fields then goes.
  - Held back until near the cut: a build made before it shows the Vault empty, with nothing saying
    why.

## Open: internal

- **VT51, zone recovery proves less than it says** (internal half done: `MachineZone.recovery` says
  as read, fill, swap or printed number, each reading logs a debug line counting each, and tests pin
  the pairs branch and a G-series passport read as 6…). With weights 7-3-1, one unknown digit in a
  checked field always has exactly one passing digit, and the overall check re-tests the same
  residues; only `readWithPrintedNumber` has an independent witness. *Owner's call:* a recovered zone
  needs the printed number or date to agree, or is marked inferred (VT5).

## Open: the owner's calls

Each changes what the user sees, gets or is asked.
- **Reader accuracy**, each changes what is read (a made-up page that fails first, a version bump, the
  harness):

  | ID | Misread |
  |---|---|
  | VT92 | A checklist's "Social Security card" above a number; a scan-broken form number (`Form W 4`). |
  | VT93 | A state ID titled a license; one form and holder for every receipt on a page; a barcode `DAQ` cut at a space; a mask of under three X's read whole; a garbled PAN holder line; lower-case letters forming an I-94. |

## Open: blocked or roadmap

- **VT31, the lock is the app's, not the key's** (blocked with VF7). The key sits in the file-based
  login keychain, readable without the user present. *Done when:* on a signed install it lives in the
  data-protection keychain under `.userPresence`, the unlock passes its `LAContext`; needs a
  provisioning profile (−34018 today).
- **VT10's rest** (with VT31): hold the key from a load until `release()`; `keyState()` for the probe.
- **Features, not debt** (each changes what the user gets): VT5, an assurance level on every read
  (VF16, VQ4); VT48, accounts read only under five folder names, no card or bank readers (VF20);
  VT49, fields read and dropped: birth date, the zone's name parts, AAMVA address, A-number, green card,
  EAD, SEVIS, pages past the third (VF10).

## Done

| ID | What | Where |
|---|---|---|
| VT2, VT4 | Kinds and places as data (`VaultKindSpec`, `VaultGeo`) | batches 12, 14 |
| VT8 | Display rules out of the view (`VaultRowText.swift`) | batch 8 |
| VT9 | The panel redraws only when what it draws moved (`Clockface`) | batches 4, 6 |
| VT11 | Stale comment | batch 3 |
| VT20, VT21, VT24, VT30, VT55 | One sealed-file writer, rolling backups, golden fixtures, no silent failure, one bad record kept | `deb831324` and reviews, batches 14–15 |
| VT22, VT25, VT26 | Session lines, reader skips counted, a whole-life log test | batches 5, 7 |
| VT27, VT28, VT29 | App-side, privacy and lock-table tests | batches 5, 7 |
| VT32, VT33, VT36 | Decrypt after proof, a way out of an unreadable Vault, screen capture | VF4, VF6, VF9 |
| VT35 | One copy path (`VaultPasteboard.copyPlain`); copied names and dates stay ordinary copies, by the owner's call (only an ID's number and a birth date are concealed and cleared) | batch 19, 2026-11-25 |
| VT40–43, VT45 | Reader bugs | `f7e441a7a`, `fd0377535` |
| VT88 (ink alone) | By the owner's call, the ink-only reading of a scan on colored paper takes the render the first reading needed (4000 pixels where 2400 lost its small type). Version 27, with batches 47–53, checked together on the owner's papers | batch 46 |
| VT88 (typed over a scan) | By the owner's call, a full typed page that draws a scan is read from its picture too: the typed text stays the page, the picture kept beside it where it says more. On the owner's papers: nine account numbers read from the scans under typed bills, one of them the same in six | batch 47 |
| VT88 (both ways) | By the owner's call, where a page's typed layer and picture read one number alike the typed reading speaks and the picture lends what it lacks; each reading carries the page it came from, so a page kept both ways is one page | batch 48 |
| VT88 (inline and annotations) | By the owner's call, a scan drawn inline (BI … EI) or as an annotation's shown appearance counts as the page's scan, so its picture is read | batch 49 |
| VT90 | By the owner's call, only a page with the e-PAN's own layout (its heading, or a holder label on its own line) ranks as the PAN card; a page that only names an e-PAN quotes the PAN | batch 50 |
| VT91 | By the owner's call, under School an "Enrolment No" is the student's ID, and a page is an Aadhaar letter by its enrolment number only with its slashes or UIDAI's name | batch 51 |
| VT88 (slashed zero) | By the owner's call, a "Ø" beside a digit is a zero except the diameter sign (a lone Ø, at a line's start or after a space or bracket, before one to three digits and a unit: "Ø12 mm" read as 012); a size with no unit is a zero, as a date's last part needs, and a typed text layer's slashed zeros are put back too, as Vision's always were. Version 26. On the owner's papers: no find changed | batch 45 |
| VT53 | By the owner's call, an account number read as Other (a cover sheet's "Account Number") and as one account kind elsewhere (its next page's "Loan Number") is that kind, in one file or across files; the reading that speaks keeps who issued it, so the title is its issuer and the kind's name, and two kinds that disagree, or an identity kind, change nothing. Version 25. On the owner's papers: the mortgage's cover sheet now reads as Loans, nothing else changed | batch 44 |
| VT47 | By the owner's call, a zone's accented letter ("Ž" for Z) is read as its letter, and a character of the number that stays unreadable leaves no reading, since a digit and every letter worth ten, twenty or thirty more pass its check alike (5, F, P, Z): it was filled with the digit. A visa's foil may still print the number. Version 24. On the owner's papers (1,356 files): no zone changed | batch 43 |
| VT46 | By the owner's call, an Indian passport's number (on its own zone or a US visa's) that reads as eight digits and a filler, its first 6, 1 or 0, is read as G, L or U, the one look-alike worth ten, twenty or thirty more, which keeps every check; on a line read as is, filled, swapped or by its printed number. Its first character unreadable leaves no reading (V, L and B all pass as 1) unless a US visa's foil prints the number; the swap after a failed check is held to the same documents. Version 23. On the owner's papers (1,356 files): no find changed | batch 42 |
| VT44 | EXIF orientation: not a defect, measured; do not re-propose | 2026-11-20 |
| VT50 | The readers' toolkit, one `PrintedPage` per page | batch 19 |
| VT50 | Archive folders, by the owner's call: Backup joins Archive, Archived, Old and Expired (an ID's tab, a copy's rank, and an account's papers there are records, not read for its number: all of them now, not Archive alone), but archives an ID only below the folder read, since a drive or folder called Backup is often where everything lives; TODO by SyncCloud's own inbox rule (TODO anywhere in a folder's name, Inbox, Unfiled), TMP and Temp rank a copy below a filed one but never archive an ID; an Archive folder above the folder read keeps counting as before. On the owner's papers no file sits under the new archive names and the new lower ranks touch only which copy is preferred, so no version bump | batch 38 |
| VT52, VT54, VT58, VT73 (a, c) | PDFKit lane, a partly read file, backup key off the main actor, capture gaps | batches 3–4 |
| VT73 (b) | Quick Look's own panel is out of capture while it shows a Vault document (batch 16), now from before a first preview appears (asking for the panel creates it; it used to be set only if it already existed), and sharing again once the preview ends or the Vault closes mid-preview | batches 16, 37 |
| VT56, VT57, VT59, VT63 | Replace sets aside first, Add Missing ids, activity file set aside, name sealed after save | `5e33b3c47`, `976b30712`, reviews |
| VT60 | Settled by the owner's call (2026-11-24): the lock is always on. Settings ▸ Vault's Require Touch ID and the lock-off seal are gone from the code; an "off", a seal or its Keychain secret left by an earlier build is ignored (none on the owner's Mac). Without Touch ID set up (no fingerprint, no login password, no sensor) the Vault is not used at all: nothing is loaded, read or asked for, and the panel and Settings say how to set it up (Back Up Now, Restore and Show… wait for it); found gone while loaded, it locks and lets the numbers go; set up meanwhile, coming back to the app opens it. Out of reach (the lid closed, a lockout, a Touch ID keyboard unplugged) it stays locked. Owed: a check with the lid closed that macOS still reports the sensor | batch 29 |
| VT64 | A removed ID takes what its documents said with it (`forgetReading`, sealed): from then on Refresh stops counting and opening documents only it came from; a typed one's documents are read again, so it is offered from them; owner's go-ahead | batch 25 |
| VT100 | A name its papers write differing only in case or the marks between words ("Anna-Maria", "Anna Maria", "ANNA-MARIA") is one chip in People, as it is one name to its roles and corrections: written as most of its papers write it (a tie to the form keeping its hyphen, which a passport's machine line cannot print), every paper behind it; its tip and the summary name the other ways. An apostrophe or accent is part of a word ("O'Brien", "José"), so those stay apart, as for corrections. Owner's call (one chip over a role per spelling) | batch 32 |
| VT108 | Two copies of SyncCloud on one Vault: a save expects the file as this copy last read or wrote it (`VaultFileState`), compared with the very bytes it writes over; over another copy's save it is refused, the IDs are read again (a number the other saved leaves To Confirm) and "Another SyncCloud on this Mac changed the Vault…" shown, or why it would not read. The reading file: VT111; owner's go-ahead | batch 27 |
| VT111 | Two copies of SyncCloud and the reading file: a seal expects the file as this copy last read or sealed it; over another copy's it merges and seals again. What the user typed or chose stands as each copy changed it: names, lessons and older-rules choices by key; one person's contacts and roles field by field, a list keeping what each added and dropping what each removed; each waiting ID's choices by number, and one the other took out of To Confirm goes. A file gone keeps this copy's; a later build's fields go on; one this build cannot open is not sealed over, and the panel says so. A refused correction note is tried once more, quietly; Merge and Add a Field show only their own refusal. Not merged: a Misread's name and role are two keys, so two copies can leave them disagreeing; owner's go-ahead | batch 28 |
| VT109 | A typed ID's number changed (nothing read went into it: no reading, source or merged note): what documents said about the old one goes, sealed, and they are read again at the next read, so papers that print it offer it in To Confirm, as for a removed typed ID (VT64). An ID with a reading of its own (read, or added while its number waited) stays a correction (notes, not offered). Owner's call | batch 33 |
| VT112 | An edit over another copy's edit of the same ID: the editor keeps the ID as it opened it; when a reread (VT108) brings that copy's change to a field the editor shows (title, number, note, kind, card, whose, name), the save is refused once, saying so, what was typed stays, and Save again replaces it. This copy's own changes (a row's menu) never refuse it, and an edit keeps the ID's current pin and place, which the editor does not show | batch 34 |
| VT110 | IDs removed before VT64: as the reading file opens, what documents said about a number no saved or waiting ID has goes (`dropOrphanedCopies`), sealed at the next seal. Not beside anything a later build wrote (records, fields, reading fields) or in a Vault with no ID, which keeps them until one is added; mentions stay; documents stay marked read, so a typed ID removed back then is not offered again until its document changes; owner's go-ahead | batch 26 |
| VT65, VT66, VT67, VT102 | One seal per action, rows rebuilt once, stats off the main actor, one `daysLeft` | batches 4, 6 |
| VT68 | Stop keeps what was read | `f95e61078` |
| VT69 | The user's choices as one value (`VaultChoices`) | batch 9 |
| VT71, VT94–VT97, VT105 | Rows-cache, scratch-defaults, backup, swatch and name-role tests | batch 5 |
| VT74 | Render tests wrote the backup and read Folders to Read live: both now come with the model (`VaultModel.live()`'s; none and scratch settings in tests), and `VaultReadFolders` takes no default settings. A render still reads the owner's sharing settings (capture, clipboard time); it writes nothing | batch 24 |
| VT70 | Add to Vault proposes whose a waiting ID is by the name as corrected, as its row does, not as printed, and Confirm saves it as it always saved a printed name's person. The rows' other answers (a folder's person, a birth date, the household for a nameless account) stay guesses, worked out again after Confirm: saved as choices, a household account would be grouped and the older archived. Edit keeps what was chosen. Owner's call | batch 36 |
| VT72 | Activity lists a title whole (`VaultMask.text`), not cut at its last slash | 2026-11-24 |
| VT75 | Duplicated view code, batches 8 and 22; then, by the owner's call, one way to choose a color: the swatches (`VaultSwatches`) in a card's Color…, a group heading's Color… and every row of Customize Groups (`VaultColorWell`), the pop-up gone; and one empty state for Cards, List and People (`noIDsState`), so List also offers Show Everything when the choices hide every ID | batches 8, 22, 39 |
| — | Under "For every number", `assign`, `pin`, `setGeo`, `setAside` and `confirm` still need no proof: changes that show no number stay open to an unlocked Vault (owner's call, kept as it is) | 2026-11-25 |
| VT77, VT78, VT82, VT83, VT84 | Masonry measured once, colors made once, renders and readings once per page, labels once per page | batch 6 |
| VT79, VT80, VT103, VT106 | Retroactive conformance, dead code, People's groups by id, small duplications | batch 11 |
| VT81 | A document grown past 60 MB is passed over by Refresh, as by Discover More, and what it gave before stays in both (owner's call): Discover More had let it go as deleted. Refresh marks it read with its size and date, so it is opened again only once it changes | batch 38 |
| VT85 | Regexes per line: measured out (Foundation caches them); do not re-propose | 2026-11-21 |
| VT86 | Magic numbers named | batch 19 |
| VT87 | The account-number regex as a reader (`VaultAccountValue`) | batch 20 |
| VT89 | The account-number reader's misses | batch 21 |
| VT98 | One Vault test kit | batch 7 |
| VT99, VT101 | A role change publishes and rebuilds no rows | 2026-11-21 |
| VT104 | Waiting finds merged at every open: measured out (~60 ms for 200); if ever needed, key on the build that sealed the file, never a hand-bumped number | 2026-11-21 |
| VT107 (1, 2) | A byte-identical file read once; originals first | batch 4 |
| VT107 (3) | By the owner's call, Discover More passes over a copy filed in a packet (Supporting Documents, Petition, Application, Evidence) when it is as it was when last read whole and every number it gave then is held, in what this read has read, from a document in that ID's own folder, not archived or set down there, that this read sees. Never an ID's own document (a copy chosen with Read from This Copy), never one that gave nothing, never in Refresh or Read Everything Again. Not marked read, so it is opened once one of its numbers is held nowhere else; Refresh still sees it change. What each packet copy gave is sealed (`copyNumbers`), kept across a change of rules, let go with a Forget or Not for This ID. Accepted losses: after a change of rules such a copy leaves the row's documents and Read from choices, and a later date, detail, named number or new-rules number only it has is missed. Step 5 (seal page text) is not wanted: it would store document text | batch 41 |
| VT107 (4) | By the owner's call, Refresh opens only the document each ID is read from (the copy chosen with Read from This Copy, else the one saved from, else the most trusted); its other documents are checked for size and date. One gone is marked File not found; one changed in a folder Discover More reads is marked noticed in the read index and raises Discover More's banner, worded for it, once per change. A change of rules remembers only waiting IDs' own documents | batch 40 |
| VT76 | View state that duplicated the model's: the layout and Large Type (batch 11); the household from the window's `VaultHost`, drawn from `model.people` alone, and the read folders reloaded in one place (batch 23). `namingKindFor`/`newKindName` and `copied`/`copiedDetail` stay pairs: one optional would blank the name as its sheet slides away, and an ID's and a detail's "Copied" show together | batches 11, 23 |
| VT7 | `readDocuments`' pieces as steps of their own; last, the walk and the plan (`plannedSteps`), with every place a read can stop kept | batches 9, 10, 24 |
| VT113 | Not done, by the owner's call (2026-11-24): what the Vault guards is the ID it read or was given, its number field; a number typed into a title or a note is the user's own text, drawn as typed. (Activity and the Touch ID prompt already mask one, from VT34.) | 2026-11-24 |
| VT23 | Every choice about an ID has its Activity line, naming the ID, never its number: Move to Current or Archive (or the Vault's choice), Belongs To, Used In, Kind (As Read or As Typed named as such), Read from This Copy; one already in force adds none. A misread name corrected or its correction undone, as whose, never the spelling; a person's IDs copied in full; a birth date copied, listed as the person's, not after their first ID. Someone not in People is listed as such, never by the spelling read. A new line kind (`changed`), listed by its words by a build before it | batch 35 |
| VT34 | A Social Security or Aadhaar number's ending, never drawn while hidden: in descriptions (batch 19); and now in Activity titles, the Touch ID prompt's reason (every kind's number there cut to its ending), "Its document reads differently now", the editor's other IDs on the card, and a document's or folder's name wherever it is drawn hidden (list, tips, More Fields, the preview). Kept to nothing, the last four written alone ("xxx-xx-6789") count as a number. The correction note names its document masked, for every kind. Activity lines listed before keep what they said | batches 19, 30 |
| VT1, VT10 | Parts done; the rest is open above | batches 4–19 |

Kept on purpose: `sessionLine` in production code (the shared log capture sees sibling cases); the
reader protocol's three levels (`pages`, `reading`, `noted`); leftover `.writing-` and set-aside files
unswept (the second may be the only readable copy); a page's letters made with the page (made at
first use, three of the owner's papers read differently).

**Vision's compiled model, missing.** For two to three minutes after a differently signed build's
first text request, every request can fail (`E5RT … (Code: 13)`, "Missing E5 bundle resource"):
every build with the bundle ID shares that cache. Files read then are not marked read; the next read
takes them.

## What is sound and stays

AES-256-GCM sealing with the marker authenticated, a random key never synchronised, 0600 files, never
writing over a file this Mac cannot open; HMAC-keyed fingerprints; the session's epoch discarding late
proofs, nothing loaded before a proof; masked descriptions and empty mirrors; a concealed, host-only
clipboard copy cleared after its time, at a lock and on quit; screen capture kept off the window and
the sheets, popovers and Quick Look panel that draw a number; PBKDF2-HMAC-SHA256 at 600,000 rounds for
the backup; a bounded, sealed activity list; nothing sent to Claude.

## Not debt

Do not "fix": search never matching a hidden number's digits; numbers not selectable as text; no
Trash for a removed number; Read Documents needing no proof; the Vault telling Ask Claude only that it
is open; `sharingType = .none` hiding the whole window; a flat card-title menu (a SwiftUI submenu in
`.contextMenu` closes when rows change); EXIF orientation.
