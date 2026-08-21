# SyncCloud — Release Notes

User-facing changes, newest first. For the full commit history see the
[repository](https://github.com/agirish/sync-cloud).

---

## v4.2 — DRAFT, not released

> **This section is a draft.** v4.2 has not been cut and this is not final copy.
> Work is still landing, so entries will be added and existing ones may change or
> be withdrawn. Covers `v4.1..main`. Claims below were checked against the `v4.1`
> tag: fixes to work that landed *inside* this range earn no entry, because no user
> of v4.1 was ever exposed to them. That rule takes out most of this range — the
> setup form, the Readability tab, the toolbar Go-to field, the Organize menu and
> File's row verbs all arrived here, so the review passes that followed each of them
> are repairs to unreleased work.
>
> **Re-check the Known limitations before publishing.** They age in the direction
> that makes them wrong: ⌘/ was listed here as opening nothing, and was fixed on the
> tip while this was being written.

**SyncCloud can set itself up.** Until now the filing engine needed a *folder
profile* — the record of your tree that To File, Renames and Restructure all read —
and nothing in the app could produce one: `resurveyFilingMemory` opened by requiring
a profile id and returned without one, so a machine that had never run an
out-of-repo script got no routing, no rename proposals and no Restructure findings,
with nothing on screen saying why. In place of the six-page welcome tour there is
now a form that asks four questions and walks your tree.

The other half of the release is reach. The menu bar had not grown since tabs
arrived — Organize's sections and verbs, the row menu's seven verbs, the four
clipboard chords, the transfer chords and ↩-to-rename all had working handlers and
no menu route. ⌘K stops being a card over a dimmed window and becomes a field in the
toolbar you can type a path into. ⌘C and ⌘V stop being sealed inside the app and
exchange files with Finder. Browse gets a sidebar of the folders you pin and the ones
you keep coming back to. And Storage stops asking you to read digits to see which of
two files is bigger.

On the v4 line, so it **requires macOS 26** — coming from 3.x or 2.x, read the v4.0
section first.

### Setting up

- **A fresh install is asked four questions rather than shown six pages of prose.** Your name
  and the forms of it documents print; which of the discovered sources you actually
  use and which is primary; who else is in the household; and which folder to learn
  from. The retired tour asked for nothing, so everything the filing engine needs was
  left to be discovered later across nine settings tabs.
- **The Folders step walks your tree and writes the profile.** Names and counts only
  — no document is opened — so it takes seconds rather than the hours a document
  survey needs, and the result takes effect without a relaunch. A walk that lands
  beside a profile SyncCloud did not write is refused the pointer and says so
  ("learned N folders, but this Mac already has a folder profile it did not write")
  rather than reporting a plain success: a hand-built profile records judgements a
  walk cannot see.
- **It proposes the place names it found, and nothing starts ticked.** Mined from
  folder names and used as-is, the proposals are mostly right and every one of their
  mistakes is an invention — `HPE` is an employer, `IT` a department, `PRD` a product
  stage. Handed only the values you confirm, the same code has nothing to invent
  from. Each chip carries how many folders it would affect, with the parents it
  splits in the tooltip: a value under Finance, Legal and School reads as a place;
  one under Work/Payslips alone reads as an employer.
- **It proposes the household too, from the one folder that says what its children
  are.** `Family/Aditi` is a person because `Family` said so. Every rule that
  measured repetition instead was thrown out by the numbers rather than by review —
  on a document tree `Reference`, `Application` and `Statements` all outrank every
  real person, because document-type words repeat harder than people do. It over-proposes on purpose, with the vouching folder on each chip: a
  name you must think of unprompted costs more than a name you refuse with one click.
- **Answers are kept when there is nowhere yet to put them.** `people.json` lives
  *inside* a profile, so on the machine this form exists for, You and People have
  nowhere to write until the walk mints one. Those two rows say the answer is kept
  and applies once SyncCloud has learned a folder tree, rather than claiming to be in
  effect. When the profile arrives they are applied to the roster — adding to records
  and never removing from them, so a full name typed into Settings ▸ People in the
  meantime survives.
- **The form will not offer edits `PeopleStore` refuses to write.** It declines over
  a `people.json` it could not read, and over one whose duplicated id it had to
  collapse; the People step now says which of the two is in force, disables Add and
  Remove, and withholds the count rather than reporting a household back to you that
  it could not read.
- **It opens by itself only on a machine that has never been set up** — nothing
  completed, nobody greeted, no profile — and **Help ▸ Set Up SyncCloud…** opens it
  any time without persisting anything. A re-run opens on the rail, not on a welcome
  card addressed to somebody who has never seen the app.

### Safety

- **An unreadable pin list was destroyed by the next pin you made.** The folder-jump
  store — the pins behind the breadcrumb menu, ⌘K's Folders group and now Browse's
  sidebar — decoded with `try?`, so a blob it could not read left the store at empty,
  looking exactly like a fresh install. Nothing was lost on that read. The loss came
  on the **next write**: the first pin you made encoded that empty map over the key,
  and every pin you had curated went with it — which is why a test that checked only
  the decode would have passed throughout. The bytes are kept aside under
  `<key>.unreadable` now and the store carries on, so pinning still works and nothing
  is overwritten. Only the first stash is kept, since a later launch reads whatever
  has been written since and letting that replace it would destroy the list one
  launch later than the bug it replaces.

### The menu bar

- **Cut, Copy, Paste and Select All reach your files.** Cut, Copy and *Paste here*
  have worked from the row menu since before v4.0, and ⌘C over a selected file fell through to
  AppKit's text Copy and did nothing you could see; Select All was missing outright,
  appearing nowhere in the app except inside text-field editors. The cost was never
  the pasteboard, it was the routing — all four are text-editing keys, and a menu key
  equivalent outranks the field editor — so the keystroke is handed back whenever the
  caret owns it, and ⌘C still copies text in the pane search, a rename field, the
  differences search and the ⌘K field. ⌘X then ⌘V is a move.
- **And the clipboard reaches Finder.** The file clipboard has worked between panes
  since v3 — cut, copy, paste, with grouped undo and a banner — and it was sealed in:
  ⌘C in a pane then ⌘V in Finder did nothing, and ⌘C in Finder then ⌘V in a pane did
  nothing, because every pasteboard write in the app put the path down as *text*. A
  copy now writes file URLs to the system pasteboard and a paste reads them, both
  directions. It stays one clipboard rather than two: while the change count recorded
  at the app's own ⌘C still matches the live one, SyncCloud's own list answers — that
  list is what carries *cut*, so it is the only path that can move rather than copy —
  and the moment anything else writes, the system's board wins.
- **Organize has a menu.** Its five sections, ticked, then its four row verbs. Until
  now ⌘3 was the whole menu-bar presence of the largest feature area in v4. The
  sections route through the same call ⌘K's Organize rows use, so the workspace and
  the scope cannot be moved out of step; every verb refuses a multiple selection,
  because organizing two folders is two questions.
- **The row menu's verbs are in File** — Open in New Tab, Quick Look, Reveal in
  Finder, Rename, Copy to…, Move to… and Ignore in Comparison, each of which
  previously needed a right-click on exactly the right row. Ignore's title flips with
  the selection and is withheld outside Compare, where there is no comparison to
  ignore anything in. Download stays on the row menu: its action starts a per-pane
  watch so the cloud badge clears when the content lands, and a menu item has no pane
  to scope that to.
- **↩ renames the selected row.** It is a pane key handler rather than a menu key
  equivalent, and that is deliberate: a registered bare ↩ would outrank every default
  button in the app — the destination picker's, the ⌘K field's, every sheet's. Finder
  does not register it either. It fires only while the file list has focus, runs the
  same closure File ▸ Rename runs, and falls through untouched when no single row is
  selected.
- **Space no longer opens Quick Look on top of the destination picker.** While a
  *Copy to…* or *Move to…* pick is up, every chord the menu bar mirrors is suspended —
  that pick owns the keyboard until you answer it. Space was not among them: it is a
  key handler on the file list rather than a menu item, so it never went through the
  publication that does the silencing, and nothing stopped it putting a preview over
  the sheet you were in the middle of answering. The reasoning that missed it was that a focus-scoped
  handler cannot fire while a sheet is up — but the picker is drawn over file panes
  that are real AppKit tables, and a view drawn above one of those does not take the
  keyboard from it. ↩, which is new here, is covered by the same rule.
- **⌘← and ⌘→ are in the Compare menu.** The four directional transfers worked and
  were listed in the ⌘/ reference, but had no menu-bar route — and a menu item is
  what lets a chord be read as well as pressed. Their titles name the providers
  ("Copy to Dropbox"), as the header buttons and the row menu already do.
- **Each auxiliary window is listed once.** Keyboard Shortcuts, Activity Log and Sync
  History each appeared twice — in Help as "Open Activity Log", in Window as
  "Activity Log" — and About appeared twice as well, since AppKit's application-menu
  item was there all along. None of it was visible to a source scan: one of each pair
  is generated by SwiftUI and written down nowhere. Help keeps what is genuinely help
  — its own front door, the setup form, and the log reveal.
- **The Window menu says which folders the window is on** — `SyncCloud (iCloud/Documents
  ⇄ Dropbox/Documents)`, and in a lens the one source it is working. `NSWindow.subtitle`
  was set nowhere: the window has no visible title bar, so nothing in the app ever
  needed a name, but the Window menu and Mission Control read one whether or not it
  is drawn and both had been saying "SyncCloud" for a window that could be on any
  pair of folders in any cloud. A side whose provider no longer resolves drops out
  rather than emptying the whole name.

### Go to (⌘K)

- **⌘K grows the toolbar's Go to pill into a field, and the results hang under it.**
  It was a 620pt card floating over a dimmed window; the tree you are navigating now
  stays visible while you type the name of the folder you want. ⌘K on an open field
  selects what is there, as it does in every Mac search field, rather than closing it.
- **Type a path and it goes there.** `/Users/…` or `~/Documents`, Finder's ⇧⌘G as a
  behaviour rather than a surface. A bare name is still a search — treating
  `Documents` as a path would shadow every recent and pinned folder the moment you
  typed a word that happens to be a directory in your home — and a file's path goes
  to its enclosing folder, which is what a Finder copy actually puts on the clipboard.
- **A path it cannot deliver says why instead of doing nothing.** "Not in any
  source", "In Dropbox — switch source first", "Backup SSD is not mounted", "No
  folder at that path". Only the last is a claim about existence, and only it wears a
  question mark.
- **Recents survive quitting.** They were session-scoped, which is right for a pane's
  jump menu and wrong for a field whose entire empty state is that list: the first ⌘K
  of the day opened on nothing, at the one moment yesterday's folder is most wanted.
- **A sleeping drive says so rather than opening blank.** Checking the provider root
  first is one stalled `stat` instead of a dozen, and it correctly answered "none" for
  every remembered folder at once — so an external disk that was not awake opened ⌘K
  completely empty, with "I have no recents" indistinguishable from "my drive is not
  awake". Those folders are now listed and marked *Not available*, the highlight
  lands past them, and ↩ cannot run one.

### Browse and Storage

- **Browse gets a folder sidebar.** `FolderJumpStore` has held two lists since v3 —
  the folders you pin and the last eight you visited under a root — and the only ways
  to see them were the pane header's jump menu and ⌘K. Browse is one pane at full
  width and has the room to keep them out: 180pt on the leading edge, **View ▸
  Sidebar** or ⌃⌘S, Browse only. Click switches the pane, ⌘-click opens the folder in
  a new tab, right-click pins or unpins. Two folders called `Legal` are told apart by
  their parent, and a top-level one by its provider. A folder on a drive that is not
  awake stays listed and refuses, rather than being dropped — a sleeping disk must not
  cost you your pins.
- **Storage's ranked lists draw a magnitude bar and a share.** Every size was set in
  the same weight at the same position, so a four-fold difference between two rows
  read as nothing until you compared the digits — in a section titled "the biggest
  individual files". Each row's bar is scaled to its section's own largest file rather than to
  what is still on screen, so typing a query does not silently rescale every bar; the
  bars are on the size-ordered lists only, since on the oldest-first list a bar that
  rose and fell would read as a ranking it has nothing to do with. The share rounds
  away from zero, because "0%" claims the file is not there.
- **The treemap is one ramp instead of ten hues.** Colour was assigned by index, so
  blue-for-Work meant nothing and the eye kept looking for a legend that could not
  exist. It now runs deep to pale in your own accent hue, ordered by size, so the
  colour *is* the ranking — falling saturation against rising brightness, which keeps
  luminance strictly monotonic for every hue and is the property that lets a ramp be
  read as an order. Each tile's label takes its contrast from the fill that tile
  actually got.

### Text size and spacing

- **Text size is a percentage, 90% to 135%, in 5% steps.** It had four stops with a
  25-point hole between Default and Large that nothing lived in. The four keep their
  names as detents under the slider's ticks — Small, Default, Large, Largest (the
  last renamed from Larger, since the slider now physically stops there).
