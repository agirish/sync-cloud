import Foundation

/// A count and its noun, inflected for the count and with the number grouped the way the reader's
/// locale writes it: "1 Item", "2 Items", "7,363 Items".
///
/// Undo action names ("Move 2 Items to Trash", read in the Edit menu as "Undo Move 2 Items to
/// Trash") and progress titles ("Moving 7,363 Items to the Trash", sitting over "3,336 of 7,363") are built from this, so a single
/// item never reads as "1 Items" and a title's count is grouped like the counter under it. Each
/// call site keeps its own noun and case — "Item" for an undo name in Title Case, "file" for a
/// progress title that says files.
enum CountedNoun {
    /// - Parameters:
    ///   - count: How many.
    ///   - singular: The noun for exactly one, in the case the caller wants ("Item", "file").
    ///   - plural: The noun for any other count; `singular + "s"` when nil.
    ///   - locale: Groups the number; the reader's locale unless a test pins one.
    static func phrase(_ count: Int, _ singular: String, plural: String? = nil,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let noun = count == 1 ? singular : (plural ?? singular + "s")
        return "\(count.formatted(.number.locale(locale))) \(noun)"
    }
}
