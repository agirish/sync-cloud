import SwiftUI
import Sync
import Design
import FileExplorer

/// Which surface shows the result message (Banner Room, CA).
enum ResultMessageHome: Equatable {
    /// A pane's file list, in one stack with its action bar.
    case pane(isLeft: Bool)
    /// The lens or the editor beside a source pane — the half of the window that has no file list.
    case workspace
    /// The toolbar's capsule — a long run's ending, when the reader has moved on from where it was
    /// started (Run Room CG, CP).
    case toolbar
}

/// **Where a result message goes**: where the reader was working when it arrived.
///
/// - **Browse** has one pane and nothing else, so it goes there.
/// - **Compare** sends it to the focused pane. Every pane action — a row click, the header's
///   Delete, the bar's Copy, ⌘⌫ — moves focus to its pane before it acts, so this is the pane the
///   action happened in, and it covers only that pane's list, never the seam's ⇄ and 🔗 (TE212).
/// - **Organize and Edit** send it to their source pane when that is where the reader last clicked,
///   and otherwise to the lens or the editor — where To File's moves, Duplicates' merges and the
///   editor's saves happen. A collapsed pane is no place for it.
///
/// **A long run's ending goes where it was started, if that is still on screen; otherwise to the
/// capsule** (Run Room CG, CP). Nothing in the app runs unattended (R3), so "background" is a copy,
/// a merge, a PDF tool or Save as PDF that ends after the reader moved to another workspace — a
/// merge clicked in Organize finishing four minutes later in Browse. That ending would land in a
/// pane the reader is not looking at, or in Browse's, about something Browse never did. Recent keeps
/// it either way.
enum ResultMessageRoute {
    /// Whether a run's ending goes to the capsule: it was started in another workspace than the one
    /// on screen. `nil` — no run ended just now — is the result of a click, which stays.
    static func endsInCapsule(startedIn origin: Workspace?, showing current: Workspace) -> Bool {
        guard let origin else { return false }
        return origin != current
    }

    static func home(layout: ContentView.ContentLayout, focusedPaneIsLeft: Bool,
                     lastWorkedInPane: Bool) -> ResultMessageHome {
        switch layout {
        case .browseFull: return .pane(isLeft: true)
        case .compareSplit: return .pane(isLeft: focusedPaneIsLeft)
        case .singleExpanded, .editorExpanded: return lastWorkedInPane ? .pane(isLeft: true) : .workspace
        case .singleCollapsed, .editorCollapsed: return .workspace
        }
    }
}

extension ContentView {

    var resultMessageHome: ResultMessageHome {
        if let id = capsuleMessageID, syncManager.banner?.id == id { return .toolbar }
        return ResultMessageRoute.home(layout: contentLayout, focusedPaneIsLeft: focusedPane != .right,
                                       lastWorkedInPane: resultMessageInPane)
    }

    /// Where the run whose ending `banner` is was started — a pane PDF tool's or Save as PDF's
    /// own, or the long file operation that ended a moment ago. `nil` for a click's result.
    func runOrigin(ending banner: OperationBanner) -> Workspace? {
        if let pending = pendingResultOrigin { return pending }
        guard let ended = syncManager.lastFinishedRun?.ended, Date().timeIntervalSince(ended) < 2 else { return nil }
        return fileOperationOrigin
    }

    /// The long file operation `banner` may be the ending of — none for a pane PDF tool's or Save
    /// as PDF's result, which ends a run of its own: a copy that ended a moment before it, saying
    /// nothing, must not lend the PDF's message its title, its stop or its minutes.
    func fileRunEnded(by banner: OperationBanner) -> (started: Date, ended: Date, title: String?, cancelled: Bool)? {
        paneToolResultDoors?.banner.id == banner.id ? nil : syncManager.lastFinishedRun
    }

    /// The message as the capsule draws it (CG, TE233) — nil unless the message is the capsule's.
    var capsuleMessage: ProgressCapsuleMessage? {
        guard resultMessageHome == .toolbar, let banner = syncManager.banner else { return nil }
        var actions: [ProgressCapsuleMessage.Action] = []
        if banner.isUndoable, undoManager?.canUndo ?? false {
            actions.append(.init(title: "Undo", help: runWriteLockReason ?? ShortcutHint.tooltip("Undo this operation", "⌘Z"),
                                 isEnabled: runWriteLockReason == nil) {
                guard !refusedWhileRunLocked() else { return }
                undoManager?.undo()
                syncManager.banner = nil
            })
        }
        for followUp in banner.followUps {
            actions.append(.init(title: followUp.title, help: followUp.help) { performFollowUp(followUp) })
        }
        return ProgressCapsuleMessage(text: banner.message, weight: Self.capsuleWeight(banner.severity), actions: actions,
                                      onClose: { retireResultMessage() },
                                      onHover: { bannerDismissScheduler.hoverChanged(isHovering: $0) },
                                      isFolding: capsuleFoldingID == banner.id)
    }

