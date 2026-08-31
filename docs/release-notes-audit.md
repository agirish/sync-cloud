# Writing the release notes, and auditing every claim in them

<!-- Split out of CLAUDE.md on 2026-08-30 to keep that file to standing rules. -->

> **Read this during every release cut** — `CLAUDE.md` → **Cutting a release** → **Cutting it**
> step 1 requires it, and the audit is the step most easily skipped because nothing fails when it
> is.
>
> **This doc lives on `main` only**, unlike `docs/flaky-tests.md` and `docs/backports.md`, which are
> carried on all four lines. A cut on a maintenance line has to read it from `main`. Carry it onto
> the other lines if a maintenance release is ever cut again.

**The notes are part of the release too** — v2.9 reached the point of being tagged with none, because
nothing here said to write them. They live in two places:

- `RELEASE_NOTES.md` — `main` is the superset. **The test is whether a section is addressed to that
  line's reader, not whether the files match byte for byte**, so `cmp` is not the check and a section
  `main` has that a maintenance line lacks is not a finding. Baseline (2026-08-17, all correct):
  `v2.x` and `v3.x` are byte-identical and agree with `main` from `## v3.0` down; `main` adds `v4.0`
  onward plus four bullets retrofitted into `## v3.1` (`27fa9c14`).
- `docs/releases.html` — **`main` only.** Pages serves `docs/` from `main`. Add the new article ahead
  of the last one.

**The badge flips at the cut, not when the notes are written.** Pages goes live the moment the notes
land, so an article carrying `latest` announces a release nobody can install — v4.2 shipped that way
and had to be fixed on a live site. A draft lands as `<article class="rel draft">` with
`<span class="tag draft">In development</span>`, the previous release **keeps** `latest`, and the
footer reads `Changes so far: <tag>...main` (the compare link cannot name a tag that does not exist).
`RELEASE_NOTES.md` gets `## <version> — DRAFT, not released` plus a blockquote. `586333f8` is the
v4.1 cut that did it right; these flip in step 1 of **Cutting it**.

**That is not a checklist of everything to flip — a draft says "not released" in prose too, and
prose has no markup to enumerate.** The v4.3 draft carried an HTML comment and a `<b>Not released
yet</b>` clause opening the lede — the first sentence a reader sees — and both survived a flip that
moved every marker correctly. Neither was reachable from a markup checklist because neither existed
when it was written, and the next draft will invent its own. **So grep for the words, before you
commit:**

```sh
grep -in 'draft\|not released\|still to come\|changes so far\|in development' \
     RELEASE_NOTES.md docs/releases.html
```

It never comes back empty — read it, do not count it. At the v4.5 cut the survivors were the three
`.rel.draft` CSS rules (the next draft needs them) and one v4.1 bullet using "draft" about a rule the
editor is composing. **A hit inside the release being cut is the finding; every other hit must be
named.**

**A "Still to come in <version>" section cannot survive the cut it was written ahead of.** What is
missing at the tag is a limitation, not a promise: rename it to `### Known limitations`, and reword
the HTML `<p class="known">` to "**Not in vX.Y.**".

**Then audit every claim against the previous tag** — one command per claim, did this exist at the
last tag?

```sh
git grep -l "<symbol>" v4.4 -- Modules SyncCloudCLI MacApp | grep "/Sources/"
```

- **Audit the section before its bullets.** A feature that arrives inside the range has no prior
  behaviour to be better than, so every "used to / was doing" clause in it is false by construction.
  Five of eleven v4.1 tab bullets carried one. Delete them in one pass.
- **Cut the self-inflicted** — introduced *and* fixed inside the range, so no user of the previous
  release was ever exposed. Five of v2.9's eighteen.
- **A commit whose subject is about coverage is not a user-facing fix.** One v2.9 entry credited a
  behaviour the release already had; the commit had added a *test*.
- **A new file does not mean a new bug.** Two v2.9 claims survived a `git blame` challenge because
  the code was refactored in-range while the behaviour predated it. That direction matters as much.
- **A number that lives in prose rather than test output has not been checked.** Both figures in
  v4.1's pane-bullet were wrong; chasing one turned up `ScaledFont.nsFont(scale:)` silently dropping
  `.rounded` (`97154a32`). Treat a number you cannot reproduce as a finding, not a rounding
  difference — and prefer printing the measurement ("about 37 ms a pass, now about 2 ms") over
  describing it ("an order of magnitude"), because only the first is checkable by the next reader.
- **A number in a TEST's doc comment is still prose, and can go stale inside one release.** v4.5 said
  "twenty-six glyph-only buttons" on the authority of the scan that produced it — and a later commit
  in the same range named two more. Count the net against the tag:
  `git diff v4.4..HEAD -- 'Modules/*/Sources/*' 'MacApp/*' | grep -c '^+ *\.accessibilityLabel('`.
- **A quoted UI string is a claim.** v4.5 told readers a feature was "still available as *Mentions
  all of*"; the label is "Mentions the words". One `git grep` on every quoted label — a reader takes
  it into the app and looks for it.
- **A sentence about how the code is *structured* needs the same grep as one about what it does.**
  Two v4.1 claims asserted the opposite of the code, from intent. Publishing that a drift hazard is
  structurally prevented, when only two copies currently agreeing prevent it, is worse than silence.

Two tells. **"again"** in a claim ("fits on a small display *again*") usually means the release broke
it in the first place. And a **short list after a large range is the honest outcome**, not a failure
of the notes — v2.9's headline became its test volume, the one superlative that survived checking.
