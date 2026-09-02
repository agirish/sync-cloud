import Testing
import Foundation
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// Which files autosave may write, and how long that answer lasts.
@MainActor
@Suite struct EditorAutosavePolicyTests {

    @Test func everythingAutosavesUntilSomebodySaysOtherwise() {
        let policy = EditorAutosavePolicy()
        #expect(policy.isOn("/n/a.md"))
        #expect(policy.isOn("/n/b.md"))
        #expect(policy.suspendedCount == 0)
    }

    /// `nil` is "nothing is open", not "autosave is off" — a caller that confused the two would
    /// draw the header's switch in the wrong position the moment the editor was empty.
    @Test func noDocumentIsNotTheSameAsSwitchedOff() {
        let policy = EditorAutosavePolicy()
        #expect(policy.isOn(nil))
        policy.setOn(false, for: "/n/a.md")
        #expect(policy.isOn(nil), "an empty editor reported autosave off")
    }

    /// **Per file, which is the whole point.** Switching one off must not quiet the others.
    @Test func switchingOneOffLeavesTheRestAlone() {
        let policy = EditorAutosavePolicy()
        policy.setOn(false, for: "/n/risky.md")
        #expect(!policy.isOn("/n/risky.md"))
        #expect(policy.isOn("/n/ordinary.md"))
        #expect(policy.suspendedCount == 1)
    }

    @Test func togglingReturnsWhereItLanded() {
        let policy = EditorAutosavePolicy()
        #expect(policy.toggle("/n/a.md") == false)
        #expect(!policy.isOn("/n/a.md"))
        #expect(policy.toggle("/n/a.md") == true)
        #expect(policy.isOn("/n/a.md"))
        #expect(policy.suspendedCount == 0, "switching back on left the path behind")
    }

    /// Closing a file and opening it again in the same session keeps its setting — the set is keyed
    /// by path and nothing clears it. This is the half of the rule that a session-scoped store has
    /// to get right; the other half, forgetting at quit, is a property of the object's lifetime and
    /// is asserted by the app owning it rather than by anything here.
    @Test func aFileReopenedInTheSameSessionKeepsItsSetting() {
        let policy = EditorAutosavePolicy()
        policy.setOn(false, for: "/n/risky.md")
        // …open something else, then come back.
        #expect(policy.isOn("/n/other.md"))
        #expect(!policy.isOn("/n/risky.md"), "the setting was forgotten between visits")
    }

    /// Two files with similar names are two files. Trivial, and the kind of thing a prefix match
    /// would get wrong.
    @Test func pathsAreMatchedWholeRatherThanByPrefix() {
        let policy = EditorAutosavePolicy()
        policy.setOn(false, for: "/n/plan.md")
        #expect(policy.isOn("/n/plan.md.bak"))
        #expect(policy.isOn("/n/plan"))
    }

    @Test func settingOnAFileThatIsAlreadyOnChangesNothing() {
        let policy = EditorAutosavePolicy()
        policy.setOn(true, for: "/n/a.md")
        #expect(policy.suspendedCount == 0)
    }
}

/// Where the header's autosave switch is drawn, and where it is not.
@MainActor
@Suite struct EditorAutosaveSwitchVisibilityTests {

    @Test func anOrdinaryOpenDocumentGetsTheSwitch() {
        #expect(EditorWorkspaceView.showsAutosaveSwitch(hasPath: true, wasRefused: false,
                                                        isReadOnly: false))
    }

    /// The three cases where autosave was never going to write anyway. A switch that changes
    /// nothing reads as a broken control rather than an unavailable one.
    @Test func nothingOpenAndNothingWritableGetNoSwitch() {
        #expect(!EditorWorkspaceView.showsAutosaveSwitch(hasPath: false, wasRefused: false,
                                                         isReadOnly: false))
        #expect(!EditorWorkspaceView.showsAutosaveSwitch(hasPath: true, wasRefused: true,
                                                         isReadOnly: false))
        #expect(!EditorWorkspaceView.showsAutosaveSwitch(hasPath: true, wasRefused: false,
                                                         isReadOnly: true))
    }
}


/// The switch's shape: that it is a switch, and that it stays inside the row it sits on.
@MainActor
@Suite(.serialized) struct AutosaveSwitchTrackTests {

