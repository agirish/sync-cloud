import Foundation
import Testing
@testable import Sync

/// The rename pass's rules, against names taken from the real tree.
///
/// Every fixture here is a name that exists (or existed) in the surveyed `~/Documents`, because the
/// rules were derived from it and a synthetic name proves only that the code does what it does. The
/// two that matter most are the ones that must produce **nothing**: a `descriptive` folder, and a
/// raw original sitting beside its already-renamed copy.
@Suite struct RenamePlannerTests {

    // MARK: Helpers

    private func files(_ names: [String], in folder: String = "/T") -> [FolderFile] {
        names.map { FolderFile(path: folder + "/" + $0, name: $0) }
    }

    private func entry(_ path: String, naming: String?, axes: [String: String] = [:]) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: .yearBucket, naming: naming, anchors: [],
                           acceptsNewFiles: true, fileCount: 0, subfolderCount: 0, axes: axes)
    }

    private func plan(_ names: [String], naming: String? = "ordinal-month",
                      year: String? = nil, incoming: String? = nil,
                      relativePath: String = "T") -> RenamePlan {
        var axes: [String: String] = [:]
        if let year { axes["year"] = year }
        return RenamePlanner.plan(
            folderPath: "/T", relativePath: relativePath, files: files(names),
            entry: entry(relativePath, naming: naming, axes: axes),
            incoming: incoming.map { FolderFile(path: "/In/" + $0, name: $0) })
    }

    private func targets(_ p: RenamePlan) -> [String: String] {
        Dictionary(uniqueKeysWithValues: p.steps.map { ($0.currentName, $0.proposedName) })
    }

    // MARK: The grammar

    @Test("A one-digit ordinal parses, and reports the width that makes it wrong")
    func parsesOneDigitOrdinal() throws {
        let p = try #require(OrdinalMonthName.parse("4. Apr 2025.pdf"))
        #expect(p.ordinal == 4)
        #expect(p.ordinalDigits == 1)
        #expect(p.month == 4)
        #expect(p.year == 2025)
        #expect(p.isCanonical == false)
        // The discriminating half: the same name at two digits is canonical, so `isCanonical` is
        // answering about the WIDTH and not merely returning false for everything.
        #expect(OrdinalMonthName.parse("04. Apr 2025.pdf")?.isCanonical == true)
    }

    @Test("A three-digit leader is not an ordinal")
    func refusesThreeDigits() {
        // `077. Jul 2020.pdf` is really in the tree. Reading it as ordinal 7 would let the pass
        // "fix" a name whose actual problem it cannot see.
        #expect(OrdinalMonthName.parse("077. Jul 2020.pdf") == nil)
        #expect(OrdinalMonthName.parse("07. Jul 2020.pdf") != nil)
    }

    @Test("A missing space after the dot still parses, and is tidied")
    func parsesMissingSpace() throws {
        let p = try #require(OrdinalMonthName.parse("10.Oct 2011.pdf"))
        #expect(p.ordinal == 10 && p.month == 10 && p.isCanonical == false)
        #expect(OrdinalMonthName.render(ordinal: 10, month: 10, year: 2011, ext: "pdf")
                == "10. Oct 2011.pdf")
    }

    @Test("The summary slot is identified by its number, never by its wording")
    func summarySlotByNumber() throws {
        for name in ["0. Summary 2022.pdf", "0. 2022 Summary.pdf", "0. Spend 2019.pdf",
                     "00. 2014-2015 (1).pdf"] {
            let p = try #require(OrdinalMonthName.parse(name), "\(name)")
            #expect(p.isSummarySlot, "\(name)")
        }
        #expect(OrdinalMonthName.parse("01. Jan 2022.pdf")?.isSummarySlot == false)
    }

    // MARK: Mining a date out of a raw name

    @Test("Real provider names give up their month and year")
    func minesRealNames() throws {
        let cases: [(String, Int, Int)] = [
            ("9829custbill07182023.pdf", 7, 2023),                       // MMDDYYYY
            ("20240128-statements-8857-.pdf", 1, 2024),                  // YYYYMMDD
            ("STMTCMB100_20201101_5203_Girish_1154171_239175.PDF", 11, 2020),
            ("Statement12312020-5.pdf", 12, 2020),
            ("ATTBill_1897_Feb2022.pdf", 2, 2022),                       // glued MonYYYY
            ("DetailedBillApr2025.pdf", 4, 2025),                        // no separator at all
            // Two month tokens naming the SAME month is not a range.
            ("ABHISHEK GIRISH 01 FEB 2020 TO  29 FEB 2020.pdf", 2, 2020),
        ]
        for (name, month, year) in cases {
            let m = try #require(FileNameDate.mine(name), "\(name)")
            #expect(m.month == month, "\(name)")
            #expect(m.year == year, "\(name)")
        }
    }

    @Test("Names that do not name one month are refused")
    func refusesNonMonthlyNames() {
        for name in [
            "Jan-Dec 2019.pdf",                                  // range across months
            "Apr 2009 - Mar 2010.pdf",                           // fiscal span: two months, two years
            "ABHISHEK GIRISH 01 JUL 2020 TO  30 SEP 2020.pdf",   // range Jul→Sep
            "Year End Summary 2016.pdf",                         // a year, no month
            "2016 Summary.pdf",
            "2013-2014.pdf",                                     // two years, no month
            "Interest Certificate.pdf",                          // no date at all
            "Tags.pdf",
            "8666160540530062020.pdf",                           // 19-digit account reference
            "16106593108981703151004183789428.pdf",              // export id
            // A datestamp with a time glued onto it. The leading eight digits read perfectly as
            // 2020-11-01, which is exactly why the rule demands the WHOLE delimited run be eight
            // long: a twelve-digit run is not a date, and loosening this to "at least eight" is a
            // mutation the two names above cannot catch (neither of them parses either way).
            "STMTCMB100_202011011530_5203.PDF",
            "09a6d2b6-78e6-4f3a-83e0-ea1ac09ff81a.pdf",          // UUID
        ] {
            #expect(FileNameDate.mine(name) == nil, "\(name) should not yield a month")
        }
    }

    @Test("An eight-digit run reads one way or not at all")
    func datestampIsUnambiguous() {
        // YYYYMMDD needs 19/20/21 up front; MMDDYYYY needs 01–12. Disjoint, so no name has two
        // readings — and a DDMMYYYY name matches neither rather than being guessed at.
        #expect(FileNameDate.mine("x20200105y.pdf").map { ($0.month, $0.year) } ?? (0, 0) == (1, 2020))
        #expect(FileNameDate.mine("x01052020y.pdf").map { ($0.month, $0.year) } ?? (0, 0) == (1, 2020))
        #expect(FileNameDate.mine("x18072023y.pdf") == nil)   // DDMMYYYY: refused
    }

    // MARK: The gate — which folders the pass may touch at all

    @Test("A descriptive folder is never touched, however date-like its files look")
    func leavesDescriptiveFoldersAlone() {
        let p = plan(["ATTBill_1897_Jan2022.pdf", "ATTBill_1897_Feb2022.pdf",
                      "DetailedBillApr2025.pdf"], naming: "descriptive")
        #expect(p.steps.isEmpty)
        #expect(p.skips.isEmpty)
        // Non-vacuity: the exact same files in an ordinal-month folder DO produce proposals, so the
        // emptiness above is the gate and not the miner failing.
        #expect(plan(["ATTBill_1897_Jan2022.pdf", "ATTBill_1897_Feb2022.pdf",
                      "DetailedBillApr2025.pdf"], naming: "ordinal-month").steps.count == 3)
    }

    @Test("An inbox is never renamed in — its names are still routing files")
    func neverRenamesInsideAStagingArea() {
        let files = ["1. Jan 2021.pdf", "2. Feb 2021.pdf", "ATTBill_1897_Mar2021.pdf"]
        // Marked an inbox by the profile…
        let byRole = RenamePlanner.plan(
            folderPath: "/root/Staging", relativePath: "Staging",
            files: files.map { FolderFile(path: "/root/Staging/" + $0, name: $0) },
            entry: FolderProfileEntry(path: "Staging", role: .inbox, naming: "ordinal-month",
                                      anchors: [], acceptsNewFiles: false, fileCount: 3,
                                      subfolderCount: 0, axes: ["year": "2021"]))
        #expect(byRole.steps.isEmpty)
        // …and by its NAME alone, which is the case the profile's flags lag behind.
        let byName = plan(files, year: "2021", relativePath: "Home/TODO")
        #expect(byName.steps.isEmpty)
        let byNameNested = plan(files, year: "2021", relativePath: "Home/EDD - TODO/2021")
        #expect(byNameNested.steps.isEmpty)

        // Non-vacuity, and the reason this matters: the very same files in an ordinary folder ARE
        // renamed — including the AT&T bill, whose `attbill` token is what routes it. Renaming it
        // where it still needs routing would send it nowhere.
        let ordinary = plan(files, year: "2021")
        #expect(ordinary.steps.count == 3)
        #expect(FilingEngine.salientTokens(ofFileNamed: "ATTBill_1897_Mar2021.pdf").contains("attbill"))
        #expect(!FilingEngine.salientTokens(ofFileNamed: "03. Mar 2021.pdf").contains("attbill"))
    }

    @Test("A folder merely named like a document is not a staging area")
    func doesNotMistakeOrdinaryFoldersForInboxes() {
        // `isInboxPath` matches whole words inside a component, so a folder called `Mastodon` — or
        // `Todoist` — is not an inbox. Borrowing that rule rather than a `contains("todo")` is what
        // keeps this from switching the pass off for real folders.
        #expect(!RenamePlanner.isStagingArea("Home/Mastodon/2021", entry: nil))
        #expect(!RenamePlanner.isStagingArea("Home/Todoist/2021", entry: nil))
        #expect(RenamePlanner.isStagingArea("Home/New (TODO)/2021", entry: nil))
    }

    @Test("An unsurveyed folder needs three conforming files before it is recruited")
    func inferenceNeedsThree() {
        #expect(RenamePlanner.slotGranularity(
            files: files(["1. Jan 2020.pdf", "Lease.pdf", "Notes.pdf"]), entry: nil) == nil)
        #expect(RenamePlanner.slotGranularity(
            files: files(["1. Jan 2020.pdf", "2. Feb 2020.pdf", "3. Mar 2020.pdf"]),
            entry: nil) == .month)
    }

    // MARK: Padding — the bulk of the backlog

    @Test("One-digit ordinals are padded, and the number never moves")
    func padsWithoutRenumbering() {
        let p = plan(["1. Mar 2021.pdf", "2. Apr 2021.pdf", "10. Dec 2021.pdf"], year: "2021")
        #expect(targets(p) == ["1. Mar 2021.pdf": "01. Mar 2021.pdf",
                               "2. Apr 2021.pdf": "02. Apr 2021.pdf"])
        // `10.` was already two digits and is left completely alone — the pass proposes the minimum.
        #expect(p.steps.allSatisfy { $0.kind == .tidied })
    }

    @Test("Padding preserves everything the body says beyond the date")
    func padsWithoutDroppingTheBody() {
        // `Savings NRI/2014` really holds two June statements, one per account. Rendering the name
        // from the parsed month and year alone would call both `01. Jun 2014.pdf` — deleting the one
        // word that tells them apart, and colliding into the bargain.
        let p = plan(["1. Jun 2014 NRE.pdf", "1. Jun 2014 NRO.pdf", "2. Jul 2014.pdf"], year: "2014")
        #expect(targets(p) == ["1. Jun 2014 NRE.pdf": "01. Jun 2014 NRE.pdf",
                               "1. Jun 2014 NRO.pdf": "01. Jun 2014 NRO.pdf",
                               "2. Jul 2014.pdf": "02. Jul 2014.pdf"])
        #expect(p.skips.isEmpty)
    }

    @Test("A month spelled out IS respelled, when that is the whole body")
    func respellsABareDate() {
        // The other half of the rule above: `07. July 2016.pdf` has nothing in its body but the
        // date, so the month is safe to abbreviate. Without this, "preserve the body" would mean
        // never normalising anything.
        let p = plan(["07. July 2016.pdf", "08. Aug 2016.pdf", "09. Sep 2016.pdf"], year: "2016")
        #expect(targets(p) == ["07. July 2016.pdf": "07. Jul 2016.pdf"])
    }

    @Test("A duplicate marker is left alone, not renamed onto the original")
    func leavesDuplicateMarkersAlone() {
        // 682 files in the tree carry one. Deciding a `-2` is the same document as its original
        // needs a content fingerprint this app does not have yet, so the pass must not quietly
        // strip the marker — which is what rendering from the parsed date would do.
        let p = plan(["11. Nov 2014.pdf", "11. Nov 2014 -2.pdf", "12. Dec 2014.pdf"], year: "2014")
        #expect(p.steps.isEmpty)
        #expect(p.skips.isEmpty)
    }

    @Test("A summary slot is padded but keeps its own wording")
    func padsSummarySlot() {
        let p = plan(["0. Summary 2022.pdf", "01. Jan 2022.pdf", "02. Feb 2022.pdf"], year: "2022")
        #expect(targets(p) == ["0. Summary 2022.pdf": "00. Summary 2022.pdf"])
    }

    // MARK: Placement

    @Test("A raw bill takes the next slot in a position-numbered folder")
    func placesIntoPositionFolder() {
        // HDFC Credit/2010's real shape: Apr=01, Jul=02, Sep=03 — position, not month number.
        let p = plan(["01. Apr 2010.pdf", "02. Jul 2010.pdf", "03. Sep 2010.pdf",
                      "9829custbill10182010.pdf"], year: "2010")
        #expect(p.scheme == .position)
        #expect(targets(p) == ["9829custbill10182010.pdf": "04. Oct 2010.pdf"])
    }

    @Test("A raw bill takes its month's slot in a month-numbered folder")
    func placesIntoMonthNumberFolder() {
        // PG&E/2021's real shape: Mar=03 … Nov=11, with slots 1 and 2 standing empty.
        let p = plan(["03. Mar 2021.pdf", "04. Apr 2021.pdf", "05. May 2021.pdf",
                      "9829custbill12182021.pdf"], year: "2021")
        #expect(p.scheme == .monthNumber)
        #expect(targets(p) == ["9829custbill12182021.pdf": "12. Dec 2021.pdf"])
        // The discriminating half: the very same files under a folder whose names vouch for
        // POSITION put December at slot 04, not 12. So this test reads the scheme rather than
        // counting files.
        let positional = plan(["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf",
                               "9829custbill12182021.pdf"], year: "2021")
        #expect(positional.scheme == .position)
        #expect(targets(positional) == ["9829custbill12182021.pdf": "04. Dec 2021.pdf"])
    }

    @Test("Numbering is per extension — a csv/pdf pair shares one slot")
    func numbersPerExtension() throws {
        // Apple Card/2022 holds both for every month. All twenty-four ordinals "duplicate", and all
        // twenty-four are correct — nothing to propose.
        let settled = plan(["01. Jan 2022.csv", "01. Jan 2022.pdf",
                            "02. Feb 2022.csv", "02. Feb 2022.pdf",
                            "03. Mar 2022.csv", "03. Mar 2022.pdf"], year: "2022")
        #expect(settled.steps.isEmpty)
        #expect(settled.skips.isEmpty)

        // That folder is silent whether or not the planner partitions by extension, so it cannot on
        // its own show that it does. A raw csv arriving into a GAPPED folder of pairs can. Apr and
        // Jul are slots 01 and 02 — position numbering, as `HDFC Credit/2010` really is — so the
        // September csv is the third csv and takes slot 03. Ranked against all four files instead it
        // would take slot 05, and disagree with the pdf it belongs beside.
        let p = plan(["01. Apr 2010.csv", "01. Apr 2010.pdf",
                      "02. Jul 2010.csv", "02. Jul 2010.pdf",
                      "activity20100901.csv"], year: "2010")
        #expect(p.scheme == .position)
        #expect(targets(p) == ["activity20100901.csv": "03. Sep 2010.csv"])
    }

    // MARK: The traps

    @Test("A raw original beside its renamed copy is skipped, never renamed onto it")
    func refusesToCollideWithTheRenamedCopy() throws {
        // The exact pair the roadmap measured: same bill, same folder, one renamed and one not.
        let p = plan(["07. Jul 2023.pdf", "9829custbill07182023.pdf"], year: "2023")
        #expect(p.steps.isEmpty)
        let skip = try #require(p.skips.first)
        #expect(skip.fileName == "9829custbill07182023.pdf")
        #expect(skip.reason.contains("07. Jul 2023.pdf"))
    }

    @Test("Two names canonicalising to one target leave both alone")
    func refusesTwoStepsWantingOneName() {
        let p = plan(["4. Apr 2021.pdf", "04. Apr 2021.pdf", "05. May 2021.pdf"], year: "2021")
        #expect(p.steps.isEmpty)
        #expect(p.skips.count == 1)
        #expect(p.skips.first?.fileName == "4. Apr 2021.pdf")
    }

    @Test("A bill from a year the folder does not own is reported, not renamed")
    func refusesToStampTheWrongYear() throws {
        // PG&E's January 2024 bill filed under 2023/ — the misfiling the survey found. Renaming it
        // `01. Jan 2023.pdf` would bury the evidence under a name that looks right.
        let p = plan(["11. Nov 2023.pdf", "12. Dec 2023.pdf", "9829custbill01182024.pdf"],
                     year: "2023")
        #expect(p.steps.isEmpty)
        let skip = try #require(p.skips.first)
        #expect(skip.reason.contains("Jan 2024"))
        #expect(skip.reason.contains("2023"))
        // Non-vacuity: the same bill in its own year IS placed.
        #expect(plan(["11. Nov 2024.pdf", "12. Dec 2024.pdf", "9829custbill01182024.pdf"],
                     year: "2024").steps.count == 1)
    }

    @Test("An Indian fiscal year owns April through March, and nothing else")
    func fiscalYearWindow() {
        #expect(RenamePlanner.yearFits(2014, month: 4, ownedBy: "2014-2015"))
        #expect(RenamePlanner.yearFits(2015, month: 3, ownedBy: "2014-2015"))
        #expect(!RenamePlanner.yearFits(2014, month: 3, ownedBy: "2014-2015"))  // before it opens
        #expect(!RenamePlanner.yearFits(2015, month: 4, ownedBy: "2014-2015"))  // after it closes
        #expect(!RenamePlanner.yearFits(2016, month: 6, ownedBy: "2014-2015"))
        // A US calendar year owns exactly one year, all twelve months.
        #expect(RenamePlanner.yearFits(2023, month: 1, ownedBy: "2023"))
        #expect(!RenamePlanner.yearFits(2024, month: 1, ownedBy: "2023"))
    }

    // MARK: Cascade renumbering

    @Test("A back-fill shifts every later file up, and arrives at slot 01")
    func backFillCascades() throws {
        // `HDFC Credit/2010`'s shape: position-numbered, and February arrives before March.
        let p = plan(["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf",
                      "9829custbill02182021.pdf"], year: "2021")
        #expect(targets(p) == ["9829custbill02182021.pdf": "01. Feb 2021.pdf",
                               "01. Mar 2021.pdf": "02. Mar 2021.pdf",
                               "02. Apr 2021.pdf": "03. Apr 2021.pdf",
                               "03. May 2021.pdf": "04. May 2021.pdf"])
        #expect(p.placed == 1)
        #expect(p.renumbered == 3)
        #expect(p.skips.isEmpty)
        // All four move together or not at all.
        let cohorts = Set(p.steps.map(\.cohort))
        #expect(cohorts.count == 1)
        #expect(cohorts.first != 0)
    }

    @Test("Appending after everything already there shifts nothing")
    func appendDoesNotCascade() {
        // The ordinary case, and the one the incoming-file path almost always takes. A cascade here
        // would be churn: nothing is in the way.
        let p = plan(["01. Jan 2025.pdf", "02. Feb 2025.pdf", "03. Mar 2025.pdf",
                      "DetailedBillApr2025.pdf"], year: "2025")
        #expect(targets(p) == ["DetailedBillApr2025.pdf": "04. Apr 2025.pdf"])
        #expect(p.renumbered == 0)
        #expect(p.steps.allSatisfy { $0.cohort == 0 })
    }

    @Test("A folder nobody is adding to is never renumbered")
    func noPlacementMeansNoCascade() {
        // `10. Dec 2021.pdf` beside `1. Mar` and `2. Apr` is not a clean 1…N, and a renumbering
        // pass that normalised it would rewrite a number somebody chose by hand for no reason at
        // all. The cascade exists to make ROOM; with nothing arriving there is none to make.
        let p = plan(["1. Mar 2021.pdf", "2. Apr 2021.pdf", "10. Dec 2021.pdf"], year: "2021")
        #expect(targets(p) == ["1. Mar 2021.pdf": "01. Mar 2021.pdf",
                               "2. Apr 2021.pdf": "02. Apr 2021.pdf"])
        #expect(p.renumbered == 0)
    }

    @Test("A month-numbered folder never cascades — its slots do not move")
    func monthNumberedFolderDoesNotCascade() {
        // Under `.monthNumber` the slot IS the month, so an arriving February takes slot 02 and
        // March keeps 03. Renumbering would be actively wrong.
        let p = plan(["03. Mar 2021.pdf", "04. Apr 2021.pdf", "07. Jul 2021.pdf",
                      "9829custbill02182021.pdf"], year: "2021")
        #expect(p.scheme == .monthNumber)
        #expect(targets(p) == ["9829custbill02182021.pdf": "02. Feb 2021.pdf"])
        #expect(p.renumbered == 0)
    }

    @Test("A renumber ranks distinct MONTHS, not files")
    func cascadeRanksByMonthNotFile() throws {
        // `Savings NRI/2014` really holds two June statements sharing slot 1, with July at 2. A
        // cascade that counted FILES would push July to 3 and every later month with it — a
        // corruption dressed up as a fix.
        let p = plan(["1. Jun 2014 NRE.pdf", "1. Jun 2014 NRO.pdf", "2. Jul 2014.pdf",
                      "3. Aug 2014.pdf", "statement20140501.pdf"], year: "2014")
        #expect(targets(p) == ["statement20140501.pdf": "01. May 2014.pdf",
                               "1. Jun 2014 NRE.pdf": "02. Jun 2014 NRE.pdf",
                               "1. Jun 2014 NRO.pdf": "02. Jun 2014 NRO.pdf",
                               "2. Jul 2014.pdf": "03. Jul 2014.pdf",
                               "3. Aug 2014.pdf": "04. Aug 2014.pdf"])
        // Both June statements land on ONE slot, and the suffix that tells them apart survives.
        #expect(p.skips.isEmpty)
    }

    @Test("A renumbering that cannot complete is abandoned whole, not half-applied")
    func aBrokenCascadeStandsDown() throws {
        // `1. Mar` and `01. Mar` both want slot 02 once February arrives — one name, two files. The
        // collision guard refuses them, and with a cascade that has to take the rest of the cohort
        // with it: applying the survivors would leave April on a slot March also claims.
        let p = plan(["1. Mar 2021.pdf", "01. Mar 2021.pdf", "02. Apr 2021.pdf",
                      "9829custbill02182021.pdf"], year: "2021")
        #expect(p.steps.isEmpty, "no step may survive a cascade that cannot be completed")
        #expect(!p.skips.isEmpty)
        #expect(p.skips.contains { $0.reason.contains("renumbering this folder cannot complete") })
    }

    @Test("A renumbering stands down when the folder holds a slot it cannot rank")
    func cascadeRefusesUnrankableSlots() throws {
        // `SBI Savings/2007 - 2008` numbers fiscal-span files — `1. Apr 2007 to Aug 2007.pdf` names
        // two months and so has no single date to sort by. A cascade cannot reason about those, and
        // ranking around them silently put a shifted file on a slot one of them already held: the
        // two NAMES differ, so the collision guard never saw it.
        let p = plan(["1. Feb 2021.pdf", "02. Mar 2021.pdf", "3. Jan 2008 to Mar 2008.pdf",
                      "custbill01182021.pdf"])
        #expect(p.renumbered == 0, "no file may be shifted around a slot the pass cannot rank")
        // The arriving file is reported rather than dropped or appended to the end.
        #expect(p.skips.contains { $0.fileName == "custbill01182021.pdf" })
        // Every widening still stands: refusing the renumbering is a statement about SLOTS, and
        // padding moves none. Withholding it would punish the folder twice.
        #expect(targets(p) == ["3. Jan 2008 to Mar 2008.pdf": "03. Jan 2008 to Mar 2008.pdf",
                               "1. Feb 2021.pdf": "01. Feb 2021.pdf"])
    }

    @Test("A padding fix survives a renumbering that has to stand down")
    func paddingOutlivesADoomedCascade() {
        // `2. Feb` only needs widening — right whether or not the shift around it happens — so it
        // must not be swept into the cohort and lost with it. `1. Mar`/`01. Mar` doom the cascade.
        let p = plan(["1. Mar 2021.pdf", "01. Mar 2021.pdf", "2. Feb 2021.pdf",
                      "9829custbill01182021.pdf"], year: "2021")
        #expect(targets(p) == ["2. Feb 2021.pdf": "02. Feb 2021.pdf"])
        #expect(p.renumbered == 0)
    }

    @Test("Two placements under month numbering cannot claim one slot")
    func monthNumberedPlacementsDoNotShareASlot() {
        // A folder with no year of its own — `HDFC Forex 9055` — can take January of two years in
        // one pass. Read off an immutable `taken`, both would be told slot 01 is free.
        let p = plan(["03. Mar 2020.pdf", "05. May 2020.pdf", "07. Jul 2020.pdf",
                      "bill01152020.pdf", "bill01152021.pdf"])
        #expect(p.scheme == .monthNumber)
        let placed = p.steps.filter { $0.kind == .placed }
        #expect(placed.count == 1, "the second January is reported, not given a slot already used")
        #expect(p.skips.contains { $0.reason.contains("already in use") })
    }

    // MARK: The incoming file — Organize's move suggestion asks the same rules

    @Test("A file being filed in is named against the folder it is landing in")
    func namesAnIncomingFile() {
        let p = plan(["01. Jan 2025.pdf", "02. Feb 2025.pdf", "03. Mar 2025.pdf"],
                     year: "2025", incoming: "DetailedBillApr2025.pdf")
        #expect(targets(p) == ["DetailedBillApr2025.pdf": "04. Apr 2025.pdf"])
    }

    @Test("A file whose slot needs its neighbours moved is not renamed on the way in")
    func incomingNeedingACascadeKeepsItsName() {
        // The plan for this folder is a real four-step cohort: February takes 01 and Mar/Apr/May
        // each move up. Taking the placement out of that cohort and dropping the rest is a
        // half-applied cascade — measured, it left TWO files on slot 01.
        let p = plan(["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf"],
                     year: "2021", incoming: "9829custbill02182021.pdf")
        let step = p.steps.first { $0.currentName == "9829custbill02182021.pdf" }
        #expect(step?.proposedName == "01. Feb 2021.pdf")
        #expect(step?.cohort != 0, "the planner still describes the whole renumbering")
        // …and the manager's one-file door declines it precisely because of that cohort.
        #expect(FileSyncManager.incomingName(
            for: "9829custbill02182021.pdf", into: "/T", relativePath: "T",
            folderFiles: files(["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf"]),
            profile: FolderProfile(profileId: "t", root: "/",
                                   folders: ["T": entry("T", naming: "ordinal-month",
                                                        axes: ["year": "2021"])],
                                   personTokens: [])) == nil)
        // The discriminating half: an APPEND needs no cascade and is still offered.
        #expect(FileSyncManager.incomingName(
            for: "9829custbill06182021.pdf", into: "/T", relativePath: "T",
            folderFiles: files(["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf"]),
            profile: FolderProfile(profileId: "t", root: "/",
                                   folders: ["T": entry("T", naming: "ordinal-month",
                                                        axes: ["year": "2021"])],
                                   personTokens: [])) == "04. Jun 2021.pdf")
    }

    @Test("An incoming file with no date in its name says so, rather than going quiet")
    func reportsAnUndatableIncomingFile() {
        let p = plan(["01. Jan 2025.pdf", "02. Feb 2025.pdf", "03. Mar 2025.pdf"],
                     year: "2025", incoming: "Rewards.pdf")
        #expect(p.steps.isEmpty)
        #expect(p.skips.first?.fileName == "Rewards.pdf")
        // A file ALREADY in the folder with no date is silent — a folder holding
        // `Interest Certificate.pdf` is not a backlog, and reporting it every scan is noise.
        #expect(plan(["01. Jan 2025.pdf", "02. Feb 2025.pdf", "03. Mar 2025.pdf",
                      "Rewards.pdf"], year: "2025").skips.isEmpty)
    }

    // MARK: PG&E — the worked failure case, end to end

    @Test("PG&E 2023, as the survey found it")
    func pgeTwentyTwentyThree() {
        // Jan–Aug renamed two-digit, the rest raw, plus a January 2024 bill filed here.
        let p = plan((1...8).map { String(format: "%02d. %@ 2023.pdf",
                                          $0, OrdinalMonthName.monthAbbreviations[$0 - 1]) }
                     + ["9829custbill09182023.pdf", "9829custbill10182023.pdf",
                        "9829custbill01182024.pdf"],
                     year: "2023")
        // Jan–Aug is contiguous from January, where the two schemes are indistinguishable — so the
        // inference stays on the tree's majority reading, and both give Sep slot 09 regardless.
        #expect(p.scheme == .position)
        #expect(targets(p) == ["9829custbill09182023.pdf": "09. Sep 2023.pdf",
                               "9829custbill10182023.pdf": "10. Oct 2023.pdf"])
        // The 2024 bill is reported as a possible misfiling and is NOT given a 2023 name.
        #expect(p.skips.count == 1)
        #expect(p.skips.first?.fileName == "9829custbill01182024.pdf")
    }

    @Test("PG&E 2022, not renamed at all, is numbered end to end")
    func pgeTwentyTwentyTwo() {
        // The survey's third PG&E shape and the one with no conforming sibling to anchor on:
        // eleven raw bills, nothing else. Every one is mined and placed in date order, which is
        // only possible because placements are ranked against each other rather than against the
        // original file list — ranked against the list, all eleven compute slot 1.
        let raw = (1...11).map { m in String(format: "9829custbill%02d182022.pdf", m) }
        let p = plan(raw, year: "2022")
        #expect(p.steps.count == 11)
        #expect(p.placed == 11)
        #expect(p.skips.isEmpty)
        for m in 1...11 {
            let expected = String(format: "%02d. %@ 2022.pdf", m, OrdinalMonthName.monthAbbreviations[m - 1])
            #expect(p.steps.contains { $0.proposedName == expected }, "missing \(expected)")
        }
        // Numbered end to end with no gaps and no repeats — the whole claim of the folder.
        #expect(Set(p.steps.map(\.proposedName)).count == 11)
    }

    @Test("PG&E 2021, fully renamed one-digit, is padded and not renumbered")
    func pgeTwentyTwentyOne() {
        let p = plan((3...9).map { "\($0). \(OrdinalMonthName.monthAbbreviations[$0 - 1]) 2021.pdf" },
                     year: "2021")
        #expect(p.steps.count == 7)
        #expect(p.steps.allSatisfy { $0.kind == .tidied })
        #expect(targets(p)["3. Mar 2021.pdf"] == "03. Mar 2021.pdf")
        // Padding preserves the month-number reading the folder was built with — it does NOT
        // renumber Mar to 01 just because it is the first file present.
        #expect(targets(p)["9. Sep 2021.pdf"] == "09. Sep 2021.pdf")
    }
}

