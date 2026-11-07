import AppKit
import SwiftUI
import Testing
import Design
import Sync
@testable import FileExplorer

/// Restructure past its launch gate. `hasReviewed` decides between the setup card and the answer;
/// these draw the other side (the findings list, the clean state and the ancestor section), so
/// deleting any of `body`'s branches fails here. The flag is un-defaulted so a call site can't
/// switch the gate off by forgetting it.
@MainActor
@Suite(.serialized) struct RestructureLensReviewedTests {

    /// The gate switches something: with the same findings, opened and not yet opened must not
    /// paint the same lens.
    @Test(.machinePinned(.pixelSampling)) func theGateSwapsTheCardForTheAnswer() throws {
        let card = try Self.rendered(hasReviewed: false, findings: [Self.finding()])
        let answer = try Self.rendered(hasReviewed: true, findings: [Self.finding()])
        let differing = Self.differingPixels(card, answer)
        #expect(Double(differing) > Double(card.pixelsWide * card.pixelsHigh) * 0.05,
                "\(differing) pixels separate the setup card from the revealed answer — the launch gate is drawing the same thing either side of itself")
    }

    /// A tree that agrees with itself says so, or the empty case looks like a lens that revealed an
    /// answer and drew nothing.
    @Test(.machinePinned(.pixelSampling)) func aCleanTreeGetsASentenceRatherThanAnEmptyList() throws {
        let clean = try Self.rendered(hasReviewed: true, findings: [])
        let answer = try Self.rendered(hasReviewed: true, findings: [Self.finding()])

        // An ink count can't tell these apart: the clean state and the findings list ink within 2%
        // of each other, since a sentence with an icon and a two-row card cover similar area.
        // `differingPixels` separates them at about 15%.
        #expect(Self.ink(clean) > 200, "the clean state paints almost nothing — the lens reveals a blank pane")
        let differing = Self.differingPixels(clean, answer)
        let canvas = clean.pixelsWide * clean.pixelsHigh
        #expect(Double(differing) > Double(canvas) * 0.05,
                "\(differing) of \(canvas) pixels separate a clean tree from one with findings — the two states are drawing the same thing")
        // The words, which no render can read back, are `OrganizeScopeUnknownCountsTests`'.
    }

    /// Findings about the folder above are not emptiness. `isEmpty` covers both lists, so a scope
    /// with nothing inside but something above opens the answer, not the clean state; simplifying
    /// it to `findings.isEmpty` would break that.
    @Test(.machinePinned(.pixelSampling)) func ancestorOnlyFindingsAreAnAnswerNotACleanTree() throws {
        let ancestorOnly = try Self.rendered(hasReviewed: true, findings: [], ancestor: [Self.finding()])
        let clean = try Self.rendered(hasReviewed: true, findings: [])

        #expect(Self.ink(ancestorOnly) > Self.ink(clean),
                "a scope whose only findings are about the folder above drew the clean state — the lens says the tree agrees when it has something to show")
    }

    /// And it says which folder it means: findings about a different folder would otherwise read as
    /// an answer to the question asked.
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

    static func finding(family: String = "Family/Daughter/Events") -> StructureFinding {
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
