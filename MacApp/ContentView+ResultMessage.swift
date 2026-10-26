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
/// **Messages with no pane of their own** — a background run finishing, a scan, a sync from the
/// Differences list — follow the same rule: they show where the reader is working now. Decision BY
/// sends background work to the toolbar capsule once it exists; that session should take those
/// messages from here (see the side-session notes, 2026-10-25).
enum ResultMessageRoute {
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
        ResultMessageRoute.home(layout: contentLayout, focusedPaneIsLeft: focusedPane != .right,
                                lastWorkedInPane: resultMessageInPane)
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
        syncManager.banner = result.banner
    }

    /// Everything a new message owes beyond its timer: VoiceOver hears it (TE211), and a rule offer
    /// riding in the message it replaced leaves with that message (CB).
    func resultMessageChanged(to banner: OperationBanner?) {
        lensSession.retireRuleOffer(unlessRiding: banner?.id)
        if paneToolResultDoors?.banner.id != banner?.id { paneToolResultDoors = nil }
        guard let banner else { return }
        OperationBannerView.announce(banner, offersUndo: banner.isUndoable && (undoManager?.canUndo ?? false)
                                     && runWriteLockReason == nil)
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
