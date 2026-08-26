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

/// What the two wrappers actually put in the transaction, read out of a live render.
///
/// **The rule is a pure function and was tested as one, which cannot see the thing that matters.**
/// `DesignAnimationRule.resolve` returning nil is only useful if nil then reaches the transaction —
/// and SwiftUI has two animation doors that can disagree. This mounts a real view and reads
/// `Transaction.animation` from beneath each wrapper while an ambient `withAnimation` is running.
///
/// It exists because the answer decided a design: `.animation(_:value:)` DOES override an enclosing
/// `withAnimation`, so a value that some ancestor gates is gated however it is written — which is
/// why the panes, the inspector and the workspace switch are correctly covered despite every one of
/// them being toggled inside a `withAnimation`. Had it gone the other way, twenty converted sites
/// would have been decoration.
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

    /// The imperative half, measured the same way: a change driven by `withDesignAnimation` under
    /// the setting reaches an UNGATED subtree with no animation at all.
    ///
    /// The ungated sibling is the probe on purpose — it is the one with nothing of its own to
    /// suppress, so what it sees is whatever the driver put in the transaction and nothing else.
    /// An earlier version of this test asked `Transaction().animation` inside the closure, which
    /// constructs a fresh transaction rather than reading the ambient one and so answered nil
    /// whatever the flag said: green, and about nothing.
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
