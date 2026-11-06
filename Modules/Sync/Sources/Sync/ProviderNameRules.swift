import Foundation

/// Pure rules for provider-hostile file names, shared by the diff engine and the transfer
/// pre-flight check, because both rest on the same character-level facts:
///
/// 1. Near-name matching (`nearNameKey`): two panes can hold the same item under names that differ
///    only invisibly (edge whitespace, trailing dots, NFC/NFD), because one provider normalizes
///    what another stores verbatim. Exact-path diffing would show two phantom "missing" rows whose
///    copies the stricter provider can never upload, so the diff pairs them into one
///    `.nameConflict`.
/// 2. Destination validity (`violation`/`sanitized`): a copy into a cloud folder checks the name
///    against that provider's rules first, so the app can offer a valid name instead of silently
///    creating an unsyncable item.
public enum ProviderNameRules {

    // MARK: - Near-name normalization (diff matching)

    /// One path component in the form a strict provider would store: NFC, edge whitespace and
    /// trailing dots stripped. A component that would vanish entirely keeps its NFC form, so `" "`
    /// and `"."` don't collapse to one empty key and pair unrelated names.
    public static func normalizedComponent(_ name: String) -> String {
        // Fast path for the common case: most real components are plain ASCII with nothing to
        // strip, and `nearNameKey` runs for every key of both sides before the diff starts.
        if hasNothingToNormalize(name) { return name }
        let precomposed = name.precomposedStringWithCanonicalMapping
        var trimmed = precomposed.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? precomposed : trimmed
    }

    /// True when `normalizedComponent` would return `name` unchanged, decided in one pass over the
    /// UTF-8 bytes. Conservative: any byte at or above 0x80 takes the slow path, since deciding NFC
    /// cheaply is the hard part. Wrong this way costs speed; wrong the other way would silently
    /// change a diff key.
    ///
    /// The checks mirror the transforms: ASCII can't change under NFC, no edge ASCII whitespace
    /// rules out the trims, and no trailing "." rules out the dot strip. An empty name returns
    /// as-is, as the slow path does.
    static func hasNothingToNormalize(_ name: String) -> Bool {
        let utf8 = name.utf8
        guard let first = utf8.first, let last = utf8.last else { return true }  // empty
        if isASCIIWhitespace(first) || isASCIIWhitespace(last) || last == UInt8(ascii: ".") { return false }
        for byte in utf8 where byte >= 0x80 { return false }
        return true
    }

    /// The ASCII members of `CharacterSet.whitespacesAndNewlines`, which the trims use. Pinned
    /// against Foundation's own set by
    /// `ProviderNameFastPathTests.asciiWhitespacePredicateMatchesFoundation`.
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// `lowercased()` for a string already known to be pure ASCII. The caller must guarantee that
    /// (see `nearNameKey`).
    static func asciiLowercased(_ s: String) -> String {
        var bytes = Array(s.utf8)
        var changed = false
        for i in bytes.indices where bytes[i] >= UInt8(ascii: "A") && bytes[i] <= UInt8(ascii: "Z") {
            bytes[i] |= 0x20
            changed = true
        }
        // An already-lowercase path keeps its storage instead of allocating a copy.
        return changed ? String(decoding: bytes, as: UTF8.self) : s
    }

    /// A relative path normalized per component (see `normalizedComponent`), case-folded when
    /// `foldCase` is true, which is exactly when the diff runs case-insensitively. The whole path
    /// is normalized, not just the leaf, so children of `Swimming ` and `Swimming` pair up too.
    public static func nearNameKey(forRelativePath path: String, foldCase: Bool) -> String {
        // Nothing to normalize: skip the split and rejoin, which would rebuild the same string and
        // cost about half this function's time.
        if pathHasNothingToNormalize(path) {
            // The predicate has proved the path ASCII, where `lowercased()` is just "map A-Z", so
            // one byte pass does it (pinned by
            // `ProviderNameFastPathTests.asciiLowercaseMatchesFoundationForEveryAsciiScalar`).
            // NEVER call it on a string that has not passed `pathHasNothingToNormalize`: Unicode
            // case folding is not byte-local (ẞ, İ, Σ), so it would silently change the key.
            return foldCase ? asciiLowercased(path) : path
        }
        // Split by scalar, as the byte pass reads it. A name can open with a combining mark or end
        // with a Prepend character, which joins the `/` beside it into one Character, so a split by
        // Character would merge two components.
        let normalized = path.unicodeScalars
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { normalizedComponent(String($0)) }
            .joined(separator: "/")
        return foldCase ? normalized.lowercased() : normalized
    }

