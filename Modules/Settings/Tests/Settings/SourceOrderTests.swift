import Testing
import Foundation
@testable import Settings
import Sync

/// The user's own source order, which the Browse sidebar drags and everything else reads. One
/// order, not a sidebar-local one: a sidebar and a pane-header dropdown listing the same accounts
/// in two sequences make a user distrust both.
@Suite struct SourceOrderTests {

    private func provider(_ id: String, _ name: String) -> CloudProvider {
        CloudProvider(id: id, displayName: name, imageName: "", rootPath: "/x/\(id)", type: .iCloud)
    }

    private var discovered: [CloudProvider] {
        [provider("icloud", "iCloud Drive"), provider("dropbox", "Dropbox"),
         provider("drive-emp", "Drive"), provider("onedrive", "OneDrive")]
    }

    /// The stored order wins; ids it names that are gone are ignored, and a duplicated id keeps
    /// its first place, so nothing leaves a hole or drops a provider.
    @Test(arguments: [
        // No stored order (every install before the first drag) is discovery order, untouched,
        // which makes the feature safe without a migration or a seed.
        ([], ["icloud", "dropbox", "drive-emp", "onedrive"]),
        (["onedrive", "drive-emp", "dropbox", "icloud"], ["onedrive", "drive-emp", "dropbox", "icloud"]),
        // A newly connected account appends rather than jumping to the front, where a user would
        // least expect it. Fails if unranked ids get a default rank of 0.
        (["onedrive", "icloud"], ["onedrive", "icloud", "dropbox", "drive-emp"]),
        (["ghost", "dropbox"], ["dropbox", "icloud", "drive-emp", "onedrive"]),
        (["dropbox", "dropbox", "icloud"], ["dropbox", "icloud", "drive-emp", "onedrive"]),
        // The sequence it already has changes nothing, so `discoverProviders`' no-op guard
        // publishes nothing.
        (["icloud", "dropbox", "drive-emp", "onedrive"], ["icloud", "dropbox", "drive-emp", "onedrive"]),
    ] as [([String], [String])])
    func theOrderIsApplied(_ order: [String], _ expected: [String]) {
        #expect(SettingsManager.inUserOrder(discovered, order: order).map(\.id) == expected)
    }

    /// The unnamed tail keeps a stable order between launches. Swift's sort is not stable, so a
    /// single `sorted(by:)` over an optional rank would let the newest accounts shuffle.
    @Test func theUnnamedTailDoesNotShuffleBetweenRuns() {
        let answers = Set((0..<40).map { _ in
            SettingsManager.inUserOrder(discovered, order: ["onedrive"]).map(\.id).joined(separator: ">")
        })
        #expect(answers == ["onedrive>icloud>dropbox>drive-emp"],
                "the unnamed tail varies between runs: \(answers)")
    }

    /// Ordering is a permutation: nothing is added, nothing is lost, whatever the stored order says.
    @Test func orderingNeverAddsOrLosesASource() {
        for order in [[], ["icloud"], ["ghost"], ["onedrive", "ghost", "icloud"],
                      discovered.map(\.id).reversed()] as [[String]] {
            let out = SettingsManager.inUserOrder(discovered, order: order)
            #expect(Set(out.map(\.id)) == Set(discovered.map(\.id)),
                    "order \(order) changed the set of sources")
            #expect(out.count == discovered.count, "order \(order) changed the count")
        }
    }
}
