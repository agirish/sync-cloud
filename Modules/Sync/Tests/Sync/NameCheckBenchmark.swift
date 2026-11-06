import Foundation
import Testing
@testable import Sync

/// Prices one name check, `NameNormalizer.risky`, against the real names on this machine.
///
/// The row badge runs it per visible row, not per scan, so the number that matters is what one
/// name costs, and what the same name costs the second time. Inert unless
/// `SYNCCLOUD_NAME_BENCHMARK` names the roots to walk (colon-separated, tilde allowed), so an
/// ordinary `swift test` and CI never run it:
///
/// ```sh
/// SYNCCLOUD_NAME_BENCHMARK="~/Documents:~/Library/CloudStorage/OneDrive-Personal" \
///   arch -arm64 swift test -c release --filter NameCheckBenchmark
/// ```
///
/// Every figure is per-name nanoseconds over the same name list, so the three columns compare
/// directly: the live check, the memoized check on a cold table (every name a miss plus an
/// insert), and the memoized check on a warm one (what a re-render pays).
@Suite(.serialized) struct NameCheckBenchmark {

    private static var roots: [URL] {
        guard let raw = ProcessInfo.processInfo.environment["SYNCCLOUD_NAME_BENCHMARK"], !raw.isEmpty else { return [] }
        return raw.split(separator: ":").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
    }

    /// Every leaf name under `root`, in walk order. Duplicates are kept: the repetition is what a
    /// memo exploits, and averaging it away would flatter the cache.
    private static func names(under root: URL) -> [String] {
        var out: [String] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in e {
            out.append(url.lastPathComponent)
            if out.count >= 60_000 { break }
        }
        return out
    }

    /// The same names as native Swift strings. `URL.lastPathComponent` returns a string lazily
    /// bridged from `NSString`, whose hashes and comparisons take the ObjC slow path, so keeping
    /// them would measure Foundation's bridge as much as the rules. Round-tripping the UTF-8 forces
    /// native storage.
    private static func nativized(_ names: [String]) -> [String] {
        names.map { String(decoding: Array($0.utf8), as: UTF8.self) }
    }

    private static func ns(_ count: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(max(count, 1))
    }

    @Test func priceOneNameCheck() {
        let roots = Self.roots
        guard !roots.isEmpty else { return }
        let providers: [CloudProvider.ProviderType] = [.oneDrive, .iCloud]

        for root in roots {
            let bridged = Self.names(under: root)
            guard !bridged.isEmpty else { continue }
            print("BENCH root \(root.lastPathComponent): \(bridged.count) names, \(Set(bridged).count) distinct")

            for (storage, names) in [("bridged", bridged), ("native", Self.nativized(bridged))] {
            for provider in providers {
                // Warm the allocator and the ICU tables so the first provider isn't charged for
                // both: the comparison is between strategies, not iterations.
                for name in names.prefix(200) {
                    _ = NameNormalizer.risky(name: name, relativePath: name, absolutePath: name,
                                             isDirectory: false, provider: provider)
                }

                var sink = 0
                let live = Self.ns(names.count) {
                    for name in names {
                        if NameNormalizer.risky(name: name, relativePath: name, absolutePath: name,
                                                isDirectory: false, provider: provider) != nil { sink += 1 }
                    }
                }

                var memo: [String: Bool] = [:]
                let cold = Self.ns(names.count) {
                    for name in names {
                        if let hit = memo[name] { if hit { sink += 1 }; continue }
                        let risky = NameNormalizer.risky(name: name, relativePath: name, absolutePath: name,
                                                         isDirectory: false, provider: provider) != nil
                        memo[name] = risky
                        if risky { sink += 1 }
                    }
                }
                let warm = Self.ns(names.count) {
                    for name in names where memo[name] == true { sink += 1 }
                }

                print(String(format: "BENCH %@ %@ %@: live %.0f ns/name · memo cold %.0f · memo warm %.0f · risky %d (sink %d)",
                             root.lastPathComponent, storage, provider.rawValue, live, cold, warm,
                             memo.values.filter { $0 }.count, sink))
            }
            }
        }
    }
}