    static func capsuleWeight(_ severity: OperationBanner.Severity) -> ProgressCapsuleMessage.Weight {
        switch severity {
        case .success: return .success
        case .warning: return .warning
        case .error: return .failure
        }
    }

    /// **The message leaves on its own** — its time ran out, or ✕ — rather than being undone or
    /// followed, which clear it where it is. The capsule's folds into its ring and flies into the
    /// Activity button (`ResultMessageExit`); every other message just goes.
    func retireResultMessage() {
        guard let banner = syncManager.banner else { return }
        let anchors = CapsuleFlightAnchors.shared.frames()
        switch ResultMessageExit.exit(home: resultMessageHome, reduceMotion: reduceMotion,
                                      activityIsOpen: ActivityCenter.shared.popoverIsOpen,
                                      hasAnchors: anchors != nil) {
        case .clear:
            syncManager.banner = nil
        case .flashInActivity:
            syncManager.banner = nil
            ActivityCenter.shared.flashRow(for: banner.id)
        case .landInActivity:
            syncManager.banner = nil
            CapsuleFlightLanding.shared.arrived(banner.id)
        case .fly:
            CapsuleFlightLanding.shared.takeOff(banner.id)
            withDesignAnimation(ProgressCapsuleFlight.foldAnimation, reduceMotion: reduceMotion) {
                capsuleFoldingID = banner.id
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(ProgressCapsuleFlight.foldDuration))
                capsuleFoldingID = nil
                // Replaced or closed while it folded: the newer message is not this one's to clear.
                guard syncManager.banner?.id == banner.id else {
                    CapsuleFlightLanding.shared.callOff(banner.id)
                    return
                }
                syncManager.banner = nil
                // Measured again after the fold: the toolbar may have re-laid out under it.
                if let ends = CapsuleFlightAnchors.shared.frames() {
                    CapsuleFlight.fly(Self.capsuleWeight(banner.severity), from: ends.capsule, to: ends.activity,
                                      over: ends.host) { CapsuleFlightLanding.shared.arrived(banner.id) }
                } else {
                    CapsuleFlightLanding.shared.arrived(banner.id)
                }
            }
        }
    }

    /// The message this pane shows, or nil when it is shown elsewhere — or there is none.
    func paneResultMessage(isLeft: Bool) -> OperationBanner? {
        guard let banner = syncManager.banner, resultMessageHome == .pane(isLeft: isLeft) else { return nil }
        return banner
    }

    /// Organize and Edit's other half's message host — the lens or the editor.
    var workspaceResultMessageHost: WorkspaceResultMessageHost {
        let banner = resultMessageHome == .workspace ? syncManager.banner : nil
        return WorkspaceResultMessageHost(message: banner.map { AnyView(resultMessageView($0)) },
                                          messageID: banner?.id,
                                          onClick: { noteResultRegion(inPane: false) })
    }

    /// Records where the reader is working in Organize and Edit — from a click in either half.
    func noteResultRegion(inPane: Bool) {
        if resultMessageInPane != inPane { resultMessageInPane = inPane }
    }

    /// Re-renders a pane column when its overlay stack's edge moved without a selection change — a
    /// scroll, or a message measuring taller than its estimate.
    func paneOverlayFlip(isLeft: Bool) -> () -> Void {
        {
            withAnimation(.easeInOut(duration: 0.22)) {
                if isLeft { leftBarAtTop.toggle() } else { rightBarAtTop.toggle() }
            }
        }
    }

    /// The contextual action bar's half of a pane's overlay stack.
    @ViewBuilder
    func paneBarPiece(isLeft: Bool, barNodes: [FileNode], atTop: Bool, placement: PaneBarPlacement) -> some View {
        if !barNodes.isEmpty {
            paneActionBar(isLeft: isLeft, selectionNodes: barNodes)
                .padding(10)
                // Feed the padded bar's real footprint to the placement math, so the
                // flip-to-top triggers exactly when a bottom bar would cover the
                // selected row — not at a guessed fixed band. Writes to the shared
                // class, so no view invalidation.
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { placement.coverage = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, h in placement.coverage = h }
                    }
                )
                // Re-key on the edge so a scroll-crossing flip is a clean cross-fade (old
                // copy fades out at one edge, new fades in at the other) rather than an
                // alignment snap. A selection-driven edge change carries no animation
                // context, so it lands instantly; a scroll flip runs inside the callback's
                // `withAnimation`, so it cross-fades.
                .id(atTop)
                .transition(.move(edge: atTop ? .top : .bottom).combined(with: .opacity))
        }
    }

    /// The result message's half: on the list's side of the bar, with the bar's 10pt gutters — and
    /// none between the two, where the bar's own padding already is.
    func paneMessagePiece(isLeft: Bool, message: OperationBanner, atTop: Bool, besideBar: Bool,
                          placement: PaneBarPlacement) -> some View {
        let flip = paneOverlayFlip(isLeft: isLeft)
        return resultMessageView(message)
            .frame(maxWidth: 560)
            .padding(.horizontal, 10)
            .padding(atTop ? .bottom : .top, 10)
            .padding(atTop ? .top : .bottom, besideBar ? 0 : 10)
            // Its real footprint, as the bar's. A message that wraps measures taller than the
            // placement's estimate, which can put the row it is guarding inside the zone — so a
            // new height re-resolves, and a flip re-renders the column.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            placement.messageCoverage = proxy.size.height
                            placement.flipIfEdgeMoved(flip)
                        }
                        .onChange(of: proxy.size.height) { _, h in
                            placement.messageCoverage = h
                            placement.flipIfEdgeMoved(flip)
                        }
                }
            )
            // Re-keyed per message, so a replacement slides in for the one it replaces.
            .id(message.id)
            .transition(.move(edge: atTop ? .top : .bottom).combined(with: .opacity))
    }

    /// The message itself, wired to the window: Undo, close, hover, its follow-ups, and To File's
    /// "Save as rule…".
    func resultMessageView(_ banner: OperationBanner) -> some View {
        OperationBannerView(
            banner: banner,
            glassLevel: glassLevel,
            canUndo: undoManager?.canUndo ?? false,
            onUndo: {
                // Greyed during a run (CF); refused here too, should a press slip past the grey.
                guard !refusedWhileRunLocked() else { return }
                // The same reversal ⌘Z performs: this operation registered exactly one
                // (grouped) undo step and its banner is the newest, so it sits on top of
                // the stack. Clear the banner so the affordance doesn't linger post-undo.
                undoManager?.undo()
                syncManager.banner = nil
            },
            onClose: { syncManager.banner = nil },
            onHover: { hovering in bannerDismissScheduler.hoverChanged(isHovering: hovering) },
            onFollowUp: { performFollowUp($0) },
            accessory: ruleOfferAccessory(for: banner))
    }

    /// **"Save as rule…" in the "Filed …" message** (Banner Room, CB), while the offer that move
    /// made still rides in it. Organize only: the review sheet the offer ends in is the lens's. The
    /// button observes the session itself — the window owns it without observing it.
    func ruleOfferAccessory(for banner: OperationBanner) -> AnyView? {
        guard selectedWorkspace == .filing else { return nil }
        return AnyView(FilingRuleOfferButton(session: lensSession, bannerID: banner.id, syncManager: syncManager,
                                             accent: glassHue.accentColor,
                                             onOpenChange: { ruleOfferIsOpen = $0 }))
    }

    /// Opens one of a finished result's doors — to the files still there, or says they are gone.
    func performFollowUp(_ followUp: OperationBanner.FollowUp) {
        guard let doors = paneToolResultDoors, doors.banner.id == syncManager.banner?.id else { return }
        func here(_ paths: [String]) -> [String]? {
            let here = PaneToolResult.stillThere(paths)
            if here.isEmpty { syncManager.banner = .warning(PaneToolResult.goneMessage(paths)) }
            return here.isEmpty ? nil : here
        }
        switch followUp {
        case .openInEdit(let path):
            guard let here = here([path]) else { return }
            doors.open(here[0])
        case .revealInBrowse(let paths):
            guard let here = here(paths) else { return }
            doors.reveal(here)
        case .download(let path):
            syncManager.banner = nil
            doors.download(path)
        }
    }

    /// A pane-launched PDF tool's or Save as PDF's ending, shown as the result message (TE207).
    func postPaneToolResult(_ result: PaneToolResult) {
        paneToolResultDoors = result
        pendingResultOrigin = result.source == .saveAsPDF ? saveAsPDFOrigin : paneToolOrigin
        syncManager.banner = result.banner
    }

    /// Everything a new message owes beyond its timer: VoiceOver hears it (TE211), and a rule offer
    /// riding in the message it replaced leaves with that message (CB). Returns whether the message
    /// is the capsule's, for its timer.
    @discardableResult
    func resultMessageChanged(to banner: OperationBanner?) -> Bool {
        // A capsule problem's dot waits only while its message is on screen or in flight: replaced,
        // or cleared without a flight (Undo, a follow-up), it shows now rather than never.
        if banner != nil || CapsuleFlightLanding.shared.flying == nil { ActivityCenter.shared.releaseDot() }
        lensSession.retireRuleOffer(unlessRiding: banner?.id)
        if paneToolResultDoors?.banner.id != banner?.id { paneToolResultDoors = nil }
        guard let banner else { return false }
        // Where its run was started decides whether it is the capsule's (CG, CP).
        let toCapsule = ResultMessageRoute.endsInCapsule(startedIn: runOrigin(ending: banner),
                                                         showing: selectedWorkspace)
        pendingResultOrigin = nil
        capsuleMessageID = toCapsule ? banner.id : nil
        OperationBannerView.announce(banner, offersUndo: banner.isUndoable && (undoManager?.canUndo ?? false)
                                     && runWriteLockReason == nil)
        // Copied into Activity's Recent as it is published (Run Room R9), not spoken again (R19). A
        // problem the capsule showed for its ten seconds while the reader worked elsewhere leaves the
        // Activity button's dot (CS).
        ActivityCenter.shared.record(banner, run: syncManager.lastRecordedRun,
                                     finishedRun: fileRunEnded(by: banner).map { ($0.started, $0.ended, $0.cancelled) },
                                     seen: NSApp.isActive && !toCapsule, dotWaits: toCapsule)
        return toCapsule
    }

    /// Where a Recent row's buttons go: this window's own doors (R12).
    var activityDoors: ActivityDoors {
        ActivityDoors(
            openInEdit: { path in _ = handOffToEditor(path) },
            reveal: { paths in
                guard let first = paths.first else { return }
                revealInBrowse(first, with: EditorRevealInBrowse.companions(of: paths), from: .activity)
            },
            download: { path in downloadFromEdit(path) },
            showInHistory: { runId in
                ActivityCenter.shared.historyRun = runId
                ActivityCenter.shared.tab = .history
                openWindow(id: ActivityCenter.windowID)
            },
            showInLog: { span in
                ActivityCenter.shared.logSpan = span
                ActivityCenter.shared.tab = .log
                openWindow(id: ActivityCenter.windowID)
            },
            showScan: { scan in
                // The card the scan keeps its controls on, in the main window, brought forward.
                ActivityCenter.shared.popoverIsOpen = false
                selectedWorkspace = .filing
                switch scan {
                case .readDocuments: selectedOrganizeLens = nil
                case .duplicates: selectedOrganizeLens = .duplicates
                case .restructure: selectedOrganizeLens = .restructure
                }
                // Show is often clicked in the Activity window, which is then the main window.
                openWindow(id: SyncCloudApp.mainWindowId)
            })
    }
}

