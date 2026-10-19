# SyncCloud — releasing

Read before any release cut, version bump, or new maintenance line. The branch table with each
line's live marker is in [`CLAUDE.md`](CLAUDE.md) §1.

**A cut is never automatic.** Build the whole cut locally, then ask him once before anything reaches
`origin` (step 3 of §4). The one ask covers the whole cut.

---

## 1. Rules

- The version bump and the release notes are part of the release.
- Tags have two components — `v2.9`, never `v2.9.0` — and are used only for releases. This prints
  nothing:
  ```sh
  git tag | grep -v '^v[0-9]*\.[0-9]*$'
  ```
- A release is a tag on the line that owns it — `v2.9` from `v2.x`, `v6.0` from `main`. Tags are never
  branched from, except to cut a new maintenance line (§5).

---

## 2. The version

`project.yml` is the source of truth:

```yaml
CFBundleShortVersionString: "<MAJOR>.<MINOR>-dev"   # marketing version
CFBundleVersion: "<MAJOR × 100 + MINOR>"            # build number
```

- `MacApp/Info.plist` is generated from it by `xcodegen` and tracked in git — regenerate and commit
  both.
- Only display code reads the version — the Settings rail
  (`Modules/Settings/Sources/Settings/SettingsLayout.swift`) and the launch line in
  `~/sync-cloud.log` (`MacApp/SyncCloudApp.swift`) — so changing it is safe.
- **Three copies move with it, in the same commit:** `MacApp/Info.plist`; the `versionMarker`
  literal in `Modules/Settings/Tests/Settings/SettingsLayoutTests.swift`; the branch table in
  `CLAUDE.md`.

Check the table against `project.yml` from the repo root — this prints nothing when they match:

```sh
# main is read from the working tree (the copy you are about to land); maintenance lines from origin.
# Do not read main from origin too: that reports clean throughout a local bump.
for l in main v5.x v4.x v3.x v2.x; do
  if [ "$l" = main ]; then m=$(grep -o '"[0-9.]*-dev"' project.yml | tr -d '"')
  else m=$(git show origin/$l:project.yml | grep -o '"[0-9.]*-dev"' | tr -d '"'); fi
  r=$(grep "^| \`$l\`" CLAUDE.md | grep -o '`[0-9.]*-dev`' | tr -d '`')
  [ "$m" = "$r" ] || echo "$l: table says $r, project.yml says $m"
done
```

**Marketing version.** Between releases each tip carries `<next version>-dev`. A release drops the
suffix; the tip is re-bumped straight after, so a plain number like `2.9` appears only on the tagged
commit. A non-numeric string is fine: SyncCloud is distributed
directly, not through the App Store, and Launch Services orders builds by `CFBundleVersion`.

**Build number.** `CFBundleVersion` = MAJOR × 100 + MINOR (`2.9` → `209`, `2.10` → `210`, `3.0` →
`300`). It changes in the same edit as the marker; the `-dev` build shares it with the release it
becomes. Keep MINOR under 100 (ordering) and MAJOR under 100 (the rail's width budget, §6).

---

## 3. The notes

- They live in `RELEASE_NOTES.md` (`main` carries the superset) and `docs/releases.html` (`main`
  only — Pages serves `docs/` from `main` and publishes on push).
- **Until the cut, notes are a draft:** the article is `<article class="rel draft">`, the previous
  release keeps `latest`, and `RELEASE_NOTES.md` has `## <version> — DRAFT, not released`.
- **Audit every claim against the previous tag, one command per claim**, with
  [`docs/release-notes-audit.md`](docs/release-notes-audit.md) (§4 step 1).

---

## 4. Cutting it

Work in a worktree ([`COMMIT.md`](COMMIT.md)). The examples cut `v2.9` from `v2.x`.

1. **Drop the suffix and publish the notes, in one commit.**
   - `project.yml`: `2.9-dev` → `2.9`; `CFBundleVersion` is already `209`.
   - `RELEASE_NOTES.md`: remove the DRAFT heading and blockquote.
   - `docs/releases.html`: remove `class="rel draft"`; the tag `draft` / "In development" becomes
     `latest`; the previous release swaps `latest` for a theme tag; the footer changes from
     `Changes so far: <prev>...main` to `Full changelog: <prev>...<new>`.
   - Before committing, work through [`docs/release-notes-audit.md`](docs/release-notes-audit.md):
     convert "Still to come", run the draft-word grep (the markup list is not the whole set), and
     audit every claim.

