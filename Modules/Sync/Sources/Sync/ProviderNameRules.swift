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
        // Overwhelmingly the common case, and it used to cost the same as the rare one: on the
        // two real pane roots 673,925 of 719,361 path components (94%) are plain ASCII with no
        // edge whitespace and no trailing dot, so every step below is a no-op for them — yet
        // each still paid a full NFC transform plus two CharacterSet trims. `nearNameKey` is
        // called for every key of both sides at scan setup, so that cost is multiplied by tens
        // of thousands before the diff's first pass starts.
        if hasNothingToNormalize(name) { return name }
        let precomposed = name.precomposedStringWithCanonicalMapping
        var trimmed = precomposed.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? precomposed : trimmed
    }

    /// True when `normalizedComponent` would return `name` unchanged, decided in one pass over
    /// the UTF-8 bytes.
    ///
    /// Deliberately conservative — it answers "is this definitely a no-op", never "is this
    /// equivalent". Any byte at or above 0x80 sends the name down the slow path even though most
    /// non-ASCII names are already NFC, because deciding NFC-ness cheaply is exactly the problem
    /// `precomposedStringWithCanonicalMapping` exists to solve. Being wrong in this direction
    /// costs a little speed; being wrong in the other would silently change a diff key.
    ///
    /// The three conditions mirror the three transforms: ASCII rules out NFC changing anything
    /// (no ASCII scalar has a canonical decomposition or composition), no leading/trailing ASCII
    /// whitespace rules out both trims, and no trailing "." rules out the dot strip. Interior
    /// whitespace and interior dots are untouched by all three, so they stay on the fast path.
    /// An empty name qualifies and is returned as-is, which is what the slow path does with it
    /// (`trimmed.isEmpty` hands back the equally empty `precomposed`).
    static func hasNothingToNormalize(_ name: String) -> Bool {
        let utf8 = name.utf8
        guard let first = utf8.first, let last = utf8.last else { return true }  // empty
        if isASCIIWhitespace(first) || isASCIIWhitespace(last) || last == UInt8(ascii: ".") { return false }
        for byte in utf8 where byte >= 0x80 { return false }
        return true
    }

    /// The ASCII members of `CharacterSet.whitespacesAndNewlines`, which is what the trims above
    /// use. Pinned by `ProviderNameFastPathTests.asciiWhitespacePredicateMatchesFoundation`,
    /// which walks all 128 ASCII scalars and compares this against Foundation's own set rather
    /// than trusting the list to be remembered correctly.
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// `lowercased()` for a string already known to be pure ASCII. Caller must guarantee that —
    /// see the call site in `nearNameKey`.
    static func asciiLowercased(_ s: String) -> String {
        var bytes = Array(s.utf8)
        var changed = false
        for i in bytes.indices where bytes[i] >= UInt8(ascii: "A") && bytes[i] <= UInt8(ascii: "Z") {
            bytes[i] |= 0x20
            changed = true
        }
        // An already-lowercase path — the common case — keeps its existing storage instead of
        // allocating an identical copy.
        return changed ? String(decoding: bytes, as: UTF8.self) : s
    }

    /// A relative path normalized per component (see `normalizedComponent`), optionally
    /// case-folded — pass `foldCase: true` exactly when the diff runs case-insensitively,
    /// so a pair differing by case AND whitespace still meets on one key. Normalizing the
    /// FULL path (not just the leaf) also matches descendants of folders whose names differ
    /// only invisibly, so identical children under `Swimming ` and `Swimming` pair up
    /// instead of double-reporting.
    public static func nearNameKey(forRelativePath path: String, foldCase: Bool) -> String {
        // When no component would change, the split/map/join below reassembles the string it
        // started with — so skip it and keep the original. This is worth more than the
        // per-component fast path it builds on: the allocation of a component array and a
        // rejoined string, per key, was about half of what this function cost.
        if pathHasNothingToNormalize(path) {
            // That predicate has already established the whole path is ASCII, and over ASCII
            // `lowercased()` is exactly "map A-Z, leave the rest" — so it can be done in one
            // byte pass instead of going through the full Unicode case mapping. Pinned by
            // `ProviderNameFastPathTests.asciiLowercaseMatchesFoundationForEveryAsciiScalar`,
            // which checks all 128 against `lowercased()`. NEVER call this on a string that has
            // not been through `pathHasNothingToNormalize`: Unicode case folding is not
            // byte-local (ẞ, İ, Σ), so on non-ASCII it would silently produce a different key.
            return foldCase ? asciiLowercased(path) : path
        }
        let normalized = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { normalizedComponent(String($0)) }
            .joined(separator: "/")
        return foldCase ? normalized.lowercased() : normalized
    }

    /// `hasNothingToNormalize` for every "/"-separated component of `path`, in one pass and
    /// without splitting it. Kept honest by
    /// `ProviderNameFastPathTests.pathPredicateAgreesWithPerComponentPredicate`, which asserts
    /// the two agree — including on the empty components that `omittingEmptySubsequences: false`
    /// preserves for a leading, trailing, or doubled slash.
    static func pathHasNothingToNormalize(_ path: String) -> Bool {
        let slash = UInt8(ascii: "/")
        let dot = UInt8(ascii: ".")
        var lastByteOfComponent: UInt8?
        var atComponentStart = true
        for byte in path.utf8 {
            if byte >= 0x80 { return false }
            if byte == slash {
                // The component just ended: reject it if it closed on whitespace or a dot. A nil
                // here is an EMPTY component, which normalizes to itself and is therefore fine.
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
    /// and a plain folder accept anything the local filesystem does, so they never report one.
    ///
    /// A folder source belongs in that branch on the merits — a local volume accepts what a local
    /// volume accepts — and the question users actually want asked of a folder ("would this survive
    /// being put on OneDrive?") is answered a layer up, by `CloudProvider.nameRuleType(for:
    /// folderRule:)`, which substitutes the ruleset before this is ever called. Keeping the
    /// substitution out of here leaves this function answering only what it claims to.
    public static func violation(name: String, provider: CloudProvider.ProviderType) -> Violation? {
        func make(_ reason: String) -> Violation {
            Violation(componentName: name, reason: reason, sanitizedName: sanitized(name: name, for: provider))
        }
        switch provider {
        case .iCloud, .googleDrive, .localFolder:
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
            // Match `sanitized(...)`'s split exactly (omittingEmptySubsequences: false), so a
            // leading-dot name like ".CON" derives an empty base — not "CON" — and isn't
            // flagged as reserved when the sanitizer would leave it unchanged anyway.
            let baseName = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
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
            let parts = result.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let baseName = String(parts.first ?? "")
            if oneDriveReservedNames.contains(baseName.uppercased()) {
                // Suffix the BASE component, not the whole string: "CON.txt" must become
                // "CON-1.txt" — appending to the end ("CON.txt-1") leaves the base "CON" reserved,
                // so the sanitized name is still one OneDrive can't store.
                result = parts.count > 1 ? "\(baseName)-1.\(parts[1])" : "\(baseName)-1"
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
