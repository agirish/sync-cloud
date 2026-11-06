import Foundation

/// Decides which scalars of a risky name get a visible marker, so a view can draw a trailing space
/// or a hidden joiner as something the eye can land on. Out of any view body, so it tests without
/// rendering.
///
/// In Sync because two modules render these names (the Rename lens card in FileExplorer, and
/// Settings ▸ Organize's kept-names list) and both must mark the same scalars. Beside
/// ``NameNormalizer``, it shares that type's zero-width set. It picks the marker glyphs; the caller
/// tints them.
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
            // Zero-width and BOM scalars are invisible and not whitespace, so they get a marker
            // wherever they sit. From `NameNormalizer`, so what makes a name risky is what's shown.
            if NameNormalizer.zeroWidthScalars.contains(scalar) {
                return Cell(glyph: "◌", isMarker: true)
            } else if scalar == " " {
                // An interior space shows by the text either side; only leading and trailing ones
                // are invisible.
                return edges.contains(idx) ? Cell(glyph: "␣", isMarker: true) : Cell(glyph: " ", isMarker: false)
            } else if scalar.properties.isWhitespace {
                // No-break space, tab, other Unicode spaces: always suspicious in a name.
                return Cell(glyph: "␣", isMarker: true)
            } else {
                return Cell(glyph: String(scalar), isMarker: false)
            }
        }
    }

    /// Every index in the leading and trailing whitespace runs. The whole run, not just the outermost
    /// scalar, or "Swimming  " would show one marker and still hide a space. Matches
    /// `NameDisplay.visibleName(_:)`.
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