2. **Regenerate and update the marker.** Run `xcodegen`; set `versionMarker` in
   `SettingsLayoutTests.swift` to the same string; run the table check (§2).

3. **Commit, ask, land on the line, and wait for CI to pass on that SHA.**
   - Stay off the machine while CI runs — the runner is this Mac, and load causes flakes.
   - Before rerunning a red, check `uptime` and
     `gh api repos/agirish/sync-cloud/actions/runners --jq '.runners[].busy'`. Budget a rerun into
     the cut. Failing suites that pass in under a second locally at the same SHA (against a ~12 s
     timeout on CI) are load, not code.
   - Check that the folder survey's ground truth ran — `FolderSurveyGroundTruthGateTests` prints the
     verdict, and a `SKIPPED` line names the gate that closed it:
     ```sh
     gh run view <run-id> --log | grep '\[ground-truth\]'   # want: RAN — …
     ```
     On CI it always reads `SKIPPED` (`liveProfile is in SYNCCLOUD_SKIP_MACHINE_PINNED`). To get a
     RAN, run `FolderSurveyGroundTruthTests` locally with the display woken and held:
     `nohup caffeinate -u -t 1200 &`, run the suite, then `pkill` the hold (`caffeinate -u <cmd>` or a
     short `-t` is not enough). A SKIPPED does not block the cut.

4. **Tag that commit, push the tag, then create the release with an explicit `--target`:**
   ```sh
   git tag v2.9 <sha> && git push origin v2.9
   gh release create v2.9 --target v2.x \
     --title "v2.9 — <the lede, shortened>" --notes-file <body> --latest
   ```
   Without `--target`, the release records `main` as its target. To fix that after publishing:
   ```sh
   RID=$(gh release view v2.9 --json databaseId --jq .databaseId)
   gh api --method PATCH repos/agirish/sync-cloud/releases/$RID -f target_commitish=v2.x
   ```
   Then confirm the tag did not move:
   `gh api repos/agirish/sync-cloud/git/refs/tags/v2.9 --jq .object.sha` is unchanged and
   `git branch -r --contains <sha>` names only `origin/v2.x`. Leave v2.8's target as `main`; it is
   correct.

5. **Re-bump the tip immediately, in its own commit** — `v2.x` becomes `2.10-dev` / `210`:
   `project.yml`, `xcodegen`, the test marker and the `CLAUDE.md` table.

6. **Install and confirm.** Run the `install-sync-cloud` skill; the first line of
   `~/sync-cloud.log` must name the new version.

---

## 5. Cutting a new maintenance line

When the next major opens on `main`, cut the shipped major's line from its last tag. In the commit
that creates the branch:

- add its row to the branch table in `CLAUDE.md`;
- add it to `branches:` in `.github/workflows/tests.yml`;
- re-bump its tip to the next marker (§4 step 5);
- add it to the table check's line list (§2) and the `git ls-remote` expectation in `CLAUDE.md` §1.

Pushing the new branch is a push to a maintenance line, so it needs his yes (`CLAUDE.md` §4).

---

## 6. The version line has a width budget

- The Settings rail is fixed-width (176 pt) and does not scroll; its version line has no `lineLimit`,
  so a long version wraps and pushes the Large text size past its opening.
- **The ceiling is 19 characters including `SyncCloud `.** The column is 142 pt:
  `SyncCloud 10.10-dev` measures 136 pt; `SyncCloud 100.10-dev` measures 145 pt and wraps. The
  per-size table is in the test's doc comment.
- Tests lay the line out through `SettingsRail.versionText` with `versionMarker`, because
  `Bundle.main` under `swift test` has no version. Keep `versionMarker` equal to `project.yml`.
- `theVersionLineFitsTheRailOnOneLine` fails if a version is too long. Do not widen the rail without
  re-measuring the tabs that share its opening.
