import Foundation

/// Lowercase hexadecimal for a run of bytes: the one spelling of it in this module. A table lookup
/// rather than `String(format: "%02x")`, which boxes and parses a format per byte, and a duplicates
/// scan renders tens of thousands of digests.
///
/// **The output must match `%02x` byte for byte.** These strings are persisted and compared across
/// runs (content-hash cache keys, filing profile ids, ``ItemIdentity`` tree digests), and one
/// differing character would silently miss every stored digest and re-hash everything.
/// ``HexEncodingTests`` pins all 256 byte values, since a table typo hits one nibble.
enum HexEncoding {
    /// The nibble table, as UTF-8 bytes so indexing is a byte load, not a grapheme.
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