- **They live in a Readability tab of their own.** Text size and list density were
  two adjacent segmented pickers in Appearance with a caption between them and no
  hint that they were related, though both answer the same question — so somebody who
  finds everything too small had to work out that two separate controls were
  involved. Drawn as they wanted to be drawn they no longer fit an Appearance tab
  that was already running on about 15pt of margin, and a tab of their own is what
  buys the room. It is called Readability rather than "Text size" because row spacing
  is half of it and is not type at all. "List density" is now "Row spacing".
- **Five presets over the two controls**, each step showing less and reading bigger,
  and a live preview of three real file rows at the chosen size and spacing. The
  preview is the only thing on screen that shows what Compact costs: it drops each
  file's size and date entirely, which nobody choosing from the word alone would
  guess.
- **Your stored size migrates at launch.** The value was the string `small` /
  `medium` / `large` / `extraLarge` for every release before this one, and a build
  reading an integer cannot see it — so without the migration every user who had
  chosen a size would have opened a build reporting 100%, and the first write would
  have made it permanent.
- **The setup form's first step carries the same preset row**, because somebody who
  needs larger text needs it for the four questions that follow, not after them.

### Help

- **The Help card can be resized, and remembers the size.** It was fixed at 760×520
  on the argument that its content is bounded — true of the sidebar and false of the
  articles, which run well past the card and scroll. Eight grips, a 560×400 floor,
  and a ceiling of what the window can show; at the smallest window the card is
  exactly what it always was.
- **The rail stops truncating its titles.** Every row set a one-line limit on a rail
  fixed at 220pt, which does not widen when the card is resized — so there was no
  window size that got the word back, and the surface you enlarge the type to read
  answered by removing letters. Titles wrap now, as they always did in the Settings
  rail one file over. "Who your documents belong to" is shortened to "People and
  names".
- **The book describes the app again.** Nineteen articles became twenty-eight, and
  four separate drifts are fixed at once. Three articles sent people to a Help menu
  that no longer has the item. Two told users to add a folder "under Settings ▸
  Providers", a tab renamed **Sources** when it started listing plain folders beside
  the cloud accounts. Three of Organize's five sections — Renames, Restructure and
  Rules — had no article at all, under a section called "Cleanup tools" that
  described half a workspace. And **"Requires macOS 15"** was two majors out of date,
  which is the one stale claim here with a cost attached, since it is read by
  somebody deciding whether to download; it is derived from the built bundle now.
- New articles cover the setup form, the Organize workspace itself, each of its five
  sections, Readability, Intelligence, ⌘K and the household.

### People

- **The person panel stops calling everyone "her".** It is drawn for whoever is
  scoped, and four of its strings were written to a fixture: the header capsule
  ("N hers"), both group titles ("In her folders", "Hers, filed elsewhere") and the
  misfiling subtitle. Nothing failed,
  because the fixtures the tests render are the two people it happened to be right
  about; the copy was simply wrong for everyone else, on screen, from the day it
  shipped. The panel now names the person where the group starts — "In Abhishek's
  folders" — and says they/them in the sentence that follows, which is what every
  other person-facing string in the app already did.

  Deliberately not a `pronouns` field: that is a new persisted key, an editor, a
  decoder state and a small grammar layer, bought for four strings and wrong for
  every person until somebody fills it in. `relationship` ("wife", "daughter") is
  sitting right there as a shortcut and is not one — inferring pronouns from a
  free-text relationship word is how you misgender somebody.

### Known limitations

- **⌘A in a Tree pane selects the top-level rows only**, not the children of expanded
  folders. Which rows are expanded is private to the view and a menu item cannot see
  it, so "everything visible" would be a guess — and selecting a folder *and* its
  contents copies both, once as the folder and again as its parts. Columns resolves
  through the deepest open column, the same folder ⇧⌘N uses.
- **Edit's four items are never greyed out.** A menu item cannot know where the caret
  is when it renders, so disabling Copy when no files are selected would grey it out
  while somebody is typing in the ⌘K field. The accepted cost is an enabled Paste
  that does nothing on an empty clipboard.
- **⌘K cannot switch to the source a typed path is in.** A path under a source the
  pane is not showing is listed and marked "In <source> — switch source first" rather
  than delivered. Doing it properly means suppressing the provider change's own
  navigation reset, or the pane lands at its root with the folder silently dropped.

---

## v4.1

Tabs. One pane, many parked locations — the thing that turns a two-pane
comparison into a place where several jobs stay open at once. Behind them the
release is mostly repair: eleven things a v4.0 install really did, most of them
the app destroying or misdescribing a file and saying nothing about it.

On the v4 line, so it **requires macOS 26** — coming from 3.x or 2.x, read the
v4.0 section first.

### Tabs

- **Every pane gets a tab strip.** A tab is a location a pane holds, parked: its
  folder, the column stack inside it, its history and its selection. Switching
  between tabs in one folder paints from memory rather than re-walking the disk.
- **The strip draws nothing at one tab**, and sheds down three rungs as space runs
  out: every tab at full width, then a floor width with the surplus behind a count,
  then — at the ~220pt Organize and Storage rail — the active tab alone as a chevron
  menu, with a plain count for the rest and a ＋.
- **Finder's chords.** ⌘T opens a new tab *here*; ⌘W closes the tab rather than the
  window once there is more than one; ⇧⌘[ and ⇧⌘] walk the strip in both directions;
  ⇧⌘T shows the bar at a single tab from the View menu, and once a second tab is
  open on either pane it is ticked and locked on, so a strip's tabs can never be
  hidden out of reach.
- **⌃⇥ cycles tabs in Browse**, where it had always been dead — there is one pane
  there, so a chord that moves between panes had nothing to move between. Compare
  keeps it as the pane switch, and the menu item's title says which you are getting.
- **In Columns, ⌘-double-click a folder to open it in a new tab**, and double-click
  the empty stretch of the strip for a new one. The double is deliberate: a plain
  ⌘-click is multi-select and has to stay that way.
- **New Tab is on the header card's right-click menu** — the one route that needs
  neither a folder under the pointer, nor a strip, nor empty space below the rows —
  and on the pane's empty-area menu beside New Folder. With no ＋ on screen until a
  second tab exists, those menus are the whole discovery story. Close Tab withholds
  itself at one tab rather than offering to close the window.
- **Tabs pin.** A pinned tab keeps its place, and *Close Other Tabs* stops being
  offered when every other tab is pinned and the verb would do nothing.
- **In Compare, both panes wear the strip together.** A strip on one side only
  pushes that pane down 34pt, from which every row names a different folder on the
  left than on the right. A second tab on either side draws the strip on both.
- **Opening a folder in a new tab follows the link.** With the seam's 🔗 on, or ⌥
  held, it opens one on the other pane too — pruned to the deepest folder that pane
  actually has, the same treatment a mirrored drill gets.
- **The strip survives a quit** — each tab's source, its folder, the depth of its
  column stack, and whether it was pinned. Selection, history and a typed search
  stay with the session. It follows *Reopen panes where I left off*, and Compare's
  right pane gets its own remembered strip rather than sharing the left's.

### Safety

Eleven fixes for things a v4.0 install really did. Most of them are the app no longer
destroying or misdescribing your files.

- **A folder the app cannot read no longer counts as an empty one.** macOS hands
  back a working directory enumerator for a folder it has no permission to list, and
  that enumerator yields nothing — so at four places the "if the listing failed"
  branch held the honest answer and the filesystem never took it. The folder-replace
  warning said **"0 items will be removed"**, which is the last sentence you read
  before replacing a folder; the destination picker drew **"Empty"**; the Details
  sidebar printed **"Zero KB"**; and the filing rename pass offered slot **01** in a
  numbered folder it could not list. A symlinked folder is no longer mistaken for an
  unreadable one either.
- **Undo could destroy the very thing it existed to protect.** The drift guard —
  the check that stops ⌘Z discarding a file you have changed since — let two states
  fall through to the delete. A **copied folder had no drift guard at all**: copy a
  folder to a NAS, let files land inside it, press ⌘Z, and on a volume with no Trash
  they are gone, logged accurately as "removed 1 of 1". A **file was compared by
  size alone**, so an edit that kept the length compared equal and was trashed as
  untouched. And the **move-undo never looked at the destination**, only at whether
  the source path was free. Redo had no identity check of any kind. An item that
  cannot be read is now refused rather than destroyed, and the refusal says which of
  the two it was.
- **⌘Z is no longer offered for a removal it cannot take back.** On a volume with no
  Trash — exFAT, most SMB shares — a removal escalates to a permanent delete, and
  the banner still read "press ⌘Z to undo". Nothing had gone onto the undo stack, so
  ⌘Z reversed whatever was still on it, which after a filing run is that whole run
  moving back. **The merge's version was worse**: undoing a merge deletes the copies
  it folded into the keeper, so with the originals already gone, ⌘Z took the only
  ones left. Separately, the duplicate resolve **compared two copies by byte size
  alone**, so a rewrite that kept the length was trashed as redundant; that check now
  reads the modification date, and folder groups re-verify their contents.
- **Apply recommended told you it had freed space it had not.** A group whose copies
  something else had already removed still counts as resolved — it leaves the list,
  correctly — but the run reclaimed nothing for it, and its recorded size went into
  the total anyway. Two identical pairs with one copy already gone reported
  **"Reclaimed 5 KB from 2 groups"** for a run that trashed one 1 KB file. The same
  button also gave the wrong advice when it removed nothing at all: **"these groups
  changed since they were scanned — rescan"** was shown for every empty batch, and
  the usual reason is the opposite one — every copy in the group is protected, so
  nothing has changed and the rescan finds exactly what you started with.
