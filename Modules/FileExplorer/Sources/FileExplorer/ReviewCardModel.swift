import Foundation
import Sync

extension FileDifference {
    /// Absolute path of the side this difference's `action` copies FROM.
    var reviewSourcePath: String {
        action == .copyToRight ? leftItemPath : rightItemPath
    }

    /// Absolute path the copy lands at — the side that gets replaced (or created).
    var reviewDestinationPath: String {
        action == .copyToRight ? rightItemPath : leftItemPath
    }
}

/// Everything the review card renders for one queue item, derived purely from the difference,
/// the on-disk facts statted when the item became current, and the pane names. SwiftUI-free so
/// every label, delta, and warning rule is unit-testable.
struct ReviewCardModel: Equatable {
    /// On-disk facts the card stats per item (sizes travel on `FileDifference` already; dates
    /// and the folder-contents count don't). Starts empty while the stat runs — the card
    /// renders sizes immediately and the date fields fill in.
    struct Facts: Equatable, Sendable {
        var sourceModified: Date? = nil
        var destinationModified: Date? = nil
        var destinationIsDirectory: Bool = false
        /// Items anywhere under a destination folder a replace would remove; counting stops
        /// at `childCountCap` (`destinationChildCountCapped` then reads "N+ items").
        ///
        /// **nil means the folder could not be listed**, not that it holds nothing — a folder that
        /// really is empty carries `0`. The warning turns nil into "everything", which is the only
        /// honest thing to say about contents nobody could see.
        var destinationChildCount: Int? = nil
        var destinationChildCountCapped: Bool = false
        /// True when part of the folder could be read and part could not, so the count is a floor.
        /// Distinct from `destinationChildCountCapped`, which is a floor we chose; this one is a
        /// floor the disk imposed.
        var destinationChildCountIsPartial: Bool = false
    }

    /// Two modification dates within this tolerance count as "same date" — cross-volume copies
    /// commonly land a second apart (FAT stores 2s resolution; cloud stamps round).
    static let dateTolerance: TimeInterval = 2

    var fileName: String
    var parentPath: String
    /// "Local → iCloud" — the direction chip's main text.
    var directionText: String
    /// The chip's qualifier: "replaces existing" or "new".
    var directionDetail: String
    var isReplace: Bool
    /// The primary button's verb: "Copy" or "Move".
    var primaryVerb: String
    /// "Copying from Local" / "Moving from Local".
    var sourceLabel: String
    /// "Replaces on iCloud"; nil for missing-side items (nothing gets replaced).
    var destinationLabel: String?
    var sourceSizeText: String?
    var destinationSizeText: String?
    var sourceDateText: String?
    var destinationDateText: String?
    /// "3 days newer · +1.1 MB" — nil for new items or while dates are still loading.
    var deltaText: String?
    /// True when the destination is meaningfully newer than the source (tints the delta amber).
    var sourceIsOlder: Bool
    /// The calm single-line summary for missing-side items ("New on iCloud — nothing replaced.").
    var newItemText: String?
    /// Amber banner text: folder wholesale-replace or destination-newer. nil when the copy is benign.
    var warningText: String?
    /// Whether the per-item "Verify" action applies (date-only difference, same size, not a folder).
    var canVerify: Bool
    /// Best-effort folder signal for the card's icon tile: missing folders carry
    /// `enclosedItemCount`, replaced folders are statted. A miss just means a generic file icon.
    var isFolder: Bool

    @MainActor
    static func make(
        difference: FileDifference,
        facts: Facts,
        paneNames: PaneProviderNames,
        isMove: Bool
    ) -> ReviewCardModel {
        let toRight = difference.action == .copyToRight
        let sourceName = toRight ? paneNames.left : paneNames.right
        let destinationName = toRight ? paneNames.right : paneNames.left
        let isReplace = difference.type == .differentDates
        let sourceSize = difference.displaySize
        let destinationSize = toRight ? difference.rightFileSize : difference.leftFileSize

        let sourceIsOlder: Bool
        if let source = facts.sourceModified, let destination = facts.destinationModified {
            sourceIsOlder = destination.timeIntervalSince(source) > dateTolerance
        } else {
            sourceIsOlder = false
        }

        var newItemText: String? = nil
        if !isReplace {
            var text = "New on \(destinationName) — nothing replaced."
            if let count = difference.enclosedItemCount, count > 0 {
                text += " Includes \(count) item\(count == 1 ? "" : "s")."
            }
            newItemText = text
        }

        return ReviewCardModel(
            fileName: difference.fileName,
            parentPath: difference.parentPath,
            directionText: "\(sourceName) → \(destinationName)",
            directionDetail: isReplace ? "replaces existing" : "new",
            isReplace: isReplace,
            primaryVerb: isMove ? "Move" : "Copy",
            sourceLabel: "\(isMove ? "Moving" : "Copying") from \(sourceName)",
            destinationLabel: isReplace ? "Replaces on \(destinationName)" : nil,
            sourceSizeText: sourceSize.map { FileSizeFormat.byteCount.string(fromByteCount: Int64($0)) },
            destinationSizeText: isReplace
                ? destinationSize.map { FileSizeFormat.byteCount.string(fromByteCount: Int64($0)) }
                : nil,
            sourceDateText: facts.sourceModified.map { dateFormatter.string(from: $0) },
            destinationDateText: isReplace
                ? facts.destinationModified.map { dateFormatter.string(from: $0) }
                : nil,
            deltaText: isReplace
                ? deltaDescription(
                    sourceModified: facts.sourceModified,
                    destinationModified: facts.destinationModified,
                    sourceSize: sourceSize,
                    destinationSize: destinationSize)
                : nil,
            sourceIsOlder: sourceIsOlder,
            newItemText: newItemText,
            warningText: warningText(
                difference: difference,
                facts: facts,
                destinationName: destinationName,
                isMove: isMove),
            canVerify: isReplace && difference.sizesMatch && !facts.destinationIsDirectory,
            isFolder: facts.destinationIsDirectory || difference.enclosedItemCount != nil
        )
    }

