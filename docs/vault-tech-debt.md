# Vault — technical debt

What is inside the Vault: storage, the model, the panel code, the readers, tests, privacy and security.
What the user sees, and the feature roadmap (VF…, VB…, VQ…), are in the mockup artifact
<https://claude.ai/code/artifact/60d12ecd-c5f3-4945-a098-2f0a9fc8c2a4> and ROADMAP item 25.

**The goal:** internals only. No lost function, no change in what the user sees or does, no change to
the visual design. An item marked **owner's call** changes behaviour: ask first, or do only its
internal half.

**Rules.**
- IDs (`VT…`) are stable: never renumber; cite them in commit bodies. Next free: **VT113** (VT61 and VT62 were never used).
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
- **VT112, Save again from an Edit after another copy's save** writes the old draft over that copy's
  edit of the same ID. *Fix:* the editor keeps the ID as it opened it, and a save refuses when the
  fields it edits changed since (not the whole entry: a correction's note lands on it later).
- **VT109, editing a typed ID's number** leaves the old number's copies (`update` moves them only for
  an ID read from a document); VT110 drops them at the next open, with the documents still marked
  read. Whether the old number goes back to To Confirm (its documents read again) is the question.
- **VT70, "whose is it" worked out in two places**: the editor by the name as read, the row by the
  corrected name and three inferences. Letting the editor take the row's changes what Confirm offers.
- **VT100, two spellings share one role key** ("Anna-Maria" and "Anna Maria"): Legal on the second chip
  marks the first. Merging chips hides one; the internal half keys each lookup by the chip's index.
- **VT23, record lines**: pin, assign, place, kind, name correction, Read from This Copy and
  `copyPerson(numbers: true)` record nothing; `copyBirth` is titled by the first ID. Each addition is a
  new Activity line.
- **VT34's drawn part**: an activity line's title and "Its document reads differently now" show a
  Social Security number's last four. (Descriptions done, batch 19.)
- **VT35's question**: whether copied names and dates are concealed and cleared too. (One copy path
  done, batch 19.)
- **VT50's two**: `VaultCopies` taking the read folders (a read folder inside an Archive folder makes
  every copy there archived); `recordFolders` skipping `…/Archive/` while reading `…/Archived/` and
  `…/Old/`.
- **VT75's two**: `VaultColorPicker` (pop-up, Customize Groups) and `VaultColorPopover` (swatches)
  choose one thing two ways; the List layout lacks the others' empty state.
- **VT73 (b)**: Quick Look's own panel follows the capture setting while it shows a Vault document.
- **VT81**: Refresh reads a source that grew past 60 MB, which Discover skips; check the caps in
  `pages(in:)`.
- **VT107 steps 3–5** (steps 1–2 done, batch 4): pass over a supporting copy whose numbers are all held
  from a home-folder source; Refresh reopens only each ID's own file; keep Vision's page text sealed so a
  version bump re-runs the rules, not the OCR (stores document text).
- **Under "For every number"**, `assign`, `pin`, `setGeo`, `setAside` and `confirm` need no proof:
  whether a locked Vault is read-only.