    /// `hasNothingToNormalize` for every "/"-separated component of `path`, in one pass without
    /// splitting it. `ProviderNameFastPathTests.pathPredicateAgreesWithPerComponentPredicate`
    /// checks the two agree, including on empty components from a leading, trailing or doubled
    /// slash.
    static func pathHasNothingToNormalize(_ path: String) -> Bool {
        let slash = UInt8(ascii: "/")
        let dot = UInt8(ascii: ".")
        var lastByteOfComponent: UInt8?
        var atComponentStart = true
        for byte in path.utf8 {
            if byte >= 0x80 { return false }
            if byte == slash {
                // The component just ended: reject it if it closed on whitespace or a dot. A nil
                // here is an empty component, which normalizes to itself.
                if let last = lastByteOfComponent, isASCIIWhitespace(last) || last == dot { return false }
                atComponentStart = true
                lastByteOfComponent = nil
                continue
            }
            if atComponentStart {
                if isASCIIWhitespace(byte) { return false }
                atComponentStart = false
            }
            lastByteOfComponent = byte
        }
        if let last = lastByteOfComponent, isASCIIWhitespace(last) || last == dot { return false }
        return true
    }

    /// A phrase for how two leaf names differ invisibly, for `.nameConflict` descriptions. Checks
    /// the single-cause cases first so the message can name the culprit.
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
    /// difference has visible boundaries, and names the providers, which travel with their files
    /// through a pane swap, so the text stays true.
    public static func nameConflictDescription(
        leftName: String, leftProvider: String,
        rightName: String, rightProvider: String
    ) -> String {
        "Names differ by \(nameDifferenceDetail(leftName, rightName)): "
            + "“\(leftName)” (\(leftProvider)) vs “\(rightName)” (\(rightProvider))"
    }

    // MARK: - Destination validity (pre-write check)

    /// One provider-invalid path component: what it is, why it's invalid, and a valid replacement.
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
        // Only COM1–COM9 and LPT1–LPT9 are reserved; COM0/LPT0 are ordinary valid names.
        for i in 1...9 {
            names.insert("COM\(i)")
            names.insert("LPT\(i)")
        }
        return names
    }()

    /// Characters OneDrive forbids anywhere in a name ("/" can't occur in a single component).
    private static let oneDriveForbiddenCharacters = Set<Character>("\"*:<>?/\\|")

    /// Why `name` can't be stored by `provider`, or nil when it is acceptable. iCloud, Google Drive
    /// and a plain folder accept anything the local filesystem does. Whether a folder's names would
    /// survive OneDrive is asked a layer up: `CloudProvider.nameRuleType(for:folderRule:)` swaps
    /// the ruleset before calling this.
    public static func violation(name: String, provider: CloudProvider.ProviderType) -> Violation? {
        func make(_ reason: String) -> Violation {
            Violation(componentName: name, reason: reason, sanitizedName: sanitized(name: name, for: provider))
        }
        switch provider {
        case .iCloud, .googleDrive, .localFolder:
            return nil
        case .dropBox:
            if name.hasSuffix(" ") {
                return make("Dropbox doesn’t allow names ending with a space.")
            }
            if name.hasSuffix(".") {
                return make("Dropbox doesn’t allow names ending with a period.")
            }
            return nil
        case .oneDrive:
            if let forbidden = name.first(where: { oneDriveForbiddenCharacters.contains($0) }) {
                return make("OneDrive doesn’t allow “\(forbidden)” in names.")
            }
            if name.hasPrefix(" ") || name.hasSuffix(" ") {
                return make("OneDrive doesn’t allow names beginning or ending with a space.")
            }
            if name.hasSuffix(".") {
                return make("OneDrive doesn’t allow names ending with a period.")
            }
            // Split as `sanitized(...)` does (omittingEmptySubsequences: false), so ".CON" derives
            // an empty base, not "CON", and isn't flagged when the sanitizer would leave it alone.
            let baseName = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
            if oneDriveReservedNames.contains(baseName.uppercased()) {
                return make("“\(baseName)” is a reserved name on OneDrive.")
            }
            return nil
        }
    }

    /// The first provider-invalid component along `relativePath`, root outward, or nil. Every
    /// component is checked, because a copy that creates intermediate folders takes their names
    /// from the source, and an invalid ancestor is as unsyncable as an invalid leaf.
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
            let parts = result.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let baseName = String(parts.first ?? "")
            if oneDriveReservedNames.contains(baseName.uppercased()) {
                // Suffix the base, not the whole string: "CON.txt" becomes "CON-1.txt", while
                // "CON.txt-1" would still have the reserved base "CON".
                result = parts.count > 1 ? "\(baseName)-1.\(parts[1])" : "\(baseName)-1"
            }
        }
        return result
    }

    /// `relativePath` with every invalid component sanitized for `provider` (see
    /// `sanitized(name:for:)`). Valid components stay byte-identical, so an existing valid ancestor
    /// still addresses the same folder.
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