    /// The delta chip: time and size differences joined ("3 days newer · +1.1 MB"), or nil
    /// when neither is computable yet.
    @MainActor
    static func deltaDescription(
        sourceModified: Date?,
        destinationModified: Date?,
        sourceSize: Int?,
        destinationSize: Int?
    ) -> String? {
        let parts = [
            timeDeltaDescription(sourceModified: sourceModified, destinationModified: destinationModified),
            sizeDeltaDescription(sourceSize: sourceSize, destinationSize: destinationSize),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "3 days newer" / "5 minutes older" / "same date" — source relative to destination,
    /// coarsest single unit (this is orientation, not arithmetic; exact stamps sit next to it).
    static func timeDeltaDescription(sourceModified: Date?, destinationModified: Date?) -> String? {
        guard let source = sourceModified, let destination = destinationModified else { return nil }
        let interval = source.timeIntervalSince(destination)
        let magnitude = abs(interval)
        if magnitude < dateTolerance { return "same date" }
        let value: Int
        let unit: String
        switch magnitude {
        case ..<60: value = Int(magnitude); unit = "second"
        case ..<3600: value = Int(magnitude / 60); unit = "minute"
        case ..<86400: value = Int(magnitude / 3600); unit = "hour"
        default: value = Int(magnitude / 86400); unit = "day"
        }
        return "\(value) \(unit)\(value == 1 ? "" : "s") \(interval > 0 ? "newer" : "older")"
    }

    /// "+1.1 MB" / "−400 KB" / "same size" — source relative to destination.
    @MainActor
    static func sizeDeltaDescription(sourceSize: Int?, destinationSize: Int?) -> String? {
        guard let source = sourceSize, let destination = destinationSize else { return nil }
        if source == destination { return "same size" }
        let magnitude = FileSizeFormat.byteCount.string(fromByteCount: Int64(abs(source - destination)))
        return (source > destination ? "+" : "−") + magnitude
    }

    /// The amber banner. Folder wholesale-replace wins over destination-newer: it implies it,
    /// and losing a folder's contents is the bigger hazard. Wording matches the collision
    /// alert's Finder-style folder warning.
    static func warningText(
        difference: FileDifference,
        facts: Facts,
        destinationName: String,
        isMove: Bool
    ) -> String? {
        guard difference.type == .differentDates else { return nil }
        if facts.destinationIsDirectory {
            let removed: String
            if let count = facts.destinationChildCount {
                if facts.destinationChildCountCapped {
                    // "1000+" already reads as a floor, so a partial count that also hit the cap
                    // needs no second hedge.
                    removed = "\(count)+ items"
                } else if facts.destinationChildCountIsPartial {
                    // Part of the folder was withheld, so the count is what we could see and the
                    // real number is larger. Saying the bare number would understate a destructive
                    // action, which is the one direction this sentence must never err in.
                    removed = "at least \(count) item\(count == 1 ? "" : "s")"
                } else {
                    removed = "\(count) item\(count == 1 ? "" : "s")"
                }
            } else {
                // The folder could not be listed at all. Not "0 items" — nobody knows what is in
                // there, and this sentence is the last thing shown before it is replaced.
                removed = "everything"
            }
            return "Replacing this folder replaces its entire contents — \(removed) on \(destinationName) will be removed."
        }
        if let source = facts.sourceModified, let destination = facts.destinationModified,
           destination.timeIntervalSince(source) > dateTolerance {
            return "The \(destinationName) copy is newer than the one you're about to \(isMove ? "move" : "copy") over it."
        }
        return nil
    }

    /// "Jul 8, 2026 at 6:12 PM" — one cached formatter (same churn rule as `FileSizeFormat`).
    @MainActor private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