/// **Edit's own results into Recent** (Run Room R18): its PDF tools' and Fill & Sign's, which set
/// their banner on Edit's model and never pass through the window's message. Observed here, in a
/// view of its own, so the window does not observe Edit's PDF model.
struct ActivityEditRecorder: View {
    @ObservedObject var tools: EditorPDFTools

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: tools.banner) { _, banner in
                guard let banner else { return }
                ActivityCenter.shared.record(banner, seen: NSApp.isActive)
            }
    }
}

/// **The result message over the lens or the editor** — Organize and Edit's half that has no file
/// list (`ResultMessageHome.workspace`). At the foot, centred, no wider than a sentence needs: the
/// lens's header card and Edit's format bar are at the top, and they are controls.
///
/// Also where a click in that half is noted, so the next message knows the reader is working here.
struct WorkspaceResultMessageHost: ViewModifier {
    let message: AnyView?
    /// The message's identity, which its arrival animates on.
    let messageID: UUID?
    let onClick: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                // Reports and declines every press — see `PaneClickReporter`.
                PaneClickReporter(onClick: onClick)
            }
            .overlay(alignment: .bottom) {
                if let message {
                    message
                        .frame(maxWidth: 560)
                        .padding(10)
                        .id(messageID)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .designAnimation(.spring(response: 0.4, dampingFraction: 0.9), value: messageID)
    }
}

/// Opens the Activity window when ``ActivityCenter`` asks — a notification's click, which arrives
/// in the app delegate, outside any view that can open a window.
struct ActivityWindowOpener: View {
    @ObservedObject var center: ActivityCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: center.windowRequests) { _, _ in openWindow(id: ActivityCenter.windowID) }
    }
}
