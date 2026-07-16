import Testing
import Foundation
@testable import FileExplorer

/// Pins ``RuleOfferLogic/relativeToProviderRoot(_:providerRoot:)`` across its extraction from
/// TidyView (where it was an instance method reading `automationDestinationRoot`). The learned
/// rule's destination template is derived from this, so a drift here re-points what users teach.
@Suite struct RuleOfferLogicTests {

    @Test func insideTheRootYieldsTheRelativePath() {
        #expect(RuleOfferLogic.relativeToProviderRoot("/p/Docs/Invoices", providerRoot: "/p")
                == "Docs/Invoices")
    }

    @Test func theRootItselfYieldsEmpty() {
        #expect(RuleOfferLogic.relativeToProviderRoot("/p", providerRoot: "/p") == "")
    }

    @Test func outsideTheRootFallsBackToTheLeafName() {
        #expect(RuleOfferLogic.relativeToProviderRoot("/elsewhere/Docs/Tax", providerRoot: "/p") == "Tax")
        // A sibling sharing the root as a PREFIX string is still outside it.
        #expect(RuleOfferLogic.relativeToProviderRoot("/provider2/Docs", providerRoot: "/p") == "Docs")
    }

    @Test func missingOrEmptyRootFallsBackToTheLeafName() {
        #expect(RuleOfferLogic.relativeToProviderRoot("/p/Docs/Invoices", providerRoot: nil) == "Invoices")
        #expect(RuleOfferLogic.relativeToProviderRoot("/p/Docs/Invoices", providerRoot: "") == "Invoices")
    }

    @Test func pathsAreStandardizedBeforeComparing() {
        #expect(RuleOfferLogic.relativeToProviderRoot("/p/./Docs//Invoices", providerRoot: "/p/")
                == "Docs/Invoices")
    }
}