- **Reader accuracy**, each changes what is read (a made-up page that fails first, a version bump, the
  harness):

  | ID | Misread |
  |---|---|
  | VT46 | G↔6, L↔1, U↔0 never fail a 7-3-1 check: an Indian passport `G1234567` reads `61234567`. |
  | VT47 | One unknown in a zone's number field is filled with a digit only: `Z` read as `Ž` becomes `5`. |
  | VT53 | One number read under two kinds is ranked by date and details, never by the more specific kind: a mortgage labelled "Account Number" then "Loan Number" lands as Other. |
  | VT88 | A typed page trusted over a fuller scan; the picture's words over a typed name; a both-ways page's sources; inline-image scans unseen; ink-only at 2400 px; `zeroed` takes `Ø` beside any digit. |
  | VT90 | Any page mentioning an e-PAN is ranked as the PAN card. |
  | VT91 | An Indian school's 14- or 16-digit "Enrolment No". |
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
| VT35 | One copy path (`VaultPasteboard.copyPlain`) | batch 19 |
| VT40–43, VT45 | Reader bugs | `f7e441a7a`, `fd0377535` |
| VT44 | EXIF orientation: not a defect, measured; do not re-propose | 2026-11-20 |
| VT50 | The readers' toolkit, one `PrintedPage` per page | batch 19 |
| VT52, VT54, VT58, VT73 (a, c) | PDFKit lane, a partly read file, backup key off the main actor, capture gaps | batches 3–4 |
| VT56, VT57, VT59, VT63 | Replace sets aside first, Add Missing ids, activity file set aside, name sealed after save | `5e33b3c47`, `976b30712`, reviews |
| VT60 | Settled by the owner's call (2026-11-24): the lock is always on. Settings ▸ Vault's Require Touch ID and the lock-off seal are gone from the code; an "off", a seal or its Keychain secret left by an earlier build is ignored (none on the owner's Mac). Without Touch ID set up (no fingerprint, no login password, no sensor) the Vault is not used at all: nothing is loaded, read or asked for, and the panel and Settings say how to set it up (Back Up Now, Restore and Show… wait for it); found gone while loaded, it locks and lets the numbers go; set up meanwhile, coming back to the app opens it. Out of reach (the lid closed, a lockout, a Touch ID keyboard unplugged) it stays locked. Owed: a check with the lid closed that macOS still reports the sensor | batch 29 |
| VT64 | A removed ID takes what its documents said with it (`forgetReading`, sealed): from then on Refresh stops counting and opening documents only it came from; a typed one's documents are read again, so it is offered from them; owner's go-ahead | batch 25 |
| VT108 | Two copies of SyncCloud on one Vault: a save expects the file as this copy last read or wrote it (`VaultFileState`), compared with the very bytes it writes over; over another copy's save it is refused, the IDs are read again (a number the other saved leaves To Confirm) and "Another SyncCloud on this Mac changed the Vault…" shown, or why it would not read. The reading file: VT111; owner's go-ahead | batch 27 |
| VT111 | Two copies of SyncCloud and the reading file: a seal expects the file as this copy last read or sealed it; over another copy's it merges and seals again. What the user typed or chose stands as each copy changed it: names, lessons and older-rules choices by key; one person's contacts and roles field by field, a list keeping what each added and dropping what each removed; each waiting ID's choices by number, and one the other took out of To Confirm goes. A file gone keeps this copy's; a later build's fields go on; one this build cannot open is not sealed over, and the panel says so. A refused correction note is tried once more, quietly; Merge and Add a Field show only their own refusal. Not merged: a Misread's name and role are two keys, so two copies can leave them disagreeing; owner's go-ahead | batch 28 |
| VT110 | IDs removed before VT64: as the reading file opens, what documents said about a number no saved or waiting ID has goes (`dropOrphanedCopies`), sealed at the next seal. Not beside anything a later build wrote (records, fields, reading fields) or in a Vault with no ID, which keeps them until one is added; mentions stay; documents stay marked read, so a typed ID removed back then is not offered again until its document changes; owner's go-ahead | batch 26 |
| VT65, VT66, VT67, VT102 | One seal per action, rows rebuilt once, stats off the main actor, one `daysLeft` | batches 4, 6 |
| VT68 | Stop keeps what was read | `f95e61078` |
| VT69 | The user's choices as one value (`VaultChoices`) | batch 9 |
| VT71, VT94–VT97, VT105 | Rows-cache, scratch-defaults, backup, swatch and name-role tests | batch 5 |
| VT74 | Render tests wrote the backup and read Folders to Read live: both now come with the model (`VaultModel.live()`'s; none and scratch settings in tests), and `VaultReadFolders` takes no default settings. A render still reads the owner's sharing settings (capture, clipboard time); it writes nothing | batch 24 |
| VT72 | Activity lists a title whole (`VaultMask.text`), not cut at its last slash | 2026-11-24 |
| VT75 | Duplicated view code, but the pickers and List's empty state | batches 8, 22 |
| VT77, VT78, VT82, VT83, VT84 | Masonry measured once, colors made once, renders and readings once per page, labels once per page | batch 6 |
| VT79, VT80, VT103, VT106 | Retroactive conformance, dead code, People's groups by id, small duplications | batch 11 |
| VT85 | Regexes per line: measured out (Foundation caches them); do not re-propose | 2026-11-21 |
| VT86 | Magic numbers named | batch 19 |
| VT87 | The account-number regex as a reader (`VaultAccountValue`) | batch 20 |
| VT89 | The account-number reader's misses | batch 21 |
| VT98 | One Vault test kit | batch 7 |
| VT99, VT101 | A role change publishes and rebuilds no rows | 2026-11-21 |
| VT104 | Waiting finds merged at every open: measured out (~60 ms for 200); if ever needed, key on the build that sealed the file, never a hand-bumped number | 2026-11-21 |
| VT107 (1, 2) | A byte-identical file read once; originals first | batch 4 |
| VT76 | View state that duplicated the model's: the layout and Large Type (batch 11); the household from the window's `VaultHost`, drawn from `model.people` alone, and the read folders reloaded in one place (batch 23). `namingKindFor`/`newKindName` and `copied`/`copiedDetail` stay pairs: one optional would blank the name as its sheet slides away, and an ID's and a detail's "Copied" show together | batches 11, 23 |
| VT7 | `readDocuments`' pieces as steps of their own; last, the walk and the plan (`plannedSteps`), with every place a read can stop kept | batches 9, 10, 24 |
| VT1, VT10, VT34 | Parts done; the rest is open above | batches 4–19 |

Kept on purpose: `sessionLine` in production code (the shared log capture sees sibling cases); the
reader protocol's three levels (`pages`, `reading`, `noted`); leftover `.writing-` and set-aside files
unswept (the second may be the only readable copy); the swatch image made per draw (a held one keeps
the other appearance's shade); a page's letters made with the page (made at first use, three of the
owner's papers read differently).

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
