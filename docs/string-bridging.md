# What `FileNode`'s bridged strings cost

`FileNode.id` is `URL.path` and `FileNode.name` is `URL.lastPathComponent`. Foundation hands both
back lazily bridged from `NSString`, and a bridged string is not a Swift string that happens to
have come from Objective-C — it is a string with **no contiguous native UTF-8 buffer**, so every
operation Swift implements as "run over the bytes" has to go the long way round instead.

`NameCheckBenchmark` found this by accident while pricing the risky-name row badge: the same
dictionary lookup cost 77–135 ns on native strings and 1.2–2.1 µs on bridged ones. This file
records what happened when that was chased through the rest of the app —
`Modules/Sync/Tests/Sync/BridgedStringBenchmark.swift`, which is the measurement, and can be
re-run.

**The conclusion is a split verdict, and the split is the point.** `id` should be nativized and
`name` should not: the two fields are spent on opposite kinds of work, and a change that treats
them alike pays for its own win.

---

## How this was measured

```sh
SYNCCLOUD_BRIDGE_BENCHMARK="~/Documents:~/Library/CloudStorage/OneDrive-Personal" \
  arch -arm64 swift test -c release --filter BridgedStringBenchmark
```

Release only, on this Mac's two largest provider roots — `~/Documents` (38,461 nodes) and
`~/Library/CloudStorage/OneDrive-Personal` (41,095). Two roots because one root is an anecdote;
every ratio below reproduced on both.

**Arms are interleaved, never batched.** Each repeat runs every arm once and the arm order
reverses on odd repeats, because medians on this machine drift several percent between identical
runs and a bridged batch timed before a native batch measures the drift as much as the bridge.
Every sample is printed, not just the median.

**The machine is also the CI runner**, and other sessions build on it. The quoted run started at
86.9% idle and ended at 95.3%; a run made earlier at ~12% idle produced the same ratios with
absolutes inflated up to 3×. Ratios are robust to load here, absolutes are not.

Two traps this benchmark had to be repaired for, both of which silently flattered the "native"
arm:

- **`String.==` short-circuits on identical storage.** Keying the lookup table from the very
  array the native arm then queries with handed it a pointer compare on every hit. The table is
  now built from a second, independent nativization, so both arms compare equal-but-distinct
  allocations.
- **A sink that touches the strings is part of the measurement.** The construction arm originally
  sank `n.id.utf8.count` — reading the UTF-8 of a bridged string is the expensive thing under
  test, so the as-is arm was charged ~1 µs per node the nativized arms were not, and the
  round-trip looked about four times cheaper than it is.

---

## What it costs, per operation

Per-item medians, quiet machine, both roots.

| operation | bridged | native | ratio |
|---|---|---|---|
| `Dictionary` lookup, native-keyed table | 4.95 / 5.97 µs | 382 / 454 ns | **13.0× / 13.2×** |
| `Set.contains` | 5.07 / 5.96 µs | 378 / 452 ns | **13.4× / 13.2×** |
| `Dictionary` build, `node.id` as key | 3.13 / 4.28 µs | 341 / 413 ns | **9.2× / 10.4×** |
| `relativeKey` — `utf8.starts(with:)` + decode | 1.44 / 1.80 µs | 122 / 168 ns | **11.8× / 10.7×** |
| `pathHasNothingToNormalize` — one UTF-8 pass | 963 ns / 1.45 µs | 129 / 187 ns | **7.5× / 7.8×** |
| `nearNameKey(foldCase: true)` | 16.6 / 19.7 µs | 4.24 / 4.82 µs | 3.9× / 4.1× |
| `sortLevel` by name (`localizedStandardCompare`) | 1.19 / 1.11 µs | 1.48 / 1.37 µs | **0.80× / 0.81×** |

**The mechanism is missing bytes, not Objective-C dispatch.** `pathHasNothingToNormalize` sends
no messages and allocates nothing — it is a `for byte in path.utf8` loop — and it still pays 7.5×.
So the string genuinely has no contiguous UTF-8 to iterate, and every consumer that reaches for
bytes pays to materialize them. That is also why building a dictionary (mostly hashing, almost no
comparison) is nearly as expensive as querying one: it is the **hash** that is slow, because
Swift's cheap path for hashing a string wants exactly the contiguous ASCII buffer a bridged string
does not have.

**And why the last row goes the other way.** `localizedStandardCompare` is an `NSString` method.
A bridged string already *is* an `NSString` and hands itself over for free; a native one has to be
bridged out for every comparison. Nativizing names makes the pane's name sort ~20% **slower** —
about +11 ms per 40,000-node pane. This is the one measurement that decides the shape of the fix,
and it is the one a microbenchmark of dictionary lookups alone would never have found.

---

## Which consumers actually pay it

**They pay on `id`, essentially not at all on `name`.** Every dictionary and set in the app is
keyed on the path; none is keyed on the leaf name. Whole-tree phases, on a real built tree:

| phase | when | as-is | native `id` | saved |
|---|---|---|---|---|
| `FileDiffEngine.filesInfo(fromTree:)` | every scan | 181 / 227 ms | 81 / 96 ms | **−101 / −131 ms** |
| `PaneChildrenIndex` build | every publish, main actor | 35 / 51 ms | 5 / 6 ms | **−30 / −44 ms** |
| `PaneRow.project` | every publish | 6.5 / 7.1 ms | 4.9 / 5.5 ms | −1.6 / −1.6 ms |
| `sort(by: .name)` re-sort | sort-option change | 9.2 / 9.8 ms | 8.2 / 8.4 ms | −1.0 / −1.4 ms |

`filesInfo` saves more than its key derivation alone can account for, because
`URL(fileURLWithPath: node.id, isDirectory:)` — one per node — also gets cheaper when the path is
native.

