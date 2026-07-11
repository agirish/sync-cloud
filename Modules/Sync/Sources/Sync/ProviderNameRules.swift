import Foundation

/// Pure rules for provider-hostile file names, shared by the diff engine and the transfer
/// pre-flight check.
///
/// Two distinct concerns live here because they share the same character-level facts:
///
/// 1. **Near-name matching** (`nearNameKey`): two panes can hold the "same" item under names
///    that differ only invisibly — trailing/leading whitespace, trailing dots, or Unicode
///    NFC/NFD form — because one provider's server normalizes names the other stores verbatim
///    (Dropbox stores `Swimming`, iCloud keeps `Swimming `). Exact-path diffing then reports
///    two phantom "missing" rows whose copy actions mint identical-looking local-only
///    duplicates the stricter provider can never upload. The diff engine keys both sides by
///    `nearNameKey` to pair such entries into a single `.nameConflict` row instead.
///
/// 2. **Destination validity** (`violation`/`sanitized`): before a copy writes into a cloud
///    provider's folder, the target name is checked against that provider's rules so the app
///    can offer a sanitized name up front rather than silently creating an unsyncable item.
public enum ProviderNameRules {

    // MARK: - Near-name normalization (diff matching)

    /// One path component reduced to the form a strict provider would store: Unicode
    /// precomposed (NFC), leading/trailing whitespace stripped, trailing dots stripped.
    /// A component that would vanish entirely (all whitespace/dots) keeps its precomposed
    /// form instead — collapsing e.g. `" "` and `"."` to the same empty key would pair
    /// unrelated pathological names.
    public static func normalizedComponent(_ name: String) -> String {
        let precomposed = name.precomposedStringWithCanonicalMapping
        var trimmed = precomposed.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? precomposed : trimmed
    }

    /// A relative path normalized per component (see `normalizedComponent`), optionally
    /// case-folded — pass `foldCase: true` exactly when the diff runs case-insensitively,
    /// so a pair differing by case AND whitespace still meets on one key. Normalizing the
    /// FULL path (not just the leaf) also matches descendants of folders whose names differ
    /// only invisibly, so identical children under `Swimming ` and `Swimming` pair up
    /// instead of double-reporting.
    public static func nearNameKey(forRelativePath path: String, foldCase: Bool) -> String {
        let normalized = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { normalizedComponent(String($0)) }
            .joined(separator: "/")
        return foldCase ? normalized.lowercased() : normalized
    }

