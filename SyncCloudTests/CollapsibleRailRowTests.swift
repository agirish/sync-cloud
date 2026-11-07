@testable import SyncCloud
import AppKit
import SwiftUI
import Testing

/// Collapsing the rail keeps the workspace. Written into both arms of an `if collapsed`, a
/// workspace gets a new identity on every collapse: Edit would rebuild its text view around the
/// whole buffer and Organize's lists would reopen at the top. Through `CollapsibleRailRow` only the
/// leading slot changes. This mounts the row with a real `NSTextView`, folds it both ways, and
/// checks the text view is the one it started with; the control shows the two-arm shape rebuilds it.
@MainActor @Suite struct CollapsibleRailRowTests {

    final class Fold: ObservableObject {
        @Published var collapsed = false
    }

    /// A text view, counted as it is built, so a rebuild cannot hide behind an equal-looking one.
    struct TextViewProbe: NSViewRepresentable {
        let built: (NSTextView) -> Void
        func makeNSView(context: Context) -> NSTextView {
            let view = NSTextView()
            view.string = "the whole buffer"
            built(view)
            return view
        }
        func updateNSView(_ view: NSTextView, context: Context) {}
    }

    struct Row: View {
        @ObservedObject var fold: Fold
        let twoArms: Bool
        let built: (NSTextView) -> Void

        var body: some View {
            if twoArms {
                // The two-arm shape, for the control.
                if fold.collapsed {
                    HStack(spacing: 0) {
                        Color.gray.frame(width: 20)
                        TextViewProbe(built: built).frame(maxWidth: .infinity)
                    }
                } else {
                    HStack(spacing: 0) {
                        Color.blue.frame(width: 120)
                        TextViewProbe(built: built).frame(maxWidth: .infinity)
                    }
                }
            } else {
                CollapsibleRailRow {
                    if fold.collapsed {
                        Color.gray.frame(width: 20)
                    } else {
                        Color.blue.frame(width: 120)
                    }
                } workspace: {
                    TextViewProbe(built: built).frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Mounts the row, folds it and unfolds it, and answers every text view that was built and the
    /// ones in the window after each step.
    private func foldBothWays(twoArms: Bool) async -> (built: [NSTextView], mounted: [NSTextView?]) {
        let fold = Fold()
        var built: [NSTextView] = []
        let host = NSHostingView(rootView: Row(fold: fold, twoArms: twoArms) { built.append($0) })
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }

        func settle() async {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func mounted() -> NSTextView? {
            var found: NSTextView?
            func walk(_ v: NSView) {
                if let t = v as? NSTextView { found = t }
                v.subviews.forEach(walk)
            }
            walk(host)
            return found
        }
        var seen: [NSTextView?] = []
        await settle()
        seen.append(mounted())
        fold.collapsed = true
        await settle()
        seen.append(mounted())
        fold.collapsed = false
        await settle()
        seen.append(mounted())
        return (built, seen)
    }

    @Test func theWorkspaceSurvivesACollapseAndAnExpand() async throws {
        let (built, mounted) = await foldBothWays(twoArms: false)
        let first = try #require(mounted.first ?? nil, "the text view never mounted")
        #expect(built.count == 1, "the workspace was built \(built.count) times across a collapse and an expand")
        #expect(mounted.allSatisfy { $0 === first },
                "a different text view was on screen after a fold")
    }

    /// The control: the two-arm layout does rebuild the text view on every fold.
    @Test func theTwoArmShapeItReplacedRebuildsIt() async throws {
        let (built, mounted) = await foldBothWays(twoArms: true)
        try #require(mounted.allSatisfy { $0 != nil }, "the text view never mounted")
        #expect(built.count == 3, "the control no longer rebuilds — the test above cannot see a rebuild")
    }

    /// Both layouts go through the row, with one workspace each. The mount above is about the row;
    /// this pins that the app's two collapsible layouts use it and write their workspace once.
    @Test func organizeAndEditLayOutThroughTheRow() throws {
        let split = try CodeText(declarationBody(
            of: "func singleSourceLayout(collapsed: Bool, geo: GeometryProxy) -> some View {",
            in: macAppFile("ContentView+SplitLayout.swift")))
        #expect(split.contains("CollapsibleRailRow {"), "Organize's row no longer keeps its workspace")
        #expect(split.count(of: "bottomPaneView") == 1, "Organize writes its workspace more than once")

        let editor = try CodeText(declarationBody(
            of: "func editorLayout(collapsed: Bool, geo: GeometryProxy) -> some View {",
            in: macAppFile("ContentView+Editor.swift")))
        #expect(editor.contains("CollapsibleRailRow {"), "Edit's row no longer keeps its workspace")
        #expect(editor.count(of: "editorWorkspace(showsRail:") == 1, "Edit writes its workspace more than once")

        // Identity can also break outside those bodies: one `case` per state is two call sites, and
        // an `.id` keyed on the fold is a new identity on every toggle.
        let dispatch = sourceCodeOnly(try macAppFile("ContentView+SplitLayout.swift"))
        #expect(dispatch.contains("case .singleExpanded, .singleCollapsed:"),
                "Organize's two states are separate cases — the row is built in two places again")
        #expect(dispatch.contains("case .editorExpanded, .editorCollapsed:"),
                "Edit's two states are separate cases — the row is built in two places again")
        #expect(!split.contains(".id(") && !editor.contains(".id("),
                "an `.id` inside a collapsible layout gives the workspace a new identity")
    }
}