Per render, `FileRowView` does roughly four path-keyed operations per visible row
(`DiffStatusIndex.status`, `containedDiffCount`, `selection.contains`, the ignore check). At
~4.6 µs saved per lookup and ~120 visible rows across two panes, a pass that rebuilds every row
is worth about 2 ms — which is why this is felt as scrolling and not only as load time.

**Two consumers that look like they should pay and do not**, both worth knowing before "fixing"
them:

- **`ProviderNameRules`' byte-level fast path is safe.** `hasNothingToNormalize` iterating
  `name.utf8` is exactly the shape that suffers, and in isolation it does (7.5×). But all four
  production `nearNameKey` call sites in `FileDiffEngine` pass keys taken from `leftFilesInfo` /
  `rightFilesInfo`, and both the warm (`filesInfo`) and cold (`getFilesInDirectory`) branches mint
  those keys with `String(decoding:)` — which is native. The fast path added in `f6ba96e7` is
  delivering what it appears to. It only meets a bridged string via `NameNormalizer.risky`, from
  the row badge, which is memoized.
- **`FileIconCache` would get *worse*.** It keys on `(name as NSString).pathExtension.lowercased()`
  — native either way — and a bridged name is what makes that `as NSString` free.

---

## What nativizing would cost the walk

The walk is at the floor of directory enumeration (`5b920041`→`77510719`), so anything added there
is added to the number that decides how long "show me this folder" takes. Measured as a whole-tree
transform against a control that rebuilds every node *without* the round-trip, so this is the price
of nativizing and not the price of building a tree:

| | Documents | OneDrive |
|---|---|---|
| `buildTree`, warm | 394.7 ms | 423.1 ms |
| surcharge, `id` only | **+11.0 ms** (2.8%) | **+13.4 ms** (3.2%) |
| surcharge, `id` + `name` | +16.8 ms | +19.7 ms |
| plus the name sort getting slower | +11.0 ms | +10.4 ms |

---

## The ledger, and the recommendation

Per pane, one load plus one scan:

| | Documents | OneDrive |
|---|---|---|
| **nativize `id`** | **−122 ms** | **−165 ms** |
| additionally nativize `name` | +18 ms *worse* | +16 ms *worse* |

**Nativize `id` at construction. Leave `name` bridged.** (Landed — see the outcome below.) Roughly ten times more comes back than
goes in, the walk gives up under 3.5%, and the one place bridging is an advantage — the name sort
— is untouched because it reads `name`.

Forcing native storage is `String(decoding: Array(s.utf8), as: UTF8.self)`. That is
**byte-identical** by construction: `String.utf8` is valid UTF-8 and decoding valid UTF-8 restores
the same scalars, so equality, ordering, hashing, `hasPrefix`, and every byte-level scan in the app
see exactly what they saw before. Do **not** reach for
`String(cString: url.fileSystemRepresentation)` as a cheaper source — it is not obviously
normalization-identical to `URL.path`, and a silent NFC/NFD change to a diff key is precisely the
class of bug `nearNameKey` exists to paper over.

The three sites are `leafNode`, `cappedNode` and `folderNode` in
`Modules/Sync/Sources/Sync/FileSyncManager+Scanning.swift` — deliberately the only places a
production `FileNode` is built.

---

## Outcome — what landing it actually did

Done, via `FileSyncManager.nativePath`. Same machine (97–98% idle), same roots, same benchmark,
before and after:

| phase | Documents | OneDrive |
|---|---|---|
| `FileDiffEngine.filesInfo(fromTree:)` | 181.4 → 78.8 ms | 227.2 → 93.0 ms |
| `PaneChildrenIndex` build | 34.9 → 5.3 ms | 50.7 → 6.3 ms |
| `PaneRow.project` | 6.5 → 4.7 ms | 7.1 → 5.0 ms |
| `sort(by: .name)` re-sort | 9.2 → 8.3 ms | 9.8 → 9.2 ms |
| **total, one load + one scan** | **−135 ms** | **−181 ms** |

**The walk surcharge could not be seen end to end, and that is the honest reading.** `buildTree`
went 394.7 → 383.9 ms and 423.1 → 401.7 ms — *down*, with the before and after sample ranges
overlapping. The predicted +11.0 / +13.4 ms is real but smaller than a warm walk's own run-to-run
spread, so a whole-walk timing can neither confirm nor refute it; the isolated transform
measurement is the number to quote, and the point stands that it is bought back roughly twelve
times over.

The benchmark doubles as the check that the change took effect: its `native id` arm nativizes an
already-native `id`, so every ratio that was 6.5–9.1× collapsed to 1.00–1.04×.

Behaviour-preservation was verified against the pre-change Release binary on a controlled fixture
of adversarial names — NFC vs NFD, trailing space, trailing period, case-only, zero-width, non-BMP,
a 180-character name, a 12-deep chain, an empty directory, a `chmod 000` directory, and both a
valid and a broken symlink:

- a dump of every walked node (`id` and `name` as raw UTF-8 hex, plus `isDirectory`,
  `isUnexplored`, `isSymbolicLink`, size, kind, tags and child count) in tree order under **all
  five sort options**, together with every `filesInfo` key, its `FileInfo.url.path`, and both
  `nearNameKey` folds — 650 lines, **byte-for-byte identical**;
- `synccloud scan` plain, `--show-hidden` and `--json` — stdout, stderr and exit codes identical;
- a real `synccloud sync --direction to-right --strategy keep-both` — identical output, and the
  resulting file trees identical across 92 entries by raw-byte path, size and SHA-256.

`swift test -c release` in `Modules/Sync` 1180/1180, `Modules/FileExplorer` 672/672, and
`xcodebuild test -scheme SyncCloud` 270/270.