- **The log says when a document could not be read**, rather than reading like a
  document with nothing in it. A file the filing scan cannot open — no permission,
  deleted between the walk and the read, an unreachable mount — contributed no text,
  so the suggestion was made from the filename alone with nothing anywhere saying
  why. Three readers were silent about it: a text file that will not open, a PDF that
  will not parse, and an image that will not decode. The OCR reader already said so;
  now all four do. What is suggested is unchanged — this is the difference between a
  scan you can diagnose and one you cannot.
- **Redo re-applies a nested rename in the order that makes it possible.** It
  replayed the undo's order, so a parent was renamed back first and each deeper
  item's recorded destination named a parent that had stopped existing — which
  `createDirectory` obligingly manufactured. Measured: ⌘⇧Z produced a new empty
  folder carrying exactly the risky name the feature had just removed.
- **An automation will not rebuild a provider that has gone away.** Applying a batch
  created the destination with nothing checked, so a provider unmounted between the
  preview and the apply was recreated as an ordinary local folder — and this is a
  *move*, so the files left a live tree for a dead one nothing syncs. The single-file
  filing path had refused this all along; only the automations lacked the guard.
- **One unreadable value no longer wipes every automation rule.** v4.0 made an
  unrecognised *condition* survivable and stopped one level short: a condition this
  build does recognise, holding a value it cannot read, still threw out of the whole
  array — so every rule vanished from the lens and the next rule you created wrote
  the empty set back over them. A rule now carries the parts it cannot read
  verbatim, never runs while it holds one, and reads *from a newer version* in the
  editor. As with v4.0's entry, **this protects the next upgrade rather than this
  one**.
- **An unreadable `~/Library/CloudStorage` made your cloud accounts disappear.** The
  same enumerator, behind the one site with a read-modify-write after it: the folder
  produced an empty list, and provider discovery *publishes over* the list it holds,
  so every mounted Dropbox, Google Drive and OneDrive vanished at once — with the
  synthesized iCloud entry left behind to make the truncated list look plausible.
  Nothing was logged.
- **The cross-person veto never fired for a folder that did not exist yet.** v4.0
  said a suggestion filing one person's document into another's folder is refused,
  and for a destination the model proposed *creating* that was not true: the rule
  opened with an exact lookup, and a profile describes the folders that do exist, so
  every proposed-new-folder destination skipped the veto — no refusal, no log line,
  no user-visible trace.
- **Tree and Columns agree on where the pane is.** Browse three columns deep, flip
  to Tree, and the breadcrumb still named the folder the columns had stopped in — a
  folder the tree was not showing, with `‹` lit but dead, crumb clicks landing on
  nothing, and Scan offering to walk the wrong folder.

### Organize's scope, and the palette's pins

- **A row menu in the pane that did not have focus wiped Organize's scope.** A
  SwiftUI context menu does not move focus, and the scope setter read the *focused*
  pane's root — so right-clicking a folder in the other pane normalised it against
  the wrong root, which answers "nothing". The scope you had set and the folder you
  had just named were both gone, and it survived a relaunch.
- **Right-click ▸ Open in Browse or Storage re-aimed every Organize lens.** The
  write was gated on a layout flag that predates Browse existing, so opening a folder
  in either pointed all six lenses at somewhere you had never told Organize about —
  and that survived a relaunch too. Paths resolved correctly, so nothing looked
  wrong; the lenses were simply answering about another folder.
- **A folder pinned in the breadcrumb now reads as pinned in the pane.** The
  folder-jump store keyed on the caller's string with no normalising, and the app
  carries two spellings of the same root — a folder source keeps its `~`, while every
  surface that touches the disk expands it first. A pin written under one spelling
  was invisible to readers holding the other. Installs that pinned the same folder
  twice get the two entries merged into one.

### Panes and the pane bar

- **Browse keeps its preview column when Compare turns one off.** One stored
  preference served four surfaces that want two different answers: Compare's panes
  and the Organize/Storage rail are read *against* something, where a preview costs
  half the room — while Browse is the pane where reading a file *is* the task.
- **A column row spends its width on the name.** Folder rows carried the folder's
  own mtime, which on a tree of filing folders reports the last tidy rather than
  anything about the contents — and at the default text size it cost the name about
  76pt of a 210pt column (66pt of date, plus the gap in front of it), enough to
  truncate "Birth Certificate".
- **The pane bar's controls now show their names** — a short word under each pill as
  Finder's toolbar does, turned off from the bar's right-click menu beside Icon Size,
  and the first thing the bar sheds on a narrow pane. Text Only is dropped: with the
  glyph gone the word becomes the only carrier of state.
- **A fixed space on the customize track can be aimed at.** Its pill is a dashed
  outline with no fill, and a SwiftUI shape is hit-testable only where it is painted
  — so the drag that removes it, the drop that moves things around it, and its menu
  were all attached to a 1pt ring. A space once added could never be taken off again.
- **Dragging a control off the pane bar stops showing the copy badge.** macOS put a
  green ＋ on the cursor — the sign for "the item will still be there" — over a
  target whose only job is to delete it.
- **The pane bar's ⋯ is now only about width.** It used to hold two unrelated things
  under one glyph: controls this pane is too narrow to draw, and controls you had
  deliberately taken off in Customize. The second meant the sheet could not actually
  remove anything — it demoted a control into a menu one click further away, on a bar
  that then gave up some of the room it had just gained. Removing is now removing,
  and the sheet's palette is where a control is got back from. If Show Hidden Files
  is the one you took off, **Hidden Files** (⇧⌘.) still reaches it.
- **Customize Pane Bar… has left the ⋯ menu.** It is a command about the bar's
  appearance, and it was riding under controls that were there because of the
  window's width. Right-click the bar, which is where anyone who has arranged
  Finder's toolbar tries first.

### People

- **A repeated id in `people.json` now names one person.** The roster is a file you
  can edit by hand, nothing rejects a repeated id, and every reader answered it
  differently: the phrase list took *both* records, the token map the *last*,
  `person(id:)` the *first*, and the Settings list drew the first record twice — so
  one row showed the first record's name above the last record's facts, and the
  second person never reached the screen. The collapse now happens once, at the
  single door every reader comes through: last wins, and the first occurrence keeps
  its position.
- **A person listed twice was switched off by the duplicate.** A given name is
  published only when exactly one id claims it, so somebody listed twice claimed
  their own given name twice and the claim was dropped — their given-name matching
  silently disabled by the entry that looks like it reinforces them. Measured: with
  the fix reverted, a roster listing Girish twice returns nothing at all for
  "Girish statement.pdf".
- **And opening Settings ▸ People no longer crashes on such a file.** That pane built
  its facts with `Dictionary(uniqueKeysWithValues:)`, which *traps* on a duplicate
  key — so a copy-pasted person block whose id was not changed took the whole app
  down on opening that tab.

### Known limitations

Three things tabs do not do in v4.1. All three are deliberate, and none puts
anything out of reach.

- **⌃⇧⇥ does not cycle tabs backwards.** The pair has to split the way ⌃⇥ does —
  backwards tab in Browse, backwards *pane focus* in Compare — and there is no
  reverse pane switch to mirror. **⇧⌘[ and ⇧⌘] cycle both directions everywhere**, so
  this is a missing second route, not a missing capability.
- **⌘-double-click opens a new tab in Columns only.** The tree view drives navigation
  from single taps and disclosure, and a second recognizer there has to be proved not
  to cost either — the proof the row drag that was removed on the same suspicion
  never got. **Right-click ▸ Open in New Tab works in both views.**
- **⌘W closes the window when the focused pane holds one tab**, whatever the other
  pane holds — so in Compare, a focused pane with one tab and a sibling with five
  takes the window and all six. That is Finder's rule, and every alternative makes ⌘W
  conditional on state you cannot see. The header card's **Close Tab** item withholds
  itself at one tab, so the menu route cannot surprise anyone; this is the chord only.

---

## v4.0

**The largest release SyncCloud has had** — 284 commits,
against v3.0's 181 and v1.0's 142 (both verified against their tags) — and a
major for the reason v2.0 was one: the shape of the app changed. The workspace bar
goes from five segments to four, and two of them are new answers to "what is this place for". Duplicates
and Automations are gone as places — they were never peers of Compare and Storage,
they are things you do to a single tree, and **Organize** is now the one place the
app proposes a change to one. **Browse** arrives as the plain file browser the app
has always contained and never let you look at directly. The bar reads Browse,
Compare | Organize, Storage: the first two look at trees, the last two act on or
account for one. Underneath all of it, SyncCloud learns who the people in your
documents are, and files by that.

It **requires macOS 26**, as the v3 line did — coming from 2.x, read the v3.0
section first.

### At a glance

| | |
|---|---|
| **Browse** | A fourth workspace: one tree, the whole window, no lens |
| **People** | A household SyncCloud knows by name, and files by |
| **Organize** | Five lenses, one scope you set, one overview you land on |
| **Restructure** | A new lens that reports where your tree's shape disagrees with itself |
| **Same-text duplicates** | Finds the re-downloaded copies a byte hash cannot see |
| **To File** | Routes by what a folder already contains — on a surveyed tree, 61.9% first-try |
| **Renames** | Names the file for the folder it lands in, with a backlog pass |
| **Compare** | A scan you can stop, what the last one found, and which rows failed |
| **⌘K** | One field that reaches folders, people, sources, places and actions |
| **Shortcuts** | A menu bar full of chords, plus ⌃⇥ between panes |
| **Look** | One file-type vocabulary, one setup card, one pill family |
| **Free** | The Organize scan no longer spends money — Refine does |

### Browse — one tree, the whole window

- **A fourth workspace with no lens and no opinion.** One tree at full width,
  nothing proposing anything: where you go when you do not want a lens's view of
  your files.
- **A new install now opens here**, rather than on a comparison of two clouds it
  has not scanned yet. **Upgrades are unaffected** — you carry a stored workspace
  and the app still resumes wherever you left it; only a machine with nothing
  stored is answered by this.

### Before you upgrade: this is a one-way door for automation rules

- **Rules you create in v4.0 cannot be read by v3.x, and opening them there hides
  the rest.** Rules persist as one JSON blob, and older builds throw on a condition
  they do not recognise — which does not skip that rule, it takes the whole array
  with it, and the next edit writes the empty set back over them. The raw bytes do
  survive, copied aside under `automationRules.unreadable`, but there is no in-app
  way back from there. A rule using the new *is <person>'s document* condition will
  do exactly that on v3.1 or earlier.
- v4.0 fixes this going forward: an unrecognised condition is now preserved
  verbatim, shown in the editor as *written by a newer version*, and never allowed
  to file anything. **That protects the next upgrade, not this one.** Export your
  automations before installing if you may go back.

### Organize is the one place the app proposes a change to a tree

- **Organize changes one tree on the app's suggestion, and it is the only place
  that does.** Compare holds two side by side, Storage reads one and changes
  nothing, and Browse looks at one — you can rename, move and delete there by hand,
  but nothing proposes it for you. Duplicates and Rules are lenses inside Organize
  now — the journey risky names already made in v3.0. Your stored workspace
  migrates forward.
- **A five-item rail inside Organize**: To File, Duplicates, Renames, Restructure,
  Rules. These are permanent items, not the chips that came before: a chip only
  exists once a scan has found something, so there was nowhere for *"organize this
  folder"* to land before running anything. The badge keeps the old behaviour — a
  count when there is one, nothing at zero, never a greyed "0".
- **Risky names are part of Renames now**, as a *to fix* section at the top of the
  backlog: a name your provider will not accept is one more kind of rename, and
  both answers already came off the same walk. It appears only when it has
  something to report, with per-row Fix and a Fix-all. A stored Names selection
  resolves to Renames.
