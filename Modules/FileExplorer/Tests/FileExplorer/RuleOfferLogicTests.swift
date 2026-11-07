import Testing
import Foundation
@testable import FileExplorer

/// Pins ``RuleOfferLogic/relativeToProviderRoot(_:providerRoot:)``. The learned rule's destination
/// template is derived from it, so a drift here re-points what users teach.
@Suite struct RuleOfferLogicTests {

    /// Inside the root, the relative path; the root itself, empty; outside it, or with no root,
    /// the leaf name. Paths are standardized before comparing.
    @Test(arguments: [
        ("/p/Docs/Invoices", "/p", "Docs/Invoices"),
        ("/p", "/p", ""),
        ("/elsewhere/Docs/Tax", "/p", "Tax"),
        // A sibling sharing the root as a prefix string is still outside it.
        ("/provider2/Docs", "/p", "Docs"),
        ("/p/Docs/Invoices", nil, "Invoices"),
        ("/p/Docs/Invoices", "", "Invoices"),
        ("/p/./Docs//Invoices", "/p/", "Docs/Invoices"),
    ] as [(String, String?, String)])
    func relativeToTheProviderRoot(path: String, root: String?, expected: String) {
        #expect(RuleOfferLogic.relativeToProviderRoot(path, providerRoot: root) == expected)
    }
}