/// Folders whose slot is a **date**, not a month — `naming: "ordinal-day"`.
///
/// The survey has written that value for 24 folders since it was built, and nothing read it: the
/// string appeared nowhere else in the app, so the pass declined every one of them. Every fixture
/// below is a real name from those folders, and the folder they mostly come from is
/// `Work/HPE/Compensation/Salary Statements/2026`, which is paid on the 15th and the last day of
/// each month.
@Suite struct OrdinalDayTests {

    private func files(_ names: [String]) -> [FolderFile] {
        names.map { FolderFile(path: "/T/" + $0, name: $0) }
    }

    private func entry(naming: String?, year: String? = nil) -> FolderProfileEntry {
        FolderProfileEntry(path: "T", role: .yearBucket, naming: naming, anchors: [],
                           acceptsNewFiles: true, fileCount: 0, subfolderCount: 0,
                           axes: year.map { ["year": $0] } ?? [:])
    }

    private func plan(_ names: [String], naming: String? = "ordinal-day",
                      year: String? = "2026", incoming: String? = nil) -> RenamePlan {
        RenamePlanner.plan(folderPath: "/T", relativePath: "T", files: files(names),
                           entry: entry(naming: naming, year: year),
                           incoming: incoming.map { FolderFile(path: "/In/" + $0, name: $0) })
    }