- **The rename backlog is organised category-first**, grouped by parent folder,
  with one Rename column and a tree to review by — on a real tree the pass has four
  figures in it, which is not a flat list anyone can read.
- **The rail's unselected state is an overview** — the answer from each of the four
  lenses that produce one, for the current scope, on one page, with three states
  each that never borrow one another's words: never ran, ran and clean, or
  findings. Rules takes no section there: it is configuration you write, not a
  finding about your tree. The overview is not a sixth item, so it cannot become
  the tab you forget to visit; you land on it.
- **One scope, which you set.** Every lens answers about the same territory, and
  you choose it: a folder you point Organize at, or the whole tree. It is explicit,
  it survives a relaunch, and **browsing never moves Organize's scope on its own**
  — a row of peers each quietly answering about a different folder is how a badge
  comes to report a count with none of what it counted on screen. Global is the
  default, and the scope chip says which you are in. (What a scan started from a
  pane walks is a separate, pane-local thing, and that one does follow the columns
  — see *Windows, panes and previews*.)
- **Scope filters, it does not rescan.** Filing suggestions, names and renames come
  off one walk and Restructure reads the folder profile, so narrowing is instant. A
  duplicate group is in scope if *any* copy is, and the out-of-scope copies stay
  visible — hiding half a group turns a two-copy decision into a one-copy one,
  which is how the wrong copy gets trashed.
- **Right-click any folder and choose "Organize This Folder…"** — in Browse, in
  either Compare pane, or in Organize's own rail, list or columns. It opens on that
  folder's filing queue and scans it.
- **Restructure arrives, report-only.** It reads the same folder profile the
  router does — so it too waits on a survey — and reports
  families of sibling folders shaped differently in different years, under two
  rules validated against a real tree: axis values are not structure, and
  difference is not divergence (two groups of two, not one odd sibling). It does
  not yet propose a plan — a plan is a manifest of typed operations over years of
  documents, and has its own invariants to satisfy first.

### A household, not a bag of names

- **SyncCloud now knows who the people in your documents are.** This is new, not
  improved: v3.1's filing engine had no notion of people at all — it filed by what
  a folder's documents were about, and "whose document is this" was not a question
  it could ask. A household is now a thing you keep: each person with the name
  forms they answer to, their aliases, and how they are related.
- **Names are matched phrase-first, longest wins, and a match is consumed.** In a
  real family one word is several people — `abhishek` is one person's given name
  and three others' surname; `girish` is a given name, a surname and a maiden name
  at once. In "Aditi Abhishek" the surname is spent on Aditi and never doubles as
  evidence for her father. That rule is what makes the feature safe enough to act
  on at all — without it, every shared surname in a real family is evidence for
  everyone who carries it.
- **People is its own place in Settings, and a row with folders behind it says what
  it buys** — the name forms matched against a document in the order they are
  tried, how many folders in the tree are theirs, how many documents are already
  filed in them. Somebody you have just added carries neither number, having no
  folders yet. You can add, edit and remove people; edits take effect without a
  relaunch, and no saved suggestion is replayed against the old household.
- **The editor teaches while you type**, showing live what the draft would match
  and which words are that person's alone — judged against the rest of the roster,
  because whether "girish" is distinctive is a fact about the household rather than
  about one person.
- **A rule can say whose document it is.** *is Aditi's document* rather than
  *mentions "aditi"* — not the same claim, and for a real family usually the wrong
  one. It keys on the person, so it survives a rename and starts matching a new
  name variant the moment you add one.
- **`{person}` as a destination.** `Immigration/OCI/{person}` files each person's
  card into their own folder, so what needed one rule per family member needs one
  rule. After a filing, the offer proposes the specific rule always, and the
  generalised one when the folder is named for the person and the documents share a
  topic word — that is the case where the substitution reproduces the path it was
  learned from rather than inventing one.
- **The roster grows from what you have already filed.** *Look for names* reads the
  filenames inside each person's folders and offers forms their record lacks —
  "Muktha Girish", with how many documents use it and one of them named, because
  "add this?" with no evidence is a request to trust the app about somebody's name.
  *Not a name* is remembered and travels with the roster. The rule is deliberately
  narrow: a run is offered only when every word in it already belongs to someone on
  the roster, which cannot invent a name from nothing.
- **A document that names nobody can still be attributed** — by identifiers that
  only one person's folders have ever received. A number two people share is a
  household account, and is never used. This answers last, below both the filename
  and the page, because an account number is the strongest evidence in an
  unlabelled document and the most surprising thing to be filed by.
- **Search resolves a person.** Type a name into ⌘F and a row appears beneath the
  field — *"Aditi — everything that is theirs"*, **⌘↩** to take it — turning the
  find into a gather of everything of hers across the whole source. The find itself
  is untouched: ↩ still walks to the next match and ⇧↩ back to the previous one,
  whether or not the query names somebody, so the offer costs the find nothing.

### Filing that reads your tree

The router reads a *folder profile* — the record of what your tree already holds.
It comes from a survey of the tree, which is something you run rather than
something the app writes as it goes: on a machine that has never been surveyed
there is nothing for the router to read, and Organize files as it did in v3.1.

- **On a surveyed tree, loose files are routed by what a folder already contains**,
  before any model is asked. Two things about each destination — what the folder
  *is*, and the distinguishing words of the documents already filed there. Leave one
  document out of 9,558 real filed ones and make it choose among ~2,950 folders: a
  bare folder list gets 12.6% right first try, adding what the folder is takes it to
  28.9%, and adding what it has received takes it to 58.2% (77.4% in the top three).
  Two further rules found by measuring — inheritance kept in scale, and the
  document's own years — bring the shipped router to **61.9% first try, 81.8% in the
  top three**, that pair measured on a held-out split of 7,370 documents rather than
  on the ladder's leave-one-out.
- **The model re-ranks that shortlist instead of answering past it**, and is shown
  only folders the file could actually go in — listing an inbox teaches a
  classifier to file into the place things go when they have nowhere to go.
- **Rules are learned from what a folder has received** — the same surveyed record,
  so this too waits on a survey — not from one word in the folder's name, and a
  learned year becomes `{year}` rather than the year the example happened to have.
- **A scanned PDF can be read on request.** A PDF with no text layer reaches the
  classifier as a bare filename, so its suggestion is a guess about a document
  nobody read. The scan now records which files would benefit and spends nothing; a
  **Read scan** button appears on exactly those. Measured on real scans, page 1 at
  2× plus Vision takes 0.5–2.1 seconds each — a click for the card in front of you,
  rather than every file in an inbox read on spec.
- **A suggestion that would file one person's document into another's folder is
  refused**, consulting the page the scan already read when the filename names
  nobody. The filename outranks the page:
  a page-1 mention is testimony — an application prints its sponsor, a report card
  names a sibling — while a filename is your own label.
- **A proposed new folder can be renamed before it is made.** A backend could
  already answer with a sub-path that does not exist yet; what is new is that the
  name it picked is yours to edit before anything is created. The destinations
  themselves come off the scan's own walk of your tree, so a folder you made this
  week is a folder the router can offer.

### Naming files for the folder they land in

- **Organize could say where a loose file belongs but not what to call it once it
  got there**, so the house convention was applied by hand and decayed exactly
  where the volume is. A rename is now proposed alongside the move, and a backlog
  pass covers folders already filed under raw names.
- **The rules came from the tree, not from a description of it**, and two changed
  as a result. The ordinal is a *position*, not a month — across 327 such folders,
  118 of the 132 that can tell the readings apart number by position, so the scheme
  is inferred per folder and per extension. And padding is the backlog: 567 files
  carry a one-digit ordinal, which misorders past September. An inbox's filenames
  are left alone throughout — they are still routing the file — and the backlog has
  its own search, which its scan clears.

### Duplicates finds the copies a hash cannot see

- **The same document downloaded twice is now found.** Providers re-generate a PDF
  on every download, so the same bill fetched twice is byte-different with
  identical content — and the duplicate scan reported a clean result that was
  wrong, silently, because those files hash fine and simply fail to match, so no
  counter moved. SyncCloud now also fingerprints what a document *says*: the sorted
  token multiset of its extracted text and form-field values, plus its page count
  and page geometry.
- **It is a weaker claim, and it says so.** Matches group as **same text** rather
  than identical, with their own badge, their own note, and a standing exclusion
  from *Apply recommended* — a content match is evidence, not a byte-for-byte
  guarantee, and it should never be resolved without a look.
- **Replayed over a real tree of 10,569 PDFs** it finds about 250 groups the
  content hash cannot see — **248 on each of two replays**, with a handful moving
  between full runs, because a pair that groups when read alone can fail to group
  inside a whole-tree pass. The direction is one-way and that is the part that
  matters: the residue costs an unreported duplicate, never a false claim about
  one. It never splits a byte-identical pair: 485 such pairs fingerprinted on both
  sides, and 0 disagreed, in every configuration tried.
- **The copies about to be trashed are re-verified, not just the keeper.** The
  resolve had re-checked the keeper's existence and size since it was written —
  half a guarantee, protecting the half being *kept*. A duplicate group is a
  point-in-time snapshot whose results outlive the scan, and the same-text phase
  alone takes minutes on a real tree; rewrite one of the copies in that window — a
  re-export, a provider re-download, an edit — and its path still exists, so it was
  trashed under a banner calling it redundant when it was the only instance of its
  new content.
- **Duplicate group headers align on invisible columns**, so a page of groups reads
  down the page instead of each header setting its own margins.

### Compare

- **You can stop a scan.** Every lens has had a Cancel since it shipped; the Compare
  scan — which walks two entire trees and is the longest thing the app does — had
  none, so starting one against the wrong roots meant waiting it out or quitting.
  The pane rung becomes **Stop** while a scan runs, and the busy card grows one.
- **It says how long it has been running.** Not a percentage: counting the total
  first would mean instrumenting the walk's hottest loop, and a fraction that isn't
  measured is worse than a number that is.
- **Compare opens on what the last scan found** — a count and how long ago, in the
  past tense — instead of "Nothing scanned yet". Never the rows: every action Compare
  offers against a row writes files, and a three-day-old *"Copy 412 to →"* is
  exactly the stale-world apply the caches exist to prevent. The only button stays
  **Scan**, and the summary appears only for the exact comparison the panes are
  pointed at now.
- **A partial transfer shows which rows failed.** The alert used to name the first
  failure and point at the Activity Log, so finding the other eleven of four
  hundred meant reading a text log in another window. A **Failed to transfer**
  filter now selects them and the table lands on it. A clean run or a rescan clears
  it.
- **A Path column, and the selection matches the panes.** A file directly in the
  compared root was unplaceable — the only location signal was a hover tooltip. The
  table is now Name · Change · Path · Size. The **"Copy to" column is gone**; it
  restated what Change already said.

### Organize's cost, and what it does for free

- **The scan no longer spends money.** "Suggest homes" used to do everything in one
  click, including a pass that reached Claude whenever the cloud toggle was on — so
  the only button that produced results was also the button that billed you. The
  scan is now entirely on-device. **Refine**, on the results, is what re-asks the
  model named in Settings.
- **This reverses what v3.1 said about the price.** v3.1 put the estimated cost on
  the setup card because the button beneath it could spend; that button is free now.
  The estimate you approve is the Refine pre-flight, which prices a batch it has in
  hand rather than one it is predicting.
