import AppKit
import SwiftUI
import Testing
@testable import Design

/// `designAnimation` is one decision, drop the motion when Reduce Motion is on, so the decision is
/// tested: `DesignAnimationModifier` calls `DesignAnimationRule.resolve` itself, so this is the code
/// that actually runs.
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

    /// The wrapper must not change layout: it stands in for `.animation(_:value:)` at many sites,
    /// and a different footprint would shift every one.
    @Test @MainActor func theWrapperDoesNotChangeLayout() {
        let plain = NSHostingView(rootView: Color.clear.frame(width: 90, height: 30)
            .animation(.easeOut(duration: 0.2), value: 1))
        let wrapped = NSHostingView(rootView: Color.clear.frame(width: 90, height: 30)
            .designAnimation(.easeOut(duration: 0.2), value: 1))
        #expect(plain.fittingSize == wrapped.fittingSize,
                "the wrapper changed the footprint: \(plain.fittingSize) vs \(wrapped.fittingSize)")
    }

    // MARK: - The families deliberately left alone

    /// The three exempt families stay exempt: a hover ladder, a numeric roll and an overlay
    /// cross-fade are what Reduce Motion asks motion to be replaced with. Converting them would make
    /// a hovered control snap between two fills.
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
            // `nimation(` matches BOTH spellings on purpose: `.animation(` would miss a converted
            // `.designAnimation(` site, failing the `#require` as "no longer animates" before the
            // assertion that explains the real problem is reached.
            let line = text.split(separator: "\n").first { $0.contains(marker) && $0.contains("nimation(") }
            let found = try #require(line.map(String.init),
                                     "\(path) no longer animates \(marker) — the exemption may be stale")
            #expect(!found.contains("designAnimation"),
                    "\(path) gated \(marker) on Reduce Motion. A hover wash, a rolling digit and an overlay cross-fade are what the setting asks for INSTEAD of motion — see `View.designAnimation`, which lists these three families and why.")
        }
    }
}

/// What the two wrappers actually put in the transaction, read as `Transaction.animation` beneath
/// each in a live render while an ambient `withAnimation` runs.
///
/// It pins a fact a design rests on: `.animation(_:value:)` overrides an enclosing
/// `withAnimation`, so a gated value stays gated however its mutation is wrapped.
@MainActor
@Suite(.serialized) struct AnimationTransactionTests {

    @MainActor private final class Flag: ObservableObject { @Published var on = false }

    private struct Probe: View {
        @ObservedObject var flag: Flag
        let sink: @MainActor (String, Animation?) -> Void
        var body: some View {
            VStack {
                Color.clear.frame(width: 4, height: 4).opacity(flag.on ? 1 : 0)
                    .transaction { sink("gated", $0.animation) }
                    .designAnimation(nil, value: flag.on)
                Color.clear.frame(width: 4, height: 4).opacity(flag.on ? 1 : 0)
                    .transaction { sink("ungated", $0.animation) }
            }
        }
    }

    /// `designAnimation(nil, …)` wins over an enclosing `withAnimation`; without it the ambient
    /// animation reaches the subtree, which is what makes the first half a real result.
    @Test func aGatedSubtreeSeesNoAnimationWhileAnUngatedSiblingSeesTheAmbientOne() async throws {
        let flag = Flag()
        var seen: [String: Animation?] = [:]
        let host = NSHostingView(rootView: AnyView(Probe(flag: flag) { key, animation in
            // First write wins: later idle passes re-run with no transaction and would erase it.
            if seen[key] == nil { seen[key] = animation }
        }))
        host.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        seen.removeAll()

        withAnimation(.easeInOut(duration: 5)) { flag.on = true }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()

        // Non-vacuity first: if the ungated sibling never saw the ambient animation, the harness
        // did not stage the thing under test and a nil on the gated side proves nothing.
        let ungated = try #require(seen["ungated"], "the probe never rendered — nothing was measured")
        #expect(ungated != nil, """
            the ungated sibling saw no ambient animation, so this run staged no transaction to \
            override and the gated result below is vacuous
            """)
        let gated = try #require(seen["gated"], "the gated probe never rendered")
        #expect(gated == nil, """
            designAnimation(nil,) did not clear the transaction — an enclosing withAnimation wins, \
            which would mean every converted site is only gated when nothing wraps its mutation
            """)
    }

    /// The imperative half: a change driven by `withDesignAnimation` under the setting reaches an
    /// UNGATED subtree with no animation. The ungated sibling is the probe on purpose: reading
    /// `Transaction().animation` inside the closure would build a fresh one and answer nil regardless.
    @Test func withDesignAnimationUnderReduceMotionDrivesNoAnimation() async throws {
        func ambientSeenByAnUngatedSubtree(reduceMotion: Bool) async throws -> Animation? {
            let flag = Flag()
            var seen: [String: Animation?] = [:]
            let host = NSHostingView(rootView: AnyView(Probe(flag: flag) { key, animation in
                if seen[key] == nil { seen[key] = animation }
            }))
            host.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            seen.removeAll()
            withDesignAnimation(.easeInOut(duration: 5), reduceMotion: reduceMotion) { flag.on = true }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            return try #require(seen["ungated"], "the probe never rendered — nothing was measured")
        }

        // Setting off: the animation is handed through, which is what makes the nil below a result.
        #expect(try await ambientSeenByAnUngatedSubtree(reduceMotion: false) != nil, """
            withDesignAnimation dropped the animation with the setting OFF — the comparison below \
            cannot tell suppression from a wrapper that never animates anything
            """)
        // Setting on: nothing reaches the subtree.
        #expect(try await ambientSeenByAnUngatedSubtree(reduceMotion: true) == nil,
                "withDesignAnimation animated with Reduce Motion on")
    }
}
