import AppKit
import SwiftUI
import Testing
import Design
import Sync
@testable import FileExplorer

/// Restructure **past its launch gate** — the half of this lens no test had ever drawn.
///
/// `hasReviewed` decides between the setup card and the answer, and every call site in the suite
/// built it `false`: the findings list, the clean state and the ancestor section had no coverage of
/// any kind, so `body`'s three other branches could be deleted without a single failure. The flag is
/// deliberately un-defaulted precisely so a call site cannot switch the gate off by forgetting it —
/// which made the tests all passing `false` the one way that guard could still be circumvented.
@MainActor
@Suite(.serialized) struct RestructureLensReviewedTests {

    /// The gate switches something. With the same findings behind it, opened and not-yet-opened
    /// must not paint the same lens.
    @Test func theGateSwapsTheCardForTheAnswer() throws {
        let card = try Self.rendered(hasReviewed: false, findings: [Self.finding()])
        let answer = try Self.rendered(hasReviewed: true, findings: [Self.finding()])
        let differing = Self.differingPixels(card, answer)
        #expect(Double(differing) > Double(card.pixelsWide * card.pixelsHigh) * 0.05,
                "\(differing) pixels separate the setup card from the revealed answer — the launch gate is drawing the same thing either side of itself")
    }

    /// A tree that agrees with itself says so. Without this the empty case is indistinguishable
    /// from a lens that revealed an answer and drew nothing.
    @Test func aCleanTreeGetsASentenceRatherThanAnEmptyList() throws {
        let clean = try Self.rendered(hasReviewed: true, findings: [])
        let answer = try Self.rendered(hasReviewed: true, findings: [Self.finding()])

        #expect(Self.ink(clean) > 200, "the clean state paints almost nothing — the lens reveals a blank pane")
        #expect(Self.differingPixels(clean, answer) > 0, "a clean tree and a tree with findings draw identically")

        // And the words, which no render can read back here: the claim is about the whole tree only
        // when the lens is looking at the whole tree.
        #expect(RestructureLens.cleanTitle(isScoped: false) == "The tree agrees with itself")
        #expect(RestructureLens.cleanTitle(isScoped: true) == "This folder agrees with itself")
        #expect(RestructureLens.cleanMessage(folderCount: 3_013).hasPrefix("Checked 3,013 folders."))
        #expect(!RestructureLens.cleanMessage(folderCount: nil).contains("Checked"),
                "a lens with no folder count invented one")
    }

    /// **Findings about the folder above are not emptiness.** `isEmpty` is both lists, so a scope
    /// with nothing inside it but something above still opens the answer rather than the clean
    /// state — which is the case the ancestor section exists for and the one most likely to be
    /// broken by a later "simplify this to `findings.isEmpty`".
    @Test func ancestorOnlyFindingsAreAnAnswerNotACleanTree() throws {
        let ancestorOnly = try Self.rendered(hasReviewed: true, findings: [], ancestor: [Self.finding()])
        let clean = try Self.rendered(hasReviewed: true, findings: [])

        #expect(Self.ink(ancestorOnly) > Self.ink(clean),
                "a scope whose only findings are about the folder above drew the clean state — the lens says the tree agrees when it has something to show")
    }

    /// And it says which folder it is talking about. Opening straight onto findings about a
    /// *different* folder reads as the lens having answered the question it was asked.
    @Test func theAncestorSectionSaysWhoseFindingsTheseAre() {
        #expect(RestructureLens.ancestorHeading(hasFindingsHere: false)
                == "Nothing about this folder itself — but about the folder above it:")
        #expect(RestructureLens.ancestorHeading(hasFindingsHere: true)
                == "About the folder above this one:")
        #expect(RestructureLens.ancestorHeading(hasFindingsHere: false)
                != RestructureLens.ancestorHeading(hasFindingsHere: true),
                "the heading reads the same whether or not the scope had findings of its own")
    }

    // MARK: - Fixtures

    static func finding(family: String = "Family/Aditi/Events") -> StructureFinding {
        StructureFinding(family: family, schemes: [
            .init(vocabulary: ["Photos", "Invitations"], members: ["Naming Ceremony", "Birthday"]),
            .init(vocabulary: [], members: ["Graduation"]),
        ])
    }

    private static func rendered(hasReviewed: Bool,
                                 findings: [StructureFinding],
                                 ancestor: [StructureFinding] = []) throws -> NSBitmapImageRep {
        let size = CGSize(width: 420, height: 320)
        let host = NSHostingView(rootView: AnyView(
            RestructureLens(findings: findings, aboutAncestor: ancestor, hasProfile: true,
                            folderCount: 3_013, providerName: "iCloud", accent: .blue,
                            onReveal: { _ in }, hasReviewed: hasReviewed, onReview: {},
                            onUpdateSurvey: {})
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        ))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func ink(_ rep: NSBitmapImageRep) -> Int {
        var hits = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if px.redComponent < 0.72 || px.greenComponent < 0.72 || px.blueComponent < 0.72 { hits += 1 }
            }
        }
        return hits
    }

    private static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                guard let pa = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let pb = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = abs(pa.redComponent - pb.redComponent)
                    + abs(pa.greenComponent - pb.greenComponent)
                    + abs(pa.blueComponent - pb.blueComponent)
                if d > 0.05 { differing += 1 }
            }
        }
        return differing
    }
}