- **Duplicates and Organize re-scan when you open them on a target they have
  scanned before.** Results are never restored from disk — every row carries an
  action that writes files — so the scan re-runs against the live filesystem
  instead. Three conditions, so it cannot surprise you: the folder is exactly what
  their last completed scan covered, it is still there, and nothing has already run
  against it this session. It costs nothing to do that now, because the scan itself
  is free: spending is Refine's, and Refine is a button you press.
- **One paid click has no pre-flight — "Try another" on a suggestion card.**
  Rejecting a destination and asking for a different one is the Refine pass for a
  single card, so it reaches the model named in Settings, and it has never consulted
  the spend estimate; a dialog per card click would be worse than the gap. The hard
  monthly and total caps still bound it, and with the cloud pass off — which is the
  default — it cannot spend at all. But the estimate you approve is Refine's, and
  this click does not raise it.

### ⌘K goes anywhere

- **One field that reaches your whole tree.** ⌘K opens a palette over the window:
  type a few letters and it offers folders to jump to, people on your roster, your
  configured sources, the app's own places — Browse, Compare, Organize's overview
  and each of its lenses, Storage — and its actions: Rescan, New Folder…, Choose
  Folder…, Find in Pane…, Settings, Keyboard Shortcuts, Activity Log. ↩ goes; Esc,
  a click outside, or ⌘K again dismisses it. There is a *Go to…* pill on the
  toolbar for the same thing.
- **Results are grouped, and the groups are ordered by their best match** rather
  than the list being one flat ranking with headings sprinkled through it.
- **It indexes the folders you actually have** — the same tree Organize walks,
  so a folder you made this morning is reachable by name this morning.
- **A row that matched on the text you can see shows the matching run**, so why it
  answered is visible rather than inferred. A row reached through a keyword draws no
  emphasis at all — its visible text genuinely did not match, and bolding something
  there would say otherwise. The palette teaches its own keys rather than expecting
  you to know them.

### Keyboard and focus

- **Menu-bar shortcuts for the things you were already doing**, and the ones on a
  control appear as keycaps during the ⌥-hold reveal: ⌘1–⌘4 switch workspaces in
  the bar's order, ⌘[ / ⌘] walk the focused pane's history, ⌘R rescans, ⇧⌘N
  creates a folder, ⇧⌘. and ⇧⌘P toggle hidden files and the Columns preview, ⌘⌫
  deletes the selection, ⇧⌘R and ⇧⌘V start Review and Verify, ⌘D shows the
  differences list, ⇧⌘F folds every folder, and ⌘I / ⌘L open the inspector and the
  Activity Log. Chords follow Finder wherever Finder has one.
- **⌃⇥ moves keyboard focus between the panes.** The pane-scoped chords — ⌘F, and
  the four that join it here — resolve through whichever pane holds the selection,
  which on a cold window is nothing, and the rule fell back to the left pane. So
  aiming any of them at the right pane meant clicking a row in it first; there was
  no keyboard path to the right pane at all.
- **The focused pane's provider capsule is ringed**, because the panes' only
  existing "which one is active" cue modulates *selected rows* — saying nothing in
  exactly the case ⌃⇥ exists for.
- **The pane bar's magnifier now really does tint while a query is live.** It has
  claimed to since ⌘F shipped in v3.1, and it never did: the tint was set on the
  button while the glyph sets its own colour, and the inner one wins. So a search
  that was narrowing what you could see sat behind a glyph that looked idle —
  exactly the state the tint existed for, since a collapsed field has no other
  carrier on screen. Measured: zero accent pixels either way before, and genuinely
  tinted now.

### Windows, panes and previews

- **The window has a floor: 760 × 560.** It carried a 600pt minimum width and *no
  minimum height at all*, and `.contentMinSize` makes that frame the floor — so the
  window could be dragged down to the toolbar and nothing else, a sliver with the
  pane header, the file list and the action bar all squeezed out. 560 is what
  refusing that costs: two of its rungs come off the panes' own constants — 86 for
  the header card, 44 for the action bar — and the roughly 430 left over is the
  judgement that what remains should be a list rather than a peephole.
- **An open Quick Look panel follows the selection.** It was a snapshot, not a
  view: Space opened a preview of whatever was selected at that instant and then
  nothing ever moved it — click another file, walk a search, re-root the pane,
  switch workspace, and the panel sat there naming a file long gone while looking
  exactly like a live preview of the current selection. It now follows the
  selection and closes when the selection is cleared, which is Finder's rule.
- **A space typed into the pane search field is a space.** It reached the ancestor
  Space handler and opened Quick Look instead, so ⌘F could not be used for any
  query of more than one word.
- **Clicking through columns moves what a scan started in that pane will walk.**
  Every Organize scan action and the *"Scan '<folder>'"* offer read only the pane's
  comparison focus, so browsing the columns never moved the target: the offer sat
  dead at the provider root no matter which folder was selected, and a scan launched
  from the toolbar walked a folder the pane was not looking at. Organize's own
  scope is a different thing and is unaffected — you set that one, and browsing
  still leaves it where you set it.
- **An empty tree is captioned once.** The column stack overlaid its own small
  *"Empty"* caption on any column with no rows — including the first column, which
  already draws the pane's full "Folder is empty" placeholder — so the two rendered
  stacked, the caption drawn through the placeholder's folder glyph and clipped.
- **Organize no longer opens on an inbox nobody asked for.** Switching to Organize
  moved the source rail into the loose-files inbox, which defaults to `TODO` on a
  fresh install — so the first switch re-rooted the pane on a folder you had not
  asked for, with nothing on screen saying why. The setting can also now say *off*.
- **The scanning placeholder stops drawing a gray slab.** Its loading card wore a
  material, and a material blurs what is behind it — on an empty pane there is
  nothing behind it, so what it actually painted was a flat gray rectangle in the
  middle of a white surface.

### A look that holds together

- **One file-type vocabulary everywhere.** Storage's ranked lists drew every file as
  the same gray document glyph while Duplicates drew raster icons — two surfaces,
  one file, two vocabularies, and at the 13–16pt these rows draw at, a shrunken
  raster thumbnail reads mostly as "rectangle". There is one map now: an SF symbol
  plus an identity tint per kind — red document for PDF, purple photo, teal note for
  audio, indigo film, blue for word processing, green grid for spreadsheets, orange
  presentation, brown archive.
- **Every lens opens the way To File opens** — the setup card, with the job and the
  safety contract up top, one trigger, and **sample rows in the shape real results
  take**, which is what makes the first real result list legible. All six adopt it,
  each with sample rows in their own row shape, at one height so the card stops
  jumping as you move the rail. There was no such card at v3.1: coming from there,
  Duplicates, Storage and Rules all change — Rules drew a plain empty state — and
  Renames and Restructure arrive wearing it.
- **The quiet chrome says true, whole sentences.** *"Hashing 0 candidates…"* becomes
  *"Looking for candidates…"* when no two files share a size, and the spend rows no
  longer print *"1 files"*.
- **One counting pill, one progress dialect**, across Storage's counts and the
  Duplicates toolbar.
- **The welcome tour describes the app you actually installed.** It offered
  "iCloud, OneDrive, Google Drive, or Dropbox" as the things a source can be —
  written before v3.0 made *any folder* a source, and never updated.

### Settings, and text that scales properly

- **Organize's Settings tab becomes three**: Organize, **People**, and
  **Intelligence**. It had become several subjects under one rail row, and the tell
  was its caption — one paragraph of eight sentences, because one caption had to
  explain all of them. Intelligence holds the engine and its cost: the free
  on-device pass, the opt-in Claude pass with its key and model, the spend, and the
  cache. Searching Settings for "api key", "anthropic" or "claude" already worked;
  now it lands on a tab about that and nothing else.
- **The text-size setting now has a knee curve.** It was one flat multiplier applied
  to every font alike, which produced exactly the complaint it drew: the 10pt
  captions that most needed help barely moved at Large, while 17–27pt titles
  ballooned. The full multiplier now applies through 11pt, the surplus above grows
  at half a point per point, and nothing being scaled up ever comes out smaller than
  its default — so captions get the whole boost and titles past the crossover keep
  their size. (Small still scales everything down, which is what it is for.)
- **Settings prose moves to 11pt.** Most of the sheet's explanatory text — full
  sentences, not labels — was set as 10pt captions, which put the majority of its
  readable text at the smallest legible size.

### Storage

- **Storage gets the same rail**, and every one of its three sections is counted on
  its rail item — including the untouched-files list, whose count you had to reach
  its own section header to read. All three headers carried a count; the summary
  above them left that one out.
- Its ranked lists join the app's one file-type vocabulary, and its counts wear the
  same pill as everything else that counts.

### Under the hood

- **A document is read once, and says the same thing twice.** PDFKit's text
  extraction is not thread-safe, and SyncCloud was driving it from a concurrent
  queue — four at a time during a scan. Measured over a real 10,286-document tree at
  six at a time, through the reader this release ships, **0.83% of documents came
  back with different text than a serial pass**, and two concurrent passes disagreed
  with each other as well as with the serial one. v3.1's reader — the one that read
  five pages — was worse under the same test, at 1.69%. Every content signal
  downstream, the filing suggestion and the learned rule among them, was being
  computed from text that could change between runs. Extraction now runs in one
  lane.

---

## v3.1

Two questions this release answers that the app used to leave to you: *where is
the file I'm thinking of?* and *what is this scan going to cost me?* The panes
get a real find (⌘F), and the lenses stop re-doing — and, with Claude selected,
re-billing — work they have already done. Around those two: hold ⌥ to see every
shortcut on screen, an inspector answer for "where does this file live?", and
"Find duplicates of this" on every file row.

On the v3 line, so it **requires macOS 26** — coming from 2.x, read the v3.0
section first.

### Find in the panes

- **⌘F searches inside a pane's tree — as a find, not a filter.** Every list in
  the app already had search; the two panes, the hardest and most useful half,
  had none. Matches keep their place in the tree: the matched run is bolded,
  everything off the path to an answer dims but stays readable, and a collapsed
  folder with hits inside says "2 matches" instead of hiding them. Nothing is
  removed, because the tree's shape — where a hit *sits* — is the answer.
- **↩ and ⇧↩ walk the hits**, opening only the folders on the way to each one,
  in Tree and Columns alike; switching view mode mid-search keeps your place.
  Esc puts the field away. In Compare, each hit says **"both sides"** or
  **"left only"** — which side a copy is missing from is usually the reason for
  searching at all.
- **A search never touches the disk.** It runs over the tree the pane has
  already loaded, so a query cannot make a cloud provider download anything.
- **The magnifier joins the pane bar**, including — once — on a bar you had
  customized before it existed. Remove it and it stays removed; ⌘F works either
  way.

### Nothing unchanged is paid for twice

The lenses used to start from zero on every scan: every file re-read, every
Claude classification re-sent, every Storage panel empty until a re-analysis.
Each of those now keeps its work, on disk, across launches.

- **Organize reuses suggestions for files that haven't changed.** A file with
  the same content, under the same model and instructions, gets the suggestion
  it got last time — without asking the model, which with Claude selected means
  **without paying for it**. A "reused" pill on the results says what the scan
  got for free; **Rescan ▸ Ignore saved suggestions** asks afresh (and says that
  it re-runs the paid classification); switching models re-asks everything, and
  Settings ▸ Organize says so, shows how many suggestions are saved, and can
  clear them.
