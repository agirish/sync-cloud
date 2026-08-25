import Foundation
import CryptoKit
import Testing
@testable import Sync

/// Pins ``HexEncoding/string(_:)`` to the `String(format: "%02x")` expression it replaced.
///
/// **The oracle is spelled out longhand on purpose.** Every other `%02x` in the module now calls
/// the helper, so the only way to prove the helper is right is to keep one independent copy of the
/// thing it replaced and compare against it. Sharing the implementation here would make the suite
/// agree with itself.
///
/// The stakes are why this is exhaustive rather than sampled: these strings are persisted as
/// content-hash cache keys, filing profile identifiers and ``ItemIdentity`` tree digests, and a
/// wrong nibble would not raise — it would silently miss every stored digest and re-hash the world,
/// which presents as a slow scan and never as a failure.
@Suite("Hex encoding matches the formatter it replaced")
struct HexEncodingTests {
    /// The expression that used to live at every digest site.
    private func formatted<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Every one of the 256 byte values encodes identically")
    func allByteValues() {
        for value in UInt8.min...UInt8.max {
            #expect(HexEncoding.string([value]) == formatted([value]),
                    "byte \(value) disagreed")
        }
    }

    @Test("A whole SHA-256 digest encodes identically")
    func wholeDigest() {
        for seed in 0..<64 {
            let digest = SHA256.hash(data: Data("sample-\(seed)".utf8))
            #expect(HexEncoding.string(digest) == formatted(digest))
        }
    }

    @Test("A digest prefix encodes identically — the shape the profile and memory hashes use")
    func digestPrefix() {
        let digest = SHA256.hash(data: Data("prefix-case".utf8))
        #expect(HexEncoding.string(digest.prefix(8)) == formatted(digest.prefix(8)))
        #expect(HexEncoding.string(digest.prefix(8)).count == 16)
    }

    @Test("An empty run encodes to an empty string, not to a crash")
    func emptyRun() {
        #expect(HexEncoding.string([UInt8]()) == "")
    }

    /// The characters `%02x` emits, stated independently of both implementations: lowercase, and
    /// always two per byte. A table that swapped in uppercase would still round-trip through any
    /// hex DEcoder and would still be wrong here, because the persisted comparison is on the string.
    @Test("Output is lowercase and exactly two characters per byte")
    func shape() {
        let bytes: [UInt8] = [0x00, 0x0f, 0x10, 0xa5, 0xff]
        let hex = HexEncoding.string(bytes)
        #expect(hex == "000f10a5ff")
        #expect(hex.count == bytes.count * 2)
        #expect(hex == hex.lowercased())
    }
}
