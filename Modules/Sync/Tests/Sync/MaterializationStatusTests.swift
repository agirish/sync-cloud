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
