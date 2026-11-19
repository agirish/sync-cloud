import Foundation
import Testing
@testable import Sync

/// Medical papers go to the person their record number names, billing to Insurance whoever it
/// names (``HealthLane``).
@Suite struct HealthLaneTests {
    typealias P = DocumentFacts.Period

    @Test func pageOneSaysWhatKindItIs() {
        func kind(_ page: String) -> HealthLane.Kind? { HealthLane.kind(of: page.lowercased()) }
        #expect(kind("KAISER FOUNDATION HEALTH PLAN This is not a bill. This Explanation of Benefits is a summary") == .eob)
        #expect(kind("Your professional medical bill Pay with a credit card") == .bill(label: "Physician Bill"))
        #expect(kind("Status: Processed Claims report Claim number: 1 Provider: SANTA CLARA Your plan covers") == .claim)
        #expect(kind("AFTER VISIT SUMMARY Jane Doe MRN: 11223344 Date of birth: 1/9/1988") == .visit(label: "After Visit Summary"))
        #expect(kind("Continuity of Care Document - Jane Doe (Female, born Dec. 18, 1987)") == .visit(label: "Visit Record (CCD)"))
        #expect(kind("Member name: Jane Doe MRN: 11223344 Lab results: Lipid panel") == .testResult)
        #expect(kind("Jane Doe (MRN: 1) Printed at 6/11/19 You were seen on Tuesday June 11, 2019. Tdap lab results") == .visit(label: "After Visit Summary"))
        #expect(kind("Jane Doe (MRN: 1) You saw CHARLES OWYANG MD on Wednesday August 21, 2019. Test results") == .visit(label: "After Visit Summary"))
        #expect(kind("Thyroid-Stimulating Hormone (TSH) Test Overview Why It Is Done") == nil, "a health article is no one's result")
        #expect(kind("Bank of America statement Account summary") == nil)
    }