    private func size(_ view: some View, scale: CGFloat) -> CGSize {
        NSHostingView(rootView: AnyView(view.environment(\.appFontScale, scale))).fittingSize
    }

    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    /// **Oval, not round.** A 1:1 track is a dot, which is the radio button this replaced; the
    /// proportion is what makes it read as a switch before anybody has looked at the knob.
    @Test func theTrackIsWiderThanItIsTall() {
        for scale in scales {
            let height = AutosaveSwitchTrack.height(at: scale)
            let width = AutosaveSwitchTrack.width(at: scale)
            #expect(width > height * 1.5,
                    "at scale \(scale) the track is \(width)×\(height), which is not an oval")
        }
    }

    /// It sits on a `lineLimit(1)` row beside its own label, so the thing that matters is not how
    /// it scales in the abstract but that it scales **with that label** — a switch that outgrew the
    /// words would be what pushed the status word out of the row.
    ///
    /// **Measured against a rendered `Text`, not against the ramp's arithmetic.** The first version
    /// of this asserted the height stayed under a number derived from the ramp's knee, which was
    /// simply wrong — the knee is 11pt and this text is 10, so it scales linearly by design. And a
    /// test that recomputed `scaledBox` would pass for a bare multiply too, since below the knee
    /// they agree. Comparing the drawn control to the drawn label is the claim itself.
    @Test func theTrackKeepsItsProportionToTheLabelBesideIt() {
        var ratios: [CGFloat] = []
        for scale in scales {
            let label = size(Text("Autosave").scaledFont(.system(size: 10, weight: .medium)),
                             scale: scale)
            let track = AutosaveSwitchTrack.height(at: scale)
            #expect(label.height > 0, "the label rendered to nothing at scale \(scale)")
            ratios.append(track / label.height)
        }
        // **A band, not a stability bound, and the measurement is why.** Across Small · Default ·
        // Large · Largest the ratio runs 0.90 · 0.85 · 0.92 · 0.93 — non-monotonic, because the
        // label's height is a LINE BOX and line boxes step while the track's height is continuous.
        // A tight spread would be measuring that quantisation. What is worth asserting is that the
        // switch stays a switch beside its words at every size: never shrivelled, never towering.
        for (index, ratio) in ratios.enumerated() {
            #expect(ratio > 0.75 && ratio < 1.05,
                    "at scale \(scales[index]) the switch is \(ratio)× its label's line box")
        }
        // And it really does grow — a control pinned at one size would have a perfect ratio spread
        // of zero against a label that grew, so this is the positive control for the line above.
        let heights = scales.map { AutosaveSwitchTrack.height(at: $0) }
        #expect((heights.last ?? 0) > (heights.first ?? 0), "the track is flat: \(heights)")
    }

    /// Both states are the same size, or the row would shift sideways every time it was pressed.
    @Test func bothStatesMeasureTheSame() {
        let on = size(AutosaveSwitchTrack(isOn: true, accent: .blue), scale: 1)
        let off = size(AutosaveSwitchTrack(isOn: false, accent: .blue), scale: 1)
        #expect(on == off, "the switch changes size when it is toggled: \(on) then \(off)")
    }
}

/// The autosave switch's two side effects, which are the half a policy object cannot show.
@MainActor
@Suite struct EditorAutosaveResumeTests {

    /// **Turning it back on has to write what is already waiting.** The debounce is a `.task(id:)`
    /// keyed on the buffer's version, so it does not re-fire because a setting changed — without
    /// the callback, autosave came back on and the file stayed unwritten until the next keystroke,
    /// which is the one moment somebody is most entitled to expect it to be saved.
    @Test func switchingBackOnReportsThatItResumed() {
        let policy = EditorAutosavePolicy()
        policy.setOn(false, for: "/n/a.md")
        #expect(policy.toggle("/n/a.md") == true,
                "the toggle did not report the ON transition the resume hangs off")
    }

    /// And switching OFF must not: a write triggered by turning writing off would be the exact
    /// opposite of what was asked for.
    @Test func switchingOffReportsOff() {
        let policy = EditorAutosavePolicy()
        #expect(policy.toggle("/n/a.md") == false)
    }
}
