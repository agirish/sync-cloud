import Testing
import Foundation
@testable import Sync

/// Coverage for the cloud-only (dataless) detection: the `SF_DATALESS` flag math and the safe
/// false-cases of the lstat path.
@Suite struct MaterializationStatusTests {

    @Test func datalessFlagMath() {
        #expect(MaterializationStatus.isDataless(flags: 0) == false)
        #expect(MaterializationStatus.isDataless(flags: 0x4000_0000) == true)
        // The dataless bit set alongside other flags still reads as dataless…
        #expect(MaterializationStatus.isDataless(flags: 0x4000_0000 | 0x1) == true)
        // …and an unrelated flag alone does not.
        #expect(MaterializationStatus.isDataless(flags: 0x2000_0000) == false)
    }

    /// Exhaustive single-bit sweep: of all 32 st_flags bits, ONLY bit 30 (SF_DATALESS,
    /// 0x4000_0000) may read as dataless — a mask typo (0x2000_0000, a >>/<< slip, a signed
    /// shift artifact on bit 31) flips exactly one cell of this table.
    @Test func onlyTheDatalessBitReadsAsDataless() {
        for bit in 0..<32 {
            let flag = UInt32(1) << UInt32(bit)
            #expect(MaterializationStatus.isDataless(flags: flag) == (bit == 30),
                    "bit \(bit) (\(String(flag, radix: 16)))")
        }
        // All bits set reads dataless; all bits EXCEPT 30 set does not.
        #expect(MaterializationStatus.isDataless(flags: .max) == true)
        #expect(MaterializationStatus.isDataless(flags: ~UInt32(0x4000_0000)) == false)
    }

    @Test func ordinaryLocalFileIsNotCloudOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mat-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MaterializationStatus.isCloudOnly(atPath: url.path) == false)
    }

    @Test func missingPathIsNotCloudOnly() {
        #expect(MaterializationStatus.isCloudOnly(atPath: "/no/such/file-\(UUID().uuidString)") == false)
    }
}
