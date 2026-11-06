import Foundation
import CryptoKit
import Testing
@testable import Sync

/// Pins ``HexEncoding/string(_:)`` to the `String(format: "%02x")` expression. The oracle is
/// spelled out longhand so the suite doesn't agree with itself. Exhaustive rather than sampled
/// because these strings are persisted as content-hash cache keys, filing profile identifiers and
/// ``ItemIdentity`` tree digests: a wrong nibble wouldn't raise, it would silently miss every
/// stored digest and re-hash everything, which looks like a slow scan, never a failure.
@Suite("Hex encoding matches the formatter it replaced")
struct HexEncodingTests {
    /// The independent oracle: the plain `%02x` formatter.
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

    /// What `%02x` emits, stated independently of both: lowercase, two per byte. Uppercase would
    /// still decode as hex but is wrong here, because stored digests are compared as strings.
    @Test("Output is lowercase and exactly two characters per byte")
    func shape() {
        let bytes: [UInt8] = [0x00, 0x0f, 0x10, 0xa5, 0xff]
        let hex = HexEncoding.string(bytes)
        #expect(hex == "000f10a5ff")
        #expect(hex.count == bytes.count * 2)
        #expect(hex == hex.lowercased())
    }
}
