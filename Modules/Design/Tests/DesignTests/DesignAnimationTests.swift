import AppKit
import SwiftUI
import Testing
@testable import Design

/// `designAnimation` is one decision — drop the motion when Reduce Motion is on — so the decision
/// is tested rather than the modifier that carries it. `DesignAnimationModifier` calls
/// `DesignAnimationRule.resolve` itself, so these are testing the code that actually runs and not a
/// restatement of it sitting beside it.
@Suite struct DesignAnimationTests {

    @Test func reduceMotionDropsTheAnimationEntirely() {
        #expect(DesignAnimationRule.resolve(.easeOut(duration: 0.2), reduceMotion: true) == nil,
                "Reduce Motion still animates — the whole point of the wrapper")
    }

    @Test func theAnimationSurvivesWhenTheSettingIsOff() {
        let wanted = Animation.easeOut(duration: 0.2)
        #expect(DesignAnimationRule.resolve(wanted, reduceMotion: false) == wanted,
                "the wrapper changed an animation it was only supposed to pass through")
    }

    /// A caller that already computed `nil` gets `nil` either way — the parameter is optional so a
    /// site with its own reason to skip an animation can still route through one spelling.
    @Test func aNilAnimationStaysNilInBothDirections() {
        #expect(DesignAnimationRule.resolve(nil, reduceMotion: false) == nil)
        #expect(DesignAnimationRule.resolve(nil, reduceMotion: true) == nil)
    }

    /// **The wrapper must not change layout.** It replaced `.animation(_:value:)` at fourteen
    /// sites; if the modifier reserved so much as a different size, every one of them would shift.
    @Test @MainActor func theWrapperDoesNotChangeLayout() {
        let plain = NSHostingView(rootView: Color.clear.frame(width: 90, height: 30)
            .animation(.easeOut(duration: 0.2), value: 1))
        let wrapped = NSHostingView(rootView: Color.clear.frame(width: 90, height: 30)
            .designAnimation(.easeOut(duration: 0.2), value: 1))
        #expect(plain.fittingSize == wrapped.fittingSize,
                "the wrapper changed the footprint: \(plain.fittingSize) vs \(wrapped.fittingSize)")
    }

    // MARK: - The families deliberately left alone

    /// **The three exempt families must stay exempt**, and this is the guard that says so out loud.
    ///
    /// A hover ladder, a numeric roll and an overlay cross-fade are all animation that Reduce
    /// Motion should NOT remove — colour and content transitions are what the setting asks you to
    /// substitute motion *with*. The risk this pins is a later sweep "finishing the job" by
    /// converting every remaining `.animation(` in the app, which would read as tidiness and would
    /// make a hovered control snap between two fills.
    ///
    /// Written as a source scan because the claim is about call sites, not about a function.
    @Test func theExemptFamiliesStillUseThePlainAnimationModifier() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()                       // …/<repo>

        // (file, the value: it animates) — one representative of each exempt family.
        let exempt: [(String, String)] = [
            ("Modules/Design/Sources/Design/HoverAffordance.swift", "value: phase"),
            ("Modules/Design/Sources/Design/ActionBarButtonStyle.swift", "value: phase"),
            ("Modules/Design/Sources/Design/Pill.swift", "value: text"),
            ("Modules/FileExplorer/Sources/FileExplorer/StatPill.swift", "value: count"),
            ("MacApp/ContentView.swift", "value: showSettings"),
        ]
        for (path, marker) in exempt {
            let text = try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
            // `nimation(` matches BOTH spellings on purpose. Searching for `.animation(` would not
            // match `.designAnimation(` at all, so a converted site would fail the `#require`
            // below as "no longer animates" — a true statement about the wrong thing, and the
            // assertion carrying the actual explanation would never be reached.
            let line = text.split(separator: "\n").first { $0.contains(marker) && $0.contains("nimation(") }
            let found = try #require(line.map(String.init),
                                     "\(path) no longer animates \(marker) — the exemption may be stale")
            #expect(!found.contains("designAnimation"),
                    "\(path) gated \(marker) on Reduce Motion. A hover wash, a rolling digit and an overlay cross-fade are what the setting asks for INSTEAD of motion — see `View.designAnimation`, which lists these three families and why.")
        }
    }
}
