import Testing
import Foundation
@testable import Settings
import Sync

/// **The user's own source order**, which the Browse sidebar drags and everything else reads.
///
/// One order rather than a sidebar-local one: a sidebar and a pane-header dropdown showing the same
/// eleven accounts in two different sequences is the drift that makes a user distrust both.
@Suite struct SourceOrderTests {

    private func provider(_ id: String, _ name: String) -> CloudProvider {
        CloudProvider(id: id, displayName: name, imageName: "", rootPath: "/x/\(id)", type: .iCloud)
    }

    private var discovered: [CloudProvider] {
        [provider("icloud", "iCloud Drive"), provider("dropbox", "Dropbox"),
         provider("drive-hpe", "Drive"), provider("onedrive", "OneDrive")]
    }

    /// No stored order — every install before the first drag — is discovery order, untouched.
    /// This is what makes the feature safe without a migration or a seed.
    @Test func anEmptyOrderLeavesDiscoveryOrderAlone() {
        #expect(SettingsManager.inUserOrder(discovered, order: []).map(\.id)
                == ["icloud", "dropbox", "drive-hpe", "onedrive"])
    }

    @Test func theStoredOrderWins() {
        let out = SettingsManager.inUserOrder(
            discovered, order: ["onedrive", "drive-hpe", "dropbox", "icloud"])
        #expect(out.map(\.id) == ["onedrive", "drive-hpe", "dropbox", "icloud"])
    }

    /// **A newly connected account appends** rather than jumping to the front. A sort that gave
    /// unranked ids a default rank of 0 would put every new account at the top, which is where a
    /// user would least expect a source they did not add on purpose.
    @Test func anAccountTheOrderHasNeverSeenGoesToTheEnd() {
        let out = SettingsManager.inUserOrder(discovered, order: ["onedrive", "icloud"])
        #expect(out.map(\.id) == ["onedrive", "icloud", "dropbox", "drive-hpe"])
    }

    /// An id naming a source that is gone — an account signed out, a folder source removed — is
    /// ignored rather than leaving a hole.
    @Test func aStaleIdInTheOrderIsIgnored() {
        let out = SettingsManager.inUserOrder(discovered, order: ["ghost", "dropbox"])
        #expect(out.map(\.id) == ["dropbox", "icloud", "drive-hpe", "onedrive"])
    }

    /// **The unnamed tail keeps a stable order between launches.** Swift's sort is not stable, so a
    /// single `sorted(by:)` over an optional rank would let the newest accounts shuffle on every
    /// launch — invisible in one run and obvious over a week.
    @Test func theUnnamedTailDoesNotShuffleBetweenRuns() {
        let answers = Set((0..<40).map { _ in
            SettingsManager.inUserOrder(discovered, order: ["onedrive"]).map(\.id).joined(separator: ">")
        })
        #expect(answers == ["onedrive>icloud>dropbox>drive-hpe"],
                "the unnamed tail varies between runs: \(answers)")
    }

    /// A duplicated id does not drop a provider or crash: first occurrence wins, which is the only
    /// answer that keeps the output the same length as the input.
    @Test func aDuplicatedIdIsTolerated() {
        let out = SettingsManager.inUserOrder(discovered, order: ["dropbox", "dropbox", "icloud"])
        #expect(out.map(\.id) == ["dropbox", "icloud", "drive-hpe", "onedrive"])
        #expect(out.count == discovered.count)
    }

    /// An order naming every id in the list it already has changes nothing — the case that must not
    /// trigger a publish, since re-rendering every observer for no change is what the no-op guard
    /// in `discoverProviders` exists to prevent.
    @Test func anOrderMatchingTheCurrentSequenceIsTheIdentity() {
        let out = SettingsManager.inUserOrder(discovered, order: discovered.map(\.id))
        #expect(out.map(\.id) == discovered.map(\.id))
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