- **The price is on the button that spends it.** Organize's setup card quotes
  your last cloud run — file count, model, cost — before you start, instead of
  after. On a genuine first run it says the run is billed rather than inventing
  a number.
- **Verify and Duplicates stop re-reading gigabytes they have already read.**
  File digests persist across launches, so a rescan of an unchanged tree skips
  the reads entirely — and a cancelled scan keeps what it measured, because the
  reading had already happened. Merges keep their digests too.
- **Storage opens with your last report instead of an empty panel**, marked with
  how old the reading is — "Scanned 2h ago", amber once it is stale — because a
  saved report is a reading, not a live one. Storage is the one lens whose
  results are safe to restore: its only action is Reveal in Finder, so a stale
  row can't misdirect a destructive apply.
- **Everything kept is visible and clearable.** Saved suggestions live under
  Settings ▸ Organize; the file digests and saved Storage reports under
  Settings ▸ Advanced ▸ Saved scan data, each with its size on disk and a Clear.
  Clearing costs time on the next scan and nothing else.

### Hold ⌥ to see every shortcut

- **Hold ⌥ for a fifth of a second and every control with a keyboard shortcut
  grows a key badge**; release and they vanish. The control fades back and an
  opaque keycap takes its place, so nothing shifts and nothing is half-covered.
  Starting a chord, clicking, or typing cancels the reveal — ⌥-click still acts
  on both panes exactly as before.
- **The shortcuts were already there; now they are discoverable in passing**:
  the ⌥ hold is new, and every badged control's tooltip now names the shortcut
  beside the action — joining the ⌘/ reference window that already listed them
  all. VoiceOver hears each control's shortcut unconditionally, since a held
  modifier is not a discovery path a screen reader can use.

### Where a file lives

- **The Info inspector answers "where does this file live?"** — *This Mac
  only*, *This Mac · iCloud*, or *OneDrive only* — as the conclusion of two
  facts shown right above it: the path, and whether the content is downloaded.
  The wording is deliberately literal. "This Mac only" means the path is inside
  no cloud-synced folder — never "unprotected", and never a guess: when the
  answer can't be proved (a file mid-delete, a provider the app never
  discovered), the row shows nothing rather than something plausible.
- **Rows in a folder source carry a small ⌂ when a file is on this Mac only** —
  the mirror of the ☁ cloud-only badge, in the same quiet grey, and free: it is
  pure path arithmetic, no syscall per row. Inside a cloud source's own pane it
  never appears, because there it would mark everything and mean nothing.
- **A disabled source still counts as a second copy.** Its folder is on disk
  whether or not the checkbox is on, so disabling a provider cannot make its
  files report riskier than they are.

### Find duplicates of this

- **Every file row's context menu can ask "does this have copies?"** — the
  question Duplicates answers in bulk, scoped to the one file you're looking
  at. If the current results already cover it, you land on its group, expanded,
  marked, and scrolled into view. If not, the right scan starts first.
- **"No duplicates" is only ever said by a scan that actually looked.** A file
  outside what was last scanned gets "*wasn't in the last scan*" and a button
  that scans its own folder — not a confident all-clear borrowed from results
  that never saw it.

### The window, and what the chrome claims

- **The window's smallest size is 760×560.** v3.1 held a 600pt floor on width and
  **none at all on height** — narrow enough that the workspace bar has shed its
  labels, and short enough to lose the content under the toolbar. The new floor
  keeps the labels at Small, Default and Large text.
- **A clean duplicate scan says which folder it checked.** "Nothing repeats across
  iCloud" is a claim about a whole provider, and a scan of one folder cannot make
  it; it now reads *"Nothing repeats in 'TODO'"* when the scan had a root, and
  keeps the provider-wide sentence only when it did not.
- **And a lens that has never run here says so**, rather than borrowing the words
  for "ran and found nothing" — on the overview and on the rail badge alike, since
  a count filtered to zero is not a check that came back clean.
- **One vocabulary across the lens rows** — medium file-type symbols with identity
  tints, counts in one pill, one progress dialect, and headers aligned on shared
  columns, so a row means the same thing whichever lens you are reading.

### Appearance

- **The segmented pickers in Settings follow the app's accent.** Choosing Cyan
  used to recolour the rail and leave Theme, Text size and List density in
  system blue. The "None" accent keeps the stock macOS look untouched — that
  being the point of "None".
- **The seam between the panes wears its swap/link capsule in the app hue
  again.** v3.0 had rested it on a neutral grey wash to sit level with the nav
  pills; floating over pane content on an already-tinted window, grey read as
  unstyled rather than as quiet. It is back to a frosted accent capsule, with
  its glyph inks bounded so every hue stays legible on it.

### Fixed

- **Switching providers no longer leaves the previous provider's Storage report
  on screen.** Every other lens cleared its results on a source switch; Storage
  kept showing numbers measured somewhere else, under a folder chip naming a
  root the window no longer showed. Read-only, so nothing could be misapplied —
  but it was a reading attributed to the wrong place.

The package suites stand at 3,034 checks with this release, and the new features
were re-reviewed in two dedicated adversarial passes after landing — nineteen
defects found, fixed, and pinned by mutation-checked tests before any of them
reached you.

---

## v3.0

The first release on the v3 line, and the first one that **requires macOS 26**.

Three things here are new rather than repaired: any folder on this Mac can be a
source, a name the cloud will reject is now reported and marked where you already
are instead of behind a tab you had to remember to visit, and the scan is roughly
twice as fast on a real provider root. The navigation above all of it went from
two levels to one.

Changes that shipped in v2.9 are not repeated here — if you are coming from v2.8,
read that section too.

### Requires macOS 26

- **The app now declares the floor it is actually built against.** `project.yml`
  and all seven packages said macOS 15 while the code had been written against 26
  for some time, so thirteen `#available(macOS 26.0, *)` guards and their fallback
  branches were still being compiled for an OS this app was never going to run on.
  **If you are on macOS 15, stay on the 2.x line** — v2.9 is the current
  maintenance release and continues to get fixes.

### One row of workspaces

- **Compare, Organize, Duplicates, Automations and Storage are five segments in
  one bar.** They used to be two levels: a `Compare | Tidy` container picker with
  the lenses nested underneath, which left Duplicates two clicks deep behind a
  word that named no task. The five were peers all along; only the nesting said
  otherwise. The layout rule underneath is now fixed rather than implied — the
  left side is always a file browser, and the right side is either the other
  cloud (Compare) or a lens.
- **Your selection survives the change.** The stored workspace is migrated once
  at launch and every old value maps forward explicitly, so you open where you
  left off instead of being dropped on Compare mid-task.
- **Settings follows the same names.** The Tidy tab — the last place in the
  product still using that word — is now **Organize** and **Duplicates**, each
  wearing the same glyph its workspace wears in the bar. Settings go where the
  work is, so Compare, Automations and Storage get no tab of their own rather
  than an empty one apiece.

### Risky names

- **Names the cloud will reject are reported instead of waiting to be looked
  for.** Rename was a tab you had to remember to visit for a problem you hit a
  few times a year. Organize's scan already walks the whole provider, and the
  name rules are pure, so the names come back on that pass — no second walk, no
  second button. When the scan finds some, a chip appears in Organize's summary
  row with its count; when it doesn't, nothing appears at all. Selecting the chip
  swaps in the same rename list as before — name, reason, proposed fix, **Fix
  all** — without the trip.
- **Both panes, Columns and the Differences table now mark the offender on
  sight**, with the reason on the tooltip. Previously a name that would break a
  sync looked exactly like every other name until you ran Organize.
- **"Fix name…" works.** The row context-menu item had never once appeared: it
  was declared in a protocol *extension*, and since an extension member has no
  witness-table entry, every call through the delegate bound statically to the
  extension's `nil` default. The item was unreachable from the day it was
  written, and nothing caught it — the app built, and a menu item that is merely
  absent looks the same as one correctly withheld.
- **Settings ▸ Organize lists the names you have kept.** Keeping a name has
  always been reversible, but there was no inventory — a kept name draws no
  badge, so nothing on screen led anywhere and "what have I kept?" could only be
  answered by walking your files and reading a context menu per file. There is
  now one row per name with a remove button, plus Clear All.

### Any folder is a source

- **A pane, a scan or a lens can be pointed at any folder on this Mac**, not just
  a cloud account. The source list was built by enumerating `~/Library/CloudStorage`
  plus a hardcoded iCloud entry, so `~` or `~/Projects` could never be a source.
  Two doors, one mechanism: **Settings ▸ Sources ▸ Add Folder…** for deliberate
  setup, and **Choose Folder…** at the foot of every pane's source menu, which
  creates the source and selects it in that pane in one gesture. Choosing a folder
  that is already a source selects it rather than making a second row for it.
- **A new "Check folder names against" setting decides whose rules a folder is
  judged by.** A folder has no naming rules of its own, so judging names against
  it would report an empty all-clear over a folder full of names OneDrive would
  reject. The useful question is "would this survive being put somewhere?", and
  only you know where — the default is OneDrive, the strictest.
- **Reset All Settings says that it removes your folder sources.** It always did;
  the confirmation previously reassured you that files on disk are untouched and
  stopped there.

### Scanning is faster

Measured on two real provider roots of about 40,000 nodes each.

- **94% of path components need no normalizing at all**, and the scan now checks
  that before doing the work rather than normalizing everything: 673,925 of
  719,361 components on those two roots. Name comparison went from about 500 ms
  to about 130 ms, and the whole pass roughly doubled in speed (1.0–1.6 s before,
  0.53–0.82 s after, across four interleaved runs).
- **Flattening a cached tree for the scan costs less than half what it did** —
  809 ms → 377 ms and 1,194 ms → 466 ms on the two roots. In the live app the
  scan's flatten phase went from 1.18 s to 0.51 s.
- **File paths are stored as native Swift strings**, so the scan stops paying to
  bridge them back from Foundation on every comparison: about 135 ms and 181 ms
  off a full load-and-scan on the two roots.
- **A debug log line no longer costs a tree walk when logging is off.** It built
  its message — about 5 ms per 40,000 nodes — before the level gate had a chance
  to drop it.

---

## v2.9

A consolidation release. The surfaces v2.8 introduced settle down, one real
data-loss path closes, and the app finally reports the version it actually is.

It is also **the most heavily tested and reviewed release in the 2.x series** —
about 10,700 lines of new tests, close to double any release before it, taking the
suite from 2,628 checks to 2,867 across four adversarial review passes. That is
where most of the work went, and it is why this list is shorter than the size of
the change suggests.

### Data safety
- **Verify All's "copy the identical files" offer can no longer act on a stale
  verdict.** Undoing a file operation while a verify pass was running left the
  offer describing files that had since moved — and confirming it could overwrite
  the bytes the undo had just restored. The offer now carries the state it was
  taken under and is re-checked at the moment the write is ordered, not at the
  click.
- **A cancelled Verify All no longer offers a partial batch.** Cancelling at 40% of
  500 files still published the verdicts it had reached, so the confirmation dialog
  opened over the top of the "cancelled" banner, offering a bulk write of whatever
  it had got through.

### Cloud files
- **A pane watches every download it starts**, not just the most recent one, so a
  second download no longer leaves the first one's row badged cloud-only forever.
- **The ☁ badge stops answering from a stale memo** — a file that has landed reads
  as local, and a path the app could not stat is no longer remembered as though it
  had answered.

### Columns
- **Opening the preview no longer hides the column it is describing.** The preview
  takes its width off the stack, which covered the deepest column — the one holding
  the file you selected — so you had to scroll right by hand to read what the
  preview was about.

