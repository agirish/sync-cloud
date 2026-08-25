import Foundation

/// Lowercase hexadecimal for a run of bytes — the one spelling of it in this module.
///
/// Every digest here used to be rendered with `digest.map { String(format: "%02x", $0) }.joined()`,
/// which pays CVarArg boxing plus an NSString format parse **per byte**. A duplicates scan hashes
/// tens of thousands of files at 32 bytes each, so that is hundreds of thousands of formatter
/// round-trips per scan for what is two array lookups and two appends.
///
/// **The output is byte-for-byte what `%02x` produced, and it has to be.** These strings are
/// persisted and compared across runs — content-hash cache keys, filing profile identifiers,
/// ``ItemIdentity`` tree digests. One character's difference would fail nothing and raise nothing:
/// it would silently miss every stored digest and re-hash the world, which reads as "cold cache"
/// rather than as a bug. ``HexEncodingTests`` therefore pins the equivalence over **all 256** byte
/// values and over whole digests, not over a sample — a table typo lands on one nibble, and a
/// sample is exactly what steps over it.
enum HexEncoding {
    /// The nibble table. `Array("...".utf8)` rather than a `[Character]` so indexing is a byte
    /// load, not a grapheme.
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    /// Lowercase hex, two characters per byte, in sequence order.
    static func string<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