    /// Human phrase for HOW two leaf names differ invisibly, for `.nameConflict` descriptions.
    /// Checks the specific single-cause cases first so the message can name the exact culprit.
    static func nameDifferenceDetail(_ a: String, _ b: String) -> String {
        func withoutTrailingWhitespace(_ s: String) -> String {
            var t = s
            while let last = t.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
                t.unicodeScalars.removeLast()
            }
            return t
        }
        func withoutLeadingWhitespace(_ s: String) -> String {
            var t = s
            while let first = t.unicodeScalars.first, CharacterSet.whitespacesAndNewlines.contains(first) {
                t.unicodeScalars.removeFirst()
            }
            return t
        }
        func withoutTrailingDots(_ s: String) -> String {
            var t = s
            while t.hasSuffix(".") { t.removeLast() }
            return t
        }
        if a.precomposedStringWithCanonicalMapping == b.precomposedStringWithCanonicalMapping {
            return "same name in a different Unicode form"
        }
        if withoutTrailingWhitespace(a) == withoutTrailingWhitespace(b) {
            return "a trailing space"
        }
        if withoutLeadingWhitespace(a) == withoutLeadingWhitespace(b) {
            return "a leading space"
        }
        if withoutTrailingDots(a) == withoutTrailingDots(b) {
            return "a trailing period"
        }
        return "invisible name characters"
    }

    /// Description for a `.nameConflict` difference. Quotes both spellings so the invisible
    /// difference has visible boundaries, and names the providers (which travel with their
    /// files through a pane swap, so the text stays true unmirrored).
    public static func nameConflictDescription(
        leftName: String, leftProvider: String,
        rightName: String, rightProvider: String
    ) -> String {
        "Names differ by \(nameDifferenceDetail(leftName, rightName)): "
            + "\"\(leftName)\" (\(leftProvider)) vs \"\(rightName)\" (\(rightProvider))"
    }

    // MARK: - Destination validity (pre-write check)

    /// One provider-invalid path component: what it is, why it's invalid, and a valid
    /// replacement to offer.
    public struct Violation: Equatable, Sendable {
        /// The offending path component, verbatim.
        public let componentName: String
        /// Human-readable reason suitable for an alert.
        public let reason: String
        /// A name the provider accepts (see `sanitized(name:for:)`).
        public let sanitizedName: String
    }

    /// Windows/OneDrive reserved device names; invalid as a base name regardless of extension.
    private static let oneDriveReservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for i in 0...9 {
            names.insert("COM\(i)")
            names.insert("LPT\(i)")
        }
        return names
    }()

    /// Characters OneDrive forbids anywhere in a name ("/" can't occur in a single component).
    private static let oneDriveForbiddenCharacters = Set<Character>("\"*:<>?/\\|")

    /// Why `name` can't be stored by `provider`, or nil when it is acceptable. iCloud and
    /// Google Drive accept anything the local filesystem does, so they never report one.
    public static func violation(name: String, provider: CloudProvider.ProviderType) -> Violation? {
        func make(_ reason: String) -> Violation {
            Violation(componentName: name, reason: reason, sanitizedName: sanitized(name: name, for: provider))
        }
        switch provider {
        case .iCloud, .googleDrive:
            return nil
        case .dropBox:
            if name.hasSuffix(" ") {
                return make("Dropbox doesn't allow names ending with a space.")
            }
            if name.hasSuffix(".") {
                return make("Dropbox doesn't allow names ending with a period.")
            }
            return nil
        case .oneDrive:
            if let forbidden = name.first(where: { oneDriveForbiddenCharacters.contains($0) }) {
                return make("OneDrive doesn't allow \"\(forbidden)\" in names.")
            }
            if name.hasPrefix(" ") || name.hasSuffix(" ") {
                return make("OneDrive doesn't allow names beginning or ending with a space.")
            }
            if name.hasSuffix(".") {
                return make("OneDrive doesn't allow names ending with a period.")
            }
            let baseName = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
            if oneDriveReservedNames.contains(baseName.uppercased()) {
                return make("\"\(baseName)\" is a reserved name on OneDrive.")
            }
            return nil
        }
    }

    /// The first provider-invalid component along `relativePath` (checked root-outward), or
    /// nil when every component is acceptable. Every component is checked — not just the
    /// leaf — because a copy that creates intermediate folders inherits their names from the
    /// source side, and an invalid ancestor is just as unsyncable as an invalid leaf.
    public static func violation(inRelativePath path: String, for provider: CloudProvider.ProviderType) -> Violation? {
        for component in path.split(separator: "/") {
            if let violation = violation(name: String(component), provider: provider) {
                return violation
            }
        }
        return nil
    }

    /// A nearby name `provider` accepts: forbidden characters replaced with "-", affix
    /// whitespace and trailing dots stripped (repeatedly, so "name . " fully settles),
    /// reserved names suffixed. Falls back to "untitled" if nothing survives.
    public static func sanitized(name: String, for provider: CloudProvider.ProviderType) -> String {
        var result = name
        if provider == .oneDrive {
            result = String(result.map { oneDriveForbiddenCharacters.contains($0) ? "-" : $0 })
        }
        var previous: String
        repeat {
            previous = result
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            while result.hasSuffix(".") { result.removeLast() }
        } while result != previous
        if result.isEmpty {
            result = "untitled"
        }
        if provider == .oneDrive {
            let baseName = result.split(separator: ".", maxSplits: 1).first.map(String.init) ?? result
            if oneDriveReservedNames.contains(baseName.uppercased()) {
                result += "-1"
            }
        }
        return result
    }

    /// `relativePath` with every component sanitized for `provider` (see `sanitized(name:for:)`).
    /// Valid components come through byte-identical, so an existing valid ancestor keeps
    /// addressing the same folder.
    public static func sanitizedRelativePath(_ path: String, for provider: CloudProvider.ProviderType) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { component -> String in
                let name = String(component)
                guard !name.isEmpty else { return name }
                return violation(name: name, provider: provider) == nil ? name : sanitized(name: name, for: provider)
            }
            .joined(separator: "/")
    }
}
