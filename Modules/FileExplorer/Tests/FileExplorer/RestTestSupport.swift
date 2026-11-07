import Foundation
import Testing

/// A file's bytes and modification date, its date first set into the past so a write this second
/// can't hide behind it. For the data-safety checks that an original was left alone.
struct RestPinnedOriginal {
    let bytes: Data
    let modified: Date

    init(_ file: String) throws {
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file)
        bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        modified = past
    }

    func expectUntouched(_ file: String, _ label: String,
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == bytes, "\(label): the original's bytes changed",
                sourceLocation: sourceLocation)
        let date = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
        #expect(date == modified, "\(label): the original's date moved", sourceLocation: sourceLocation)
    }
}