    @Test func theDateIsTheVisitsNotTheBirthdayOrThePrintout() {
        #expect(HealthLane.date(in: "after visit summary mrn: 1 date of birth: 1/9/1988 10/17/2025 wcr-hospital")
                == P(year: 2025, month: 10, day: 17))
        #expect(HealthLane.date(in: "date printed: 10/17/2016 member name x date of birth: 12/18/1987 visit date: 09/14/2015")
                == P(year: 2015, month: 9, day: 14))
        #expect(HealthLane.newestDate(in: "date printed: 1/6/2024 date of birth: 1/9/1988 collected on october 25, 2021")
                == P(year: 2024, month: 1, day: 6), "a result printed in 2024 showing a 2021 collection")
        #expect(HealthLane.date(in: "plan year: 01/01/2025 through 12/31/2025 the services you've received. december 02, 2025")
                == P(year: 2025, month: 12, day: 2))
        #expect(HealthLane.date(in: "minimum amount due: $5 due by: 09/22/2022 abhishek bill date: 08/23/2022")
                == P(year: 2022, month: 8, day: 23))
        #expect(HealthLane.recordNumbers(in: "AFTER VISIT SUMMARY MRN: 11223344 Medical Record No. 55667788") == ["11223344", "55667788"])
    }

    @Test func aVisitTakesTheNextNumberInItsYear() {
        let existing = ["1. Jan 5 2025 - Adult Medicine - After Visit Summary.pdf", "2. Mar 8 2025 - ENT - Visit Notes.pdf", ".DS_Store"]
        #expect(HealthLane.visitName(P(year: 2025, month: 4, day: 2), label: "After Visit Summary", existing: existing, ext: "pdf")
                == "3. Apr 2 2025 - After Visit Summary.pdf")
        #expect(HealthLane.visitName(P(year: 2025, month: 3, day: 8), label: "After Visit Summary", existing: existing, ext: "pdf")
                == "2. Mar 8 2025 - After Visit Summary.pdf", "a visit's paired papers share its number")
        #expect(HealthLane.visitName(P(year: 2025, month: 2, day: 1), label: "Visit Notes", existing: existing, ext: "pdf") == nil,
                "an earlier visit would renumber the rest: his to do")
        #expect(HealthLane.visitName(P(year: 2025, month: 1, day: 3), label: "Visit Notes", existing: [], ext: "pdf")
                == "1. Jan 3 2025 - Visit Notes.pdf")
        #expect(HealthLane.visitName(P(year: 2025, month: 12, day: 3), label: "Visit Notes", existing: ["11. Nov 2 2025 - x.pdf"], ext: "pdf")
                == "12. Dec 3 2025 - Visit Notes.pdf")
        #expect(HealthLane.visitName(P(year: 2025, month: 12, day: 3), label: "Visit Notes", existing: ["03. Nov 2 2025 - x.pdf"], ext: "pdf")
                == "04. Dec 3 2025 - Visit Notes.pdf", "the folder's own width")
    }

    // MARK: The pass

    private static let root = "/r/Docs"
    private static let med = "Health/Medical"
    private static func file(_ rel: String) -> FileNode {
        FileNode(id: root + "/" + rel, name: (rel as NSString).lastPathComponent, isDirectory: false)
    }
    private static func dir(_ rel: String, _ c: [FileNode] = []) -> FileNode {
        FileNode(id: root + "/" + rel, name: (rel as NSString).lastPathComponent, isDirectory: true, children: c)
    }
    private static let taxonomy = [dir("Health", [dir(med, [
        dir(med + "/Aditi", [dir(med + "/Aditi/Visits", [dir(med + "/Aditi/Visits/2025",
            [file(med + "/Aditi/Visits/2025/1. Jan 5 2025 - Pediatrics - After Visit Summary.pdf")])]),
                             dir(med + "/Aditi/Test Results")]),
        dir(med + "/Divit", [dir(med + "/Divit/Visits", [dir(med + "/Divit/Visits/2024")])]),
        dir(med + "/Insurance", [dir(med + "/Insurance/EOBs", [dir(med + "/Insurance/EOBs/2025")])]),
    ])])]
    private static let salt = "0123456789abcdef"
    /// What the survey learned: Aditi's visit pages printed her number.
    private static let memory = FilingMemory(profileId: "t", salt: salt, folders: [
        med + "/Aditi/Visits/2025": FilingMemoryEntry(docs: 1, anchors: [],
            idHashes: [FilingMemoryToken(token: FilingMemory.hash("11223344", salt: salt), weight: 1)], folderModified: nil),
    ])

    private static func card(_ name: String = "AVS.pdf") -> FilingSuggestion {
        FilingSuggestion(filePath: "/r/In/" + name, fileName: name, size: 1, modificationDate: nil,
                         candidates: [FilingDestination(path: root + "/Health/Medical/Divit/Visits/2024", confidence: .medium,
                                                        reasons: ["name"], newSegments: [])], providerRoot: root)
    }
    private static func best(_ page: String, memory: FilingMemory? = memory) -> FilingDestination? {
        let s = card()
        return HealthLane.placing([s], pages: [s.filePath: page], taxonomy: taxonomy, root: root, memory: memory).first?.best
    }

    /// Her number decides, whatever name the page prints (here her brother's, as the holder's
    /// name rides on family records).
    @Test func theRecordNumberDecidesThePerson() throws {
        let b = try #require(Self.best("AFTER VISIT SUMMARY Divit Abhishek MRN: 11223344 Date of birth: 1/9/2019 04/02/2025 Pediatrics"))
        #expect(b.path == Self.root + "/" + Self.med + "/Aditi/Visits/2025")
        #expect(b.proposedName == "2. Apr 2 2025 - After Visit Summary.pdf")
        #expect(b.confidence == .high)
        // No number the memory knows: left to the other lanes.
        #expect(Self.best("AFTER VISIT SUMMARY MRN: 99999999 04/02/2025")?.path == Self.card().best?.path)
        #expect(Self.best("AFTER VISIT SUMMARY MRN: 11223344 04/02/2025", memory: nil)?.path == Self.card().best?.path)
        // A number the memory saw under two people says nothing about which.
        let token = FilingMemoryToken(token: FilingMemory.hash("11223344", salt: Self.salt), weight: 1)
        let both = FilingMemory(profileId: "t", salt: Self.salt, folders: [
            Self.med + "/Aditi/Visits/2025": FilingMemoryEntry(docs: 1, anchors: [], idHashes: [token], folderModified: nil),
            Self.med + "/Divit/Visits/2024": FilingMemoryEntry(docs: 1, anchors: [], idHashes: [token], folderModified: nil),
        ])
        #expect(Self.best("AFTER VISIT SUMMARY MRN: 11223344 04/02/2025", memory: both)?.path == Self.card().best?.path)
    }

    @Test func billingGoesToInsuranceWhoeverItNames() throws {
        let b = try #require(Self.best("KAISER FOUNDATION HEALTH PLAN Aditi MRN: 11223344 This Explanation of Benefits is a summary. Statement date: 12/02/2025"))
        #expect(b.path == Self.root + "/" + Self.med + "/Insurance/EOBs/2025")
        #expect(b.proposedName == "Kaiser EOB - Dec 2 2025.pdf")
        let bill = try #require(Self.best("Your professional medical bill Kaiser Permanente Statement date: 09/22/2022"))
        #expect(bill.path == Self.root + "/" + Self.med + "/Insurance/Bills/2022", "Bills is made, laid out like EOBs")
        #expect(bill.newSegments == ["Bills", "2022"])
        #expect(bill.proposedName == "Kaiser Physician Bill - Sep 22 2022.pdf")
    }

    @Test func aFolderAPersonLacksIsLaidOutLikeAnyoneElses() throws {
        let b = try #require(Self.best("Member name: X MRN: 11223344 Lab results: Lipid panel Collected 03/04/2025"))
        #expect(b.path == Self.root + "/" + Self.med + "/Aditi/Test Results", "Test Results keeps no years")
    }
}