    /// The ten payslips the 2026 folder actually held when this was written.
    private var salaryStatements2026: [String] {
        ["01. Jan 15 2026.pdf", "02. Jan 31 2026.pdf", "03. Feb 15 2026.pdf", "04. Feb 28 2026.pdf",
         "05. Mar 15 2026.pdf", "06. Mar 31 2026.pdf", "07. Apr 15 2026.pdf", "08. Apr 30 2026.pdf",
         "09. May 15 2026.pdf", "10. May 31 2026.pdf"]
    }

    // MARK: The grammar

    @Test("A day is read only when it sits between the month and the year")
    func dayIsPositional() {
        #expect(OrdinalMonthName.parse("01. Jan 15 2026.pdf")?.day == 15)
        #expect(OrdinalMonthName.parse("01. Jun 6 2019.pdf")?.day == 6)
        #expect(OrdinalMonthName.parse("01. Jan 01 2019 (Labs).pdf")?.day == 1)
        #expect(OrdinalMonthName.parse("02. Jun 21 2019 Sev.pdf")?.day == 21)
        // **The hazard the positional rule actually buys**, measured over the tree rather than
        // reasoned about: of the 3,681 parseable names, a reader taking any 1–2-digit number in
        // the body finds a day in 378 against this one's 366, and the twelve extras are all the
        // `Form I-20` files below — filed as the 20th of their month because of the form number.
        #expect(OrdinalMonthName.parse("1. Form I-20 - May 2012.pdf")?.day == nil)
        #expect(OrdinalMonthName.parse("6. Form I-20 - Mar 2016.pdf")?.day == nil)
        // These two are also refused, but NOT by the guard — nothing follows the duplicate marker
        // that could be a year, so the scan never considers it. Asserted anyway because the
        // outcome is what matters, and noted because a reader would otherwise credit the wrong
        // rule for it.
        #expect(OrdinalMonthName.parse("11. Nov 2014 -2.pdf")?.day == nil)
        #expect(OrdinalMonthName.parse("01. Jan 2016 (2).pdf")?.day == nil)
        #expect(OrdinalMonthName.parse("01. Jan 2016 (Credit).pdf")?.day == nil)
        #expect(OrdinalMonthName.parse("04. Apr 2025.pdf")?.day == nil)
        // Month and year are unchanged by any of it — the day is strictly additive.
        #expect(OrdinalMonthName.parse("11. Nov 2014 -2.pdf")?.month == 11)
        #expect(OrdinalMonthName.parse("01. Jan 15 2026.pdf")?.month == 1)
        #expect(OrdinalMonthName.parse("01. Jan 15 2026.pdf")?.year == 2026)
    }