/// A workspace switch, a rail collapse and an Organize lens switch are not animated. An animation
/// around a layout swap keeps the outgoing layout mounted and drawn until it ends: leaving Compare
/// would keep two panes, the differences table and the sidebar alive under the next workspace,
/// and a collapse would cross-fade two whole copies of the workspace, roughly doubling the main
/// thread's work per switch. The workspace bar slides its own pill.
@Suite struct WorkspaceSwitchSnapsTests {

    @Test func noAnimationIsKeyedOnTheWorkspaceOrTheCollapse() throws {
        for name in try QuickLookOriginTests.macAppSwiftFiles() {
            let source = sourceCodeOnly(try macAppFile(name))
            // `.animation(nil, value: …)` is the suppression that makes the snap structural, so it
            // is the one keyed animation allowed.
            let animating = source.components(separatedBy: "\n")
                .filter { !$0.contains(".animation(nil, value:") }.joined(separator: "\n")
            let code = CodeText(animating)
            for key in ["value: selectedWorkspace)", "value: panesHiddenForCurrentTab)", "value: contentLayout)"] {
                let keyed = code.contains(key)
                #expect(!keyed, "\(name): an animation is keyed on \(key) again — it holds the outgoing layout on screen")
            }
            let animatedToggles = source.components(separatedBy: "\n").filter {
                ($0.contains("togglePanesForCurrentTab()") || $0.contains("editorExpand = expand")) && $0.contains("Animation(")
            }
            #expect(animatedToggles.isEmpty, "\(name): a rail toggle is animated again: \(animatedToggles)")
        }
    }

    /// And the switch and the pane toggle strip any animation a caller wraps them in, so a later
    /// `withAnimation` cannot bring the fade back (or ignore Reduce Motion).
    @Test func theSwitchAndThePaneToggleSuppressAnyAnimation() throws {
        let content = sourceCodeOnly(try macAppFile("ContentView.swift"))
        #expect(content.contains(".animation(nil, value: selectedWorkspace)"))
        #expect(content.contains(".animation(nil, value: panesHiddenForCurrentTab)"))
    }

    @Test func organizesLensSwitchesArePlainAssignments() throws {
        let code = CodeText(try repoFile("Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift"))
        #expect(code.count(of: "railLens = ") >= 5, "the scan no longer finds the lens switches")
        let eased = code.contains("withAnimation(listSettle) { railLens")
        #expect(!eased, "a lens switch eases again")
    }
}