### Appearance
- **The accent picker shows what it does.** Under the twelve swatches there is now
  a live preview — a filled transfer button beside a differences pill — and a
  caption naming what the colour is actually used for. It was the only section on
  the tab that explained itself neither in words nor by example.

### Settings
- **The app reports its real version.** Every release from v0.10 to v2.8 installed
  an app that called itself 1.0 (build 1) — in Settings, in `~/sync-cloud.log`, and
  in Finder's Version column. This one says 2.9.
- **Tidy's loose-files inbox is searchable.** Searching "inbox", "loose files", or
  "TODO" in Settings found nothing, in every 2.x release the control has shipped in.

### Launch at login
- **A login-item update that fails no longer discards the toggle you set while it
  was in flight.** The failure path re-read the service's real state and overwrote
  your switch with it, silently throwing the change away.

### Automations
- **A rule imported, bulk-toggled, or undone no longer re-writes itself.** An
  external change to a rule's enabled state was echoed back as though you had
  flipped the switch — at worst re-entering the very undo that caused it.

### Performance
- **The comparison bar lays out nearly three times faster, and you feel it wherever
  the comparison redraws.** It used to work out which layout fit by building six
  whole toolbars and measuring them — each one materialising both menus, the
  per-filter counts and every transfer label. It now computes the width
  arithmetically and offers the layout engine two. Measured at 900pt: **68.4ms →
  23.9ms per layout pass**, about 44ms of main-thread work removed. The bar's body
  re-evaluates on every render, so that saving lands every time the comparison is
  redrawn — when you point a pane somewhere new, when the selection changes, and
  once per copied file during a bulk sync.

### Fixes
- The destination picker's search says when it is showing a partial answer instead
  of presenting the first N matches as all of them, and its cards stop
  double-bordering.

