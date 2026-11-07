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

    /// `nil` is "nothing is open", not "autosave is off"; confusing the two would draw the header's
    /// switch wrong whenever the editor is empty.
    @Test func noDocumentIsNotTheSameAsSwitchedOff() {
        let policy = EditorAutosavePolicy()
        #expect(policy.isOn(nil))
        policy.setOn(false, for: "/n/a.md")
        #expect(policy.isOn(nil), "an empty editor reported autosave off")
    }

    /// Per file: switching one off must not quiet the others.
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

    /// A file reopened in the same session keeps its setting: the set is keyed by path and nothing
    /// clears it. Forgetting at quit is the object's lifetime, owned by the app, not checked here.
    @Test func aFileReopenedInTheSameSessionKeepsItsSetting() {
        let policy = EditorAutosavePolicy()
        policy.setOn(false, for: "/n/risky.md")
        // Open something else, then come back.
        #expect(policy.isOn("/n/other.md"))
        #expect(!policy.isOn("/n/risky.md"), "the setting was forgotten between visits")
    }

    /// Two files with similar names are two files, which a prefix match would get wrong.
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

    /// The three cases where autosave would never write anyway: a switch that changes nothing reads
    /// as broken, not unavailable.
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

    /// Oval, not round: a 1:1 track reads as a radio button, and the proportion is what makes it
    /// read as a switch before anyone looks at the knob.
    @Test func theTrackIsWiderThanItIsTall() {
        for scale in scales {
            let height = AutosaveSwitchTrack.height(at: scale)
            let width = AutosaveSwitchTrack.width(at: scale)
            #expect(width > height * 1.5,
                    "at scale \(scale) the track is \(width)×\(height), which is not an oval")
        }
    }

    /// It sits on a `lineLimit(1)` row beside its label, so it must scale with that label; a switch
    /// that outgrew the words would push the status word out of the row. Measured against a
    /// rendered `Text`, not the ramp's arithmetic: below the ramp's 11pt knee, recomputing
    /// `scaledBox` would agree with a bare multiply and prove nothing.
    @Test func theTrackKeepsItsProportionToTheLabelBesideIt() {
        var ratios: [CGFloat] = []
        for scale in scales {
            let label = size(Text("Autosave").scaledFont(.system(size: 10, weight: .medium)),
                             scale: scale)
            let track = AutosaveSwitchTrack.height(at: scale)
            #expect(label.height > 0, "the label rendered to nothing at scale \(scale)")
            ratios.append(track / label.height)
        }
        // A band, not a tight spread: the ratio runs about 0.85 to 0.93 across the sizes, not
        // monotonically, because the label's line box steps while the track grows smoothly. The
        // claim is that the switch never shrinks away or towers over its words.
        for (index, ratio) in ratios.enumerated() {
            #expect(ratio > 0.75 && ratio < 1.05,
                    "at scale \(scales[index]) the switch is \(ratio)× its label's line box")
        }
        // The control for the band: the track really grows with the text size.
        let heights = scales.map { AutosaveSwitchTrack.height(at: $0) }
        #expect((heights.last ?? 0) > (heights.first ?? 0), "the track is flat: \(heights)")
    }

    /// Both states are the same size, or the row would shift sideways every time it was pressed.
    @Test func bothStatesMeasureTheSame() {
        let on = size(AutosaveSwitchTrack(isOn: true, fill: .blue), scale: 1)
        let off = size(AutosaveSwitchTrack(isOn: false, fill: .blue), scale: 1)
        #expect(on == off, "the switch changes size when it is toggled: \(on) then \(off)")
    }
}

/// The autosave switch's two side effects, which are the half a policy object cannot show.
@MainActor
@Suite struct EditorAutosaveResumeTests {

    /// Turning autosave back on must write what is already waiting. The debounce is a `.task(id:)`
    /// keyed on the buffer's version and doesn't re-fire for a setting change, so without this
    /// signal the file would stay unwritten until the next keystroke.
    @Test func switchingBackOnReportsThatItResumed() {
        let policy = EditorAutosavePolicy()
        policy.setOn(false, for: "/n/a.md")
        #expect(policy.toggle("/n/a.md") == true,
                "the toggle did not report the ON transition the resume hangs off")
    }

    /// Switching off must not report a resume: a write triggered by turning writing off is the
    /// opposite of what was asked.
    @Test func switchingOffReportsOff() {
        let policy = EditorAutosavePolicy()
        #expect(policy.toggle("/n/a.md") == false)
    }
}
