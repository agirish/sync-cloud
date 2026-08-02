import Foundation

/// Decides which scalars of a risky name get a visible marker, so a view can draw a trailing space
/// or a hidden joiner as something the eye can land on. Kept out of any view body so "which scalars
/// are marked" — the feature itself — is testable without rendering anything.
///
/// **Why it lives in Sync rather than beside a view.** Two surfaces now render kept/risky names and
/// they are in different modules: the Rename lens's card (FileExplorer) and the kept-names list in
/// Settings ▸ Organize. Both are showing a name *because* something in it is invisible, so both have
/// to mark the same scalars — a name that draws two markers in one place and one in the other is
/// worse than either answer alone. Co-locating it with ``NameNormalizer`` also lets the two share
/// one zero-width set instead of the view keeping a mirrored copy that could drift.
///
/// The glyphs and their tint are the caller's business; this type only says *what* to substitute.
public enum InvisibleNameMarking {
    /// One rendered cell: the glyph to draw, and whether it is a substituted marker (which the
    /// caller tints) rather than the name's own character.
    public struct Cell: Equatable, Sendable {
        public let glyph: String
        public let isMarker: Bool
    }

    public static func cells(for name: String) -> [Cell] {
        let scalars = Array(name.unicodeScalars)
        let edges = edgeWhitespaceIndices(scalars)
        return scalars.indices.map { idx in
            let scalar = scalars[idx]
            // Zero-width / BOM scalars are invisible and NOT classed as whitespace, so they get an
            // explicit marker wherever they sit. Read from `NameNormalizer` rather than restated:
            // the set that decides a name is risky is the set that has to be made visible.
            if NameNormalizer.zeroWidthScalars.contains(scalar) {
                return Cell(glyph: "◌", isMarker: true)
            } else if scalar == " " {
                // An interior space is already visible by the text either side of it; only the
                // affix ones are the invisible surprise.
                return edges.contains(idx) ? Cell(glyph: "␣", isMarker: true) : Cell(glyph: " ", isMarker: false)
            } else if scalar.properties.isWhitespace {
                // No-break space, tab, other Unicode spaces — always suspicious in a name.
                return Cell(glyph: "␣", isMarker: true)
            } else {
                return Cell(glyph: String(scalar), isMarker: false)
            }
        }
    }

    /// Every index in the leading and trailing whitespace RUNS.
    ///
    /// Deliberately the whole run, not `idx == 0 || idx == count - 1`: "Swimming  " ends in two
    /// spaces, and marking only the outermost one drew a single "␣" followed by a space that was
    /// still invisible — so the name read as having one trailing space when it has two, in the one
    /// view whose whole job is making exactly that risk visible. Matches
    /// `NameDisplay.visibleName(_:)`, which already walks the full run for the same reason.
    private static func edgeWhitespaceIndices(_ scalars: [Unicode.Scalar]) -> Set<Int> {
        var indices: Set<Int> = []
        var index = 0
        while index < scalars.count, scalars[index].properties.isWhitespace {
            indices.insert(index)
            index += 1
        }
        index = scalars.count - 1
        while index >= 0, scalars[index].properties.isWhitespace {
            indices.insert(index)
            index -= 1
        }
        return indices
    }
}