**Full changelog:** [`v2.8...v2.9`](https://github.com/agirish/sync-cloud/compare/v2.8...v2.9)

---

## v2.8

A destination picker of our own, a preview beside the columns, and a pane bar you
arrange yourself.

### Removed
- **Cross-pane drag & drop is gone.** In practice it had not worked for a long time
  — the drag would lift, but no target ever accepted the drop — so what was on
  screen was an affordance that did nothing. Rather than leave it there, it is
  removed outright in v2.8, and Help and the shortcuts panel no longer teach it. Use
  the transfer buttons or the new destination picker.

### Data safety
- **Three ways a mutation path could destroy what it was saving** are closed.

### Sending files somewhere
- **Organize gets a destination picker of its own** instead of the system panel,
  floated over the window and dressed in the app's own surfaces. It names what a
  move is about to collide with *before* you confirm it.
- **The Tidy rail can send a file somewhere**, and a cross-pane transfer now says
  where it actually puts things.

### Preview
- **A selected file previews beside the columns** — in the Tidy rail and in the
  comparison panes, with the toggle in the pane header.
- The Tidy rail draws columns, a lone column fills its area, and columns are lifted
  off their width floor.

### A pane bar you arrange
- **The pane bar is a canvas you arrange yourself** — drag the controls you use
  onto it, drop the ones you don't, from a customize sheet.

### Performance
- **The file panes stop re-rendering on unrelated state**, the inspector's stat
  moves off the main thread, and the panes stop re-arming a timer and re-statting
  every frame.
- **Tidy and the merge planner now use the content-hash cache**, so neither pays
  again for hashing the other already did, and the merge planner stops re-asking
  what the directory walk already told it.
- A row's fonts are resolved once per pane instead of once per row, bulk-operation
  progress is throttled to one update per percent, and the pane bar computes the
  rung it needs instead of building ten to find it.

### Fixes
- The Tidy rail stops striking out and badging rows with comparison state it has no
  business showing.
- **Space previews the file the app says is current.**
- The overlay cards stop throwing away the Clear setting, and a superseded metadata
  load can no longer claim the memo ahead of the current one.

**Full changelog:** [`v2.7...v2.8`](https://github.com/agirish/sync-cloud/compare/v2.7...v2.8)

---

## v2.7

Browse your folders in columns.

### Columns
- **A new pane view mode, and the default** — panes render as columns, the way
  Finder does, so you can see the path you took instead of just where you landed.
- **Drilling into a folder mirrors onto the linked pane**, keeping both sides in
  step.
- The header shows **one location** for the pane, and the pane arrows understand
  columns before they consult the focus history.
- A click on empty space **puts the selection down**, and a linked breadcrumb click
  reaches the folder it names.

### Scrolling that behaves
- The column stack scrolls **the way AppKit scrolls**, bounce included, and is
  pulled home when the platform's bounce strands it.
- A wheel gesture **locks to its dominant axis**, so a vertical scroll does not
  nudge the stack sideways.

### Clicks
- One pane's deferred clear no longer eats the other pane's next click, and the
  action bar's buttons stop moving when the summary changes.

### Data safety
- **External-volume providers claim their own tree again.** A depth rule introduced
  in v2.6 meant a provider mounted under `/Volumes` claimed nothing — so a
  path-addressed CLI root inside it silently lost its destination-name guard and
  date-noise filter. The test is now what the root *contains*, not how deep it sits.
  *(Regression introduced in v2.6.)*
- **`›` can no longer walk into a folder that no longer exists.** Stepping back out
  of a folder that is then deleted left the forward arrow lit and pointing at a dead
  path — where New Folder, paste, and background drops act.

### Tidy accounting
- A group whose copies are all protected no longer **vanishes from the list with its
  bytes credited as reclaimed** while every copy is still on disk.
- Protected copies are no longer counted as reclaimable, so a group stops promising
  bytes its own "Move to Trash" would never deliver — and its Trash button is no
  longer enabled to do nothing.
- A corrupt store stopped rewriting its whole backup on every read — tens of
  thousands of writes per scan, exactly when the disk is least worth hammering.

### Security
- The copied API key is **marked concealed on the pasteboard**, so clipboard
  managers know not to retain it.

**Full changelog:** [`v2.6...v2.7`](https://github.com/agirish/sync-cloud/compare/v2.6...v2.7)

---

## v2.6

Comparisons you can fold up, and Settings you can read.

### Differences
- **Grouped into top-level folder sections**, so a long comparison reads as a
  handful of folders instead of one flat wall of rows.
- **Sections are selectable and collapsible**, with **Collapse All** on the
  differences bar.

### Settings
- **Stood on a left rail**, so a tab is never cut in half again.
- More air between sections, a looser vertical rhythm, and room for a provider path
  to actually be read.

### Appearance
- A **Text size** setting.
- The seam pill is quiet at rest, and the accent is reserved for meaning "linked".
- On Clear glass the provider capsule gets a ground to sit on, and chrome ink is
  brighter on a dark appearance.

### Keychain
- **Opening the Tidy tab no longer demands your Keychain password.**
- The API key gains a **reveal**, and a replace that tells you it replaced.

### Performance
- SwiftUI no longer deep-compares 40,000 file nodes on the main thread — a folder
  row's subtree is kept out of row comparison, `OutlineGroup` is no longer handed
  the raw node graph, and the Details sidebar resolves its selection through an
  index rather than walking the tree.

### Data safety
- **A bulk sync could overwrite one file with another and report success.** Each
  destination is now asked about its own volume, rather than every item inheriting
  the answer from whichever happened to be first. When a batch mixed a
  case-sensitive mount with the case-insensitive boot volume, two names differing
  only by case both passed the uniqueness check, the workers wrote to the same file,
  and with a Move both sources were consumed — one file's contents gone, a success
  banner, nothing in the Trash. Which files it hit depended on the table's sort
  order.

### Fixes
- Clearing the stored API key now reports whether it actually succeeded.
- The transfer buttons spell out **Copy**, and the link-panes toggle folds into the
  swap chip's seam capsule.

> **Known issue, fixed in v2.7:** a depth rule added in this release stopped
> external-volume providers from claiming their own tree, so a path-addressed CLI
> root under `/Volumes` lost its destination-name guard.

**Full changelog:** [`v2.5...v2.6`](https://github.com/agirish/sync-cloud/compare/v2.5...v2.6)

---

## v2.5

A retuned palette and a hardening pass.

### Colour
- **Terracotta** replaces amber as the attention colour.
- **Accent fills deepened** so every filled control can carry a legible white
  label, with on-accent text paired to the fill's own luminance.
- **Freshness badge** redesigned — scan freshness now lives in the status dot, the
  badge carries its own colour, and the scan action follows it.
- **Clear reads as glass**, with its background carrying the accent.

### Chrome
- **Pane nav controls are drawn in-app** rather than fought from outside: levelled
  pill heights, tinted glyphs, and a real hover state on every chrome-less and
  system-chrome button.
- **Differences bar zoned**, with its primary action fixed left-to-right; the
  difference count gained the same capsule a stale badge wears, and the sort menu
  now matches its neighbours.
- **The action bar says which pane** it is about to act on, and places itself from
  rows that are actually on screen.
- The **differences pane stays open** during a guided review.
- The Activity Log's **search reveal is animated**, and its severity chips count the
  history you have actually revealed.

### Filing
- Cloud Filing's Opus option moved to **Opus 5**, with the generation named in the
  model picker.

### Accessibility
- The transfer buttons are **named for VoiceOver**, and the compaction ladder is
  pinned.

### Fixes
- A filing walkthrough no longer resumes over a preview it no longer describes.
- Closed the bulk-sync exclusion in both directions, and let a sweep stand down
  mid-operation.
- Case is folded when deciding a file is already filed; a stranded review pin is
  released.
- A history wipe now asks first, and New Folder's undo no longer swallows its
  outcome.
- A delete that found nothing says so, and a wrapped busy error is no longer
  misread.
- Clearing the log clears the one you can see, not a handle nobody holds; a log the
  app could not read is told apart from one holding nothing.
- A duplicate batch keeps its hands off the folder it just called intact.

**Full changelog:** [`v2.4...v2.5`](https://github.com/agirish/sync-cloud/compare/v2.4...v2.5)

---

## v2.4

Compare actions, and a quieter Activity Log.

- **Redesigned Compare action bar** — it appears the instant a file is clicked,
  positions itself away from the selected row, and the selection can now be cleared.
- **The differences pane can be collapsed** — a show/hide chevron replaces the
  drag-only divider, and the last file stays visible.
- **Activity Log chrome** — the title bar is hidden, search collapses behind a
  magnifier, surfaces are translucent and Settings-styled, and long messages wrap
  instead of being cut off.
- **The app accent carries through** the compare chrome and row selection, replacing
  the OS gray.
- **New Folder is gone from the Compare action bar**, and the pane link toggle is
  hidden in Tidy's single-source rail where it had nothing to link.
- A **new flat two-pane app icon**, a rewritten README, and a visual GitHub Pages
  feature site.

**Full changelog:** [`v2.3...v2.4`](https://github.com/agirish/sync-cloud/compare/v2.3...v2.4)

---

## v2.3

Bold dark mode, and a true-neutral accent.

- **Dark mode reworked** — a deeper base, accent glow, specular-edged cards, and a
  bolder translucent veil on Clear glass.
- **Graphite accent** — a new hue for a genuinely neutral, monochrome look.
- **Accessibility** — a caution tier in the semantic colour table, a shared 3:1
  contrast floor, and VoiceOver-proof compact fallbacks.
- **Duplicates hardened again** — cross-folder version groups stop pooling unmarked
  originals, and merges refuse to aim through keeper hard links.
- The unreadable-folder fix from v2.2 is **widened to case- and near-name variants**.
- **A failed replace can no longer lose your file** — the staged temp is preserved
  when the source can't be restored.
- **Undo Last Run** is paired with its own run, not whatever name sits on the stack.

**Full changelog:** [`v2.2...v2.3`](https://github.com/agirish/sync-cloud/compare/v2.2...v2.3)

---

## v2.2

One design system, and a Theme to switch it with.

### Theming
- **Light / Dark / Follow macOS** — a Theme control sets the app's appearance
  independent of the system, and switching it updates everything live, down to the
  title bar.
- **Clear glass** lets the desktop through, with frosted controls and carded chrome.
- **Compare | Tidy moved into the window's title bar**, and all five Tidy lenses now
  sit under one header card.

### One visual language
- Unified badge pills, one lens-card surface, one semantic severity table, a shared
  close button and search field, real empty states, and a canonical type ramp — so
  the same idea looks the same everywhere.
- Accent, on-accent, and treemap label colours are derived from **actual luminance**,
  so text stays legible on any hue.

### Density
- **Comfortable / compact list density** extended to the file panes, Activity Log,
  Sync History, lens cards, and the Compare differences table.

### Search & automations
- **Clear Filters**, `kind:` made last-wins, and kind classes shared with Compare.
- A chip's ✕ now removes **every** occurrence of its word.
- Automations gained **Preview / Reveal** inspection.

### Scans that tell the truth
- **Unreadable directories no longer mint phantom "Missing" rows** — a
  permission-denied directory is treated as unexplored rather than empty, the scan
  root included.
- Dataless oversize files are classified as **cloud-only**, not "too large".
- A merge is refused when a source file's modification time changed under it.
- The CLI lists each name-skip's reason inline.

**Full changelog:** [`v2.1...v2.2`](https://github.com/agirish/sync-cloud/compare/v2.1...v2.2)

---

## v2.1

Search that understands what you mean, and scans that tell the truth.

### Search
- **Token search everywhere** — Compare, the Activity Log, and Tidy duplicates all
  gained a chip-based search with removable tokens and suggestions, `kind:` filters,
  and size tokens.

### Compare
- **"Scanned N ago" freshness pill** on the pane header.
- **Selection size** on the action bar, and a **folder quick-jump menu** in the header.

### Tidy & duplicates
- **Content thumbnails** in duplicate cards, and **"Compare copies"** hands a group
  straight to the Compare tab.
- **Safer grouping** — files group as "versions" only with a real marker or shared
  folder; symlinks and cloud-only placeholders are no longer mistaken for duplicates,
  and skipped-file counts are surfaced instead of going silently blind.
- A redundant copy is **re-verified right before** a merge trashes it.

### Cloud-only files
- Not-yet-downloaded files are **flagged**, with a best-effort Download; the badge
  clears once the file lands.

### Activity Log
- **Grouped by day**, with per-file operation runs folded together.

### Automations
- **One rule system** — remembered rules and automations unified, with every newly
  learned rule surfaced for review.

### Safety
- **Undo covers everything** — a full move / copy / delete undo-then-redo matrix,
  plus an Undo affordance on completion banners.
- Never auto-replace a folder from a file's "Apply to all"; no permanent delete
  offered after a merely transient trash failure.
- Fixed OneDrive name-rule false positives and an integer-overflow crash in the
  "Larger than N MB" rule.

### CLI
- Destination names are validated as the app does, and sync skips are reported by
  cause rather than assumed to be collisions.

**Full changelog:** [`v2.0...v2.1`](https://github.com/agirish/sync-cloud/compare/v2.0...v2.1)

---

## v2.0

A ground-up restructure of the window — from a provider-sidebar layout to a focused,
tab-driven workspace.

- **Persistent tab strip** with a single-source rail replaces the provider sidebar,
  at a fixed height.
- **Self-contained panes** — scanning and per-pane actions moved onto the pane
  headers, and the title bar was pared down to Logs and Settings.
- **Differences is now Compare**, with the old Details panel folded into a dedicated
  Compare inspector; Get Info routes there and the pane is resizable.
- The **Name Normalizer** returns as its own **Rename** sub-tab, and Organize's
  loose-files scan defaults to a configurable TODO inbox.
- Previewed automations are **filed for real**, one file at a time, anchored at the
  provider root.
- After filing a loose file, SyncCloud **offers to learn an Automation rule** — and
  asks only when the file actually moved.
- The comparison panes no longer re-walk their 40k-node trees on every selection,
  and the dead first click when selecting in a pane is fixed.

**Full changelog:** [`v1.4...v2.0`](https://github.com/agirish/sync-cloud/compare/v1.4...v2.0)

---

## v1.4

Three new Tidy lenses, plus a durable history you can undo from.

- **Storage Lens** — a treemap of what's eating your disk, with reclaim-candidate
  lists.
- **Sync History** — durable and exportable, with **run-level undo**: "Undo Last
  Run" names the run it will reverse and itemizes it before it fires.
- **Name normalizer** as a batch lens, with per-row Quick Look and Show in Finder.
- **Automations** arrive as a preview-only lens — rich rule cards, grouped results,
  per-rule preview, and a Browse button for the destination.
- **Activity Log** gained on-demand "Show older history" paging.
- **Cloud spend guardrails** — a pre-flight estimate before a scan, a monthly cap,
  and a lifetime cap defaulting to $5.
- A **per-tab toggle to hide the top file panes**.
- Re-verification is instant: SHA-256 is cached by path + mtime + size.

**Full changelog:** [`v1.3...v1.4`](https://github.com/agirish/sync-cloud/compare/v1.3...v1.4)

---

## v1.3

Onboarding and visual identity — the release that made SyncCloud explain itself.

- **A first-run feature tour**, with a vector illustration per page, brand glyphs,
  and motion.
- **In-app Help** — a Help overlay and enriched Help menu, plus Help ▸ Welcome to
  re-summon the first-run card.
- **Provider brand hues** tint provider identity throughout, adapting to light and
  dark.
- **Unified empty states**, and comfortable / compact list density.

**Full changelog:** [`v1.2...v1.3`](https://github.com/agirish/sync-cloud/compare/v1.2...v1.3)

---

## v1.2

AI-assisted filing — SyncCloud learns where your loose files belong.

- **The Filing lens** suggests a destination for every loose file, backed by
  on-device content signals.
- **Two engines** — on-device Apple LLM first, with an **opt-in cloud (Claude)
  classifier** for the hard cases.
- **Remembered rules** — corrections stick, with a legible, editable home in plain
  words; "Try another" re-suggests with rejection learning.
- **Cost is visible and cheap** — spend is surfaced as last-scan, total, and
  history, and the classifier defaults to Haiku to keep a scan to cents.
- A **confidence meter and legend**, Quick Look on Filing cards, and a rescan after
  you navigate somewhere else.
- **Settings ▸ Tidy** — a dedicated tab for Duplicates, Filing, and cloud spend, plus
  a header search that filters across all tabs.

**Full changelog:** [`v1.1...v1.2`](https://github.com/agirish/sync-cloud/compare/v1.1...v1.2)

---

## v1.1

The Tidy tab arrives, alongside a broad UX polish wave.

- **Duplicates lens** — find and resolve duplicate folders and files within one
  provider, including **overlapping-folder merges**.
- **Keeper picker** and a persistent **"Keep separate"** decision.
- **Cancellable scans** with determinate progress through the hashing phase.
- **Differences polish** — an actionable "No Scan Performed" state, per-side totals,
  per-filter counts, directional keyboard copy/move, and a visible "navigate both
  panes" toggle.
- **One icon vocabulary** for copy/move, so three features stop sharing the same
  arrows.

**Full changelog:** [`v1.0...v1.1`](https://github.com/agirish/sync-cloud/compare/v1.0...v1.1)

---

## v1.0

The first complete release: comparing and reconciling the folders you keep across
iCloud Drive, OneDrive, Dropbox, and Google Drive — a native macOS app plus a CLI.

- **Inline guided review** for working through differences one at a time.
- The action bar moved into the **native window toolbar**; invisible dividers, a
  per-pane hidden-files toggle, expanded Settings (conflict policy, startup restore,
  notifications, shortcuts).
- A **"None" accent** option, for the stock-macOS neutral look.
- **Reveal in Finder** and Quick Look on tree rows.
- **CLI** — `--strategy` defaults to replace, skips are explained, roots are
  validated, and a failure exits nonzero.
- **Safety, which is what makes this 1.0** — atomic destination replacement,
  replaced files kept recoverable, permanent deletes gated on Trash-less volumes,
  and orphaned `.tmp_` files swept.
- **Scan is ~8× faster** on large directories.

**Full changelog:** [`v0.20...v1.0`](https://github.com/agirish/sync-cloud/compare/v0.20...v1.0)

---

## v0.20

The Differences table and a theming pass — the last stop before 1.0.

- **Differences rebuilt as a dense, searchable, sortable table**, with header stat
  pills, a right-click menu, directional arrows, and an aggregate multi-select
  summary.
- **Settings becomes an in-window overlay** with a General tab; failures surface as
  structured errors carrying their own actions.
- Per-pane back/forward history, real file icons and metadata, and a ⇄ pane swap.
- Appearance gains a content surface-style picker, a tint slider, and accent-aware
  toolbars.

**Full changelog:** [`v0.19...v0.20`](https://github.com/agirish/sync-cloud/compare/v0.19...v0.20)

---

## v0.19

Sync-aware panes, and drag & drop.

- **Per-row sync status badges**, and provider names replacing "Left/Right" in
  action labels.
- **Drag & drop between panes**, double-click drill-down, and breadcrumb navigation.
- Streaming checksums, plus symlink and case-variant fixes — including a false
  all-missing diff.

**Full changelog:** [`v0.18...v0.19`](https://github.com/agirish/sync-cloud/compare/v0.18...v0.19)

---

## v0.18

End of the first development era (March 2026). Folder comparison and the CLI.

- **Compare folders** with ignore rules, diff refresh, and Copy / Move in an action
  bar.
- Progress bar, overwrite confirmation, Copy/Move-All with apply-all.
- Provider-branded panes and the first Liquid Glass design pass.
- A headless **SyncCloudCLI**.

**Full changelog:** [`v0.17...v0.18`](https://github.com/agirish/sync-cloud/compare/v0.17...v0.18)

---

## v0.17

Multi-selection and bulk move.

- Select many files at once and move them as a batch.
- Details tab, Move-to-source / Move-to-destination, and the first app icon.

**Full changelog:** [`v0.16...v0.17`](https://github.com/agirish/sync-cloud/compare/v0.16...v0.17)

---

## v0.1 – v0.16

The original March 2026 prototype, versioned by hand in the commit log itself —
`v0.1` through `v0.16.6`, all inside four days. These tags preserve that
self-versioning, one per minor.

- **v0.1 – v0.5** — the dual-pane file manager core: Finder-style cut / copy /
  paste with native paste-conflict handling, context menus, and right-click.
- **v0.6 – v0.8** — Get Info, and **undo / redo** across all file operations.
- **v0.9 – v0.11** — consistent logging and error handling, security fixes, and a
  pass over comments.
- **v0.12 – v0.16** — hidden-file toggle, Quick Look, the app icon, and the first
  real test suite.

**Full changelog:** [`v0.1...v0.16`](https://github.com/agirish/sync-cloud/compare/v0.1...v0.16)