    @Test("A dated body keeps its own spelling — only the ordinal is widened")
    func datedBodyIsPreserved() {
        // `13.July 15 2018.pdf` is real, and has two defects: no space, and `July` where the
        // renderer would write `Jul`. Only the first is this pass's business — a body carrying a
        // day is never a bare date, so it is never re-rendered from parts.
        #expect(OrdinalMonthName.parse("13.July 15 2018.pdf")?.canonicalName == "13. July 15 2018.pdf")
        #expect(OrdinalMonthName.parse("1. Feb 26 2019.pdf")?.canonicalName == "01. Feb 26 2019.pdf")
    }

    @Test("A new day-keyed name pads the day")
    func rendersPaddedDay() {
        #expect(OrdinalMonthName.render(ordinal: 11, month: 6, day: 15, year: 2026, ext: "pdf")
                == "11. Jun 15 2026.pdf")
        #expect(OrdinalMonthName.render(ordinal: 1, month: 6, day: 6, year: 2019, ext: "pdf")
                == "01. Jun 06 2019.pdf")
    }

    // MARK: Mining a day out of a raw name

    @Test("A delimited date is mined, day and all")
    func minesDelimitedDates() {
        // The name the whole feature exists for. Its runs are `Payslip · 2026 · 06 · 15` — no
        // 8-digit stamp, no spelled month — so before this it mined NOTHING and the file could not
        // be placed in any folder, day-keyed or not.
        let m = FileNameDate.mine("Payslip_2026-06-15.pdf")
        #expect(m?.month == 6)
        #expect(m?.day == 15)
        #expect(m?.year == 2026)
        #expect(FileNameDate.mine("Statement 06 15 2026.pdf")?.day == 15)
        // Shape-disjoint, so neither window is a coin flip.
        #expect(FileNameDate.mine("2026-06-15.pdf")?.month == 6)
        #expect(FileNameDate.mine("06-15-2026.pdf")?.month == 6)
        // An account reference whose runs are the wrong widths stays refused.
        #expect(FileNameDate.mine("STMTCMB100_5203_9911.pdf") == nil)
        // `DD MM YYYY` is refused outright — `15 06 2026` cannot be told from a US June 15th.
        #expect(FileNameDate.mine("bill 15 13 2026.pdf") == nil)
    }

    @Test("The 8-digit datestamp now reports its day, and its month is unchanged")
    func datestampReportsDay() {
        #expect(FileNameDate.mine("9829custbill07182023.pdf")?.day == 18)
        #expect(FileNameDate.mine("9829custbill07182023.pdf")?.month == 7)
        #expect(FileNameDate.mine("20240128-statements-8857.pdf")?.day == 28)
        // Two stamps in one month still answer the month — folding the day into that key would
        // turn a known month with an unknown day into a refusal.
        let two = FileNameDate.mine("bill 20240115 and 20240120.pdf")
        #expect(two?.month == 1)
        #expect(two?.day == nil)
    }

    @Test("Readings that disagree still refuse, and one that abstains does not veto")
    func readingsMustAgree() {
        // A datestamp for one month beside a word for another is not a name this pass understands.
        #expect(FileNameDate.mine("Feb 2020 stamped 20200315.pdf") == nil)
        // A spelled month with no day beside a stamp that has one: the day is known once.
        #expect(FileNameDate.mine("Jan 2024 - 20240115.pdf")?.day == 15)
    }

    // MARK: The slot is a date

    @Test("Two payslips in one month are two slots, not a collision")
    func twoFilesOneMonth() {
        // Against the month-keyed reading `02. Jan 31 2026.pdf` is a second January and the pass
        // would report it as colliding with `01. Jan 15 2026.pdf`. Under `ordinal-day` they are
        // simply the two payments January holds.
        let p = plan(salaryStatements2026)
        #expect(p.steps.isEmpty)     // already canonical
        #expect(p.skips.isEmpty)
    }

    @Test("A payslip filed in takes the next slot, keeping the day")
    func placesIncomingPayslip() {
        let p = plan(salaryStatements2026, incoming: "Payslip_2026-06-15.pdf")
        let step = p.steps.first { $0.currentName == "Payslip_2026-06-15.pdf" }
        #expect(step?.proposedName == "11. Jun 15 2026.pdf")
        #expect(step?.kind == .placed)
        // Nothing else moves: it lands after everything already there.
        #expect(step?.cohort == 0)
        #expect(p.steps.count == 1)
    }

    @Test("The second payslip of a month does not collide with the first")
    func secondPayslipOfAMonth() {
        // Jun 15 has landed; Jun 30 must get slot 12, not "June is already held here".
        let p = plan(salaryStatements2026 + ["11. Jun 15 2026.pdf"],
                     incoming: "Payslip_2026-06-30.pdf")
        #expect(p.steps.first { $0.currentName == "Payslip_2026-06-30.pdf" }?.proposedName
                == "12. Jun 30 2026.pdf")
        #expect(p.skips.isEmpty)
    }

    @Test("The same date twice is still refused")
    func sameDateStillCollides() {
        // The duplicate trap the pass exists for, at day resolution: a raw re-download of a payslip
        // already filed. Reported, never guessed at.
        let p = plan(salaryStatements2026, incoming: "Payslip_2026-05-15.pdf")
        #expect(p.steps.isEmpty)
        // `first?` rather than `[0]`: an #expect on the count does not stop the run, so a
        // subscript here turns a readable failure into an index-out-of-range crash that hides it.
        #expect(p.skips.count == 1)
        #expect(p.skips.first?.reason.contains("May 15 2026") == true)
        #expect(p.skips.first?.reason.contains("09. May 15 2026.pdf") == true)
    }

    @Test("A day-keyed folder says so when the incoming name gives no day")
    func incomingWithoutADaySaysSo() {
        let p = plan(salaryStatements2026, incoming: "Payslip Jun 2026.pdf")
        #expect(p.steps.isEmpty)
        #expect(p.skips.count == 1)
        #expect(p.skips.first?.reason.contains("no day") == true)
    }

    @Test("A day-keyed folder is never read as month-numbered")
    func dayFoldersAreAlwaysPositional() {
        // `Salary Statements/2019` starts in October, so its first files are `01. Oct 15 · 02. Oct
        // 31` — and a stretch that happens to run one file per month would read as `.monthNumber`,
        // whose whole premise (the ordinal IS the month) cannot describe this folder.
        // The fixture has GAPS on purpose. A contiguous 01·02·03 run is one the two schemes cannot
        // tell apart, and `inferScheme` deliberately calls that `.position` — so a contiguous
        // fixture would pass this test with the guard removed, which is no test at all.
        let gappy = ["03. Mar 15 2021.pdf", "05. May 15 2021.pdf", "11. Nov 15 2021.pdf"]
        #expect(RenamePlanner.inferScheme(files: files(gappy), granularity: .day) == .position)
        // The same shape read month-keyed DOES infer monthNumber, which is what makes the line
        // above a measurement of the guard rather than of the fixture.
        #expect(RenamePlanner.inferScheme(
            files: files(["03. Mar 2021.pdf", "05. May 2021.pdf", "11. Nov 2021.pdf"]),
            granularity: .month) == .monthNumber)
    }

    @Test("Granularity comes from the profile, and is inferred only unanimously")
    func granularityRules() {
        #expect(RenamePlanner.slotGranularity(files: [], entry: entry(naming: "ordinal-day")) == .day)
        #expect(RenamePlanner.slotGranularity(files: [], entry: entry(naming: "ordinal-month")) == .month)
        #expect(RenamePlanner.slotGranularity(files: [], entry: entry(naming: "descriptive")) == nil)
        // Unsurveyed: all three conforming names carry days, so the folder is day-keyed.
        #expect(RenamePlanner.slotGranularity(
            files: files(["01. Jan 15 2026.pdf", "02. Jan 31 2026.pdf", "03. Feb 15 2026.pdf"]),
            entry: nil) == .day)
        // One dated stray among bare months is a stray, not a day-keyed folder — reading it as one
        // would renumber the eleven files around it.
        #expect(RenamePlanner.slotGranularity(
            files: files(["01. Jan 15 2026.pdf", "02. Feb 2026.pdf", "03. Mar 2026.pdf"]),
            entry: nil) == .month)
    }

    @Test("A month-keyed folder ignores a day its names happen to carry")
    func monthKeyedIsUnchanged() {
        // The regression guard for the 327 folders that were already working. These names carry
        // days, but the folder says `ordinal-month`, so the second January is still a collision.
        let p = plan(["01. Jan 15 2026.pdf"], naming: "ordinal-month",
                     incoming: "Payslip_2026-01-31.pdf")
        #expect(p.steps.isEmpty)
        #expect(p.skips.count == 1)
        #expect(p.skips.first?.reason.contains("Jan 2026") == true)
        #expect(p.skips.first?.reason.contains("Jan 31 2026") == false)
    }
}
