import AppKit
import Events
import SwiftUI
import Sync

/// Where a pane's columns were scrolled, kept while the pane itself is rebuilt.
///
/// A workspace switch mounts the pane in a different layout arm, so SwiftUI rebuilds it and its
/// scroll views. The folder survives in `FileSyncManager`; this keeps the offsets. Owned by the
/// window's `ContentView`, handed to each pane through `paneScrollMemory`.
///
/// - The stack's horizontal position is kept per surface (one workspace's pane), because the same
///   stack is a different width in each. It goes back only onto the same tree root and stack; a
///   stack that changed reveals its deepest column instead (`PaneColumnsView.revealDeepestColumn`).
/// - Each column's vertical position is kept per folder, shared by every surface and side, since
///   rows are one height everywhere. A column reopened later opens where it was left, as in Finder.
///
/// A position at the end of its range is kept as "at the end" and restored to the end of the range
/// as it is now, so a preview that opened since or a narrower window can't leave the deepest column
/// hidden. Anything else is restored as the offset, clamped. Session-only, and a plain class so
/// recording on every scroll frame invalidates no view.
@MainActor
public final class PaneScrollMemory {
    /// `nonisolated` so `@State`'s initializer — which runs outside the actor — can build one.
    nonisolated public init() {}

    /// A kept position: where the scroll view rested, and whether that was the end of its range.
    struct Position: Equatable {
        var offset: CGFloat
        var atEnd: Bool

        /// The position of a scroll view resting at `offset` in `range`: clamped into it, since an
        /// elastic overscroll is not a place, and at its end when within a point of it.
        ///
        /// A list with no room to scroll is kept at its start, not its end, or a short column that
        /// later grew would restore to its bottom. `noRoomIsEnd` is the stack's rule: a row of
        /// columns that fits shows its deepest column, so in a narrower window its end is still
        /// where that column is.
        static func resting(at offset: CGFloat, in range: ClosedRange<CGFloat>,
                            noRoomIsEnd: Bool = false) -> Position {
            let clamped = min(max(offset, range.lowerBound), range.upperBound)
            let scrolls = range.upperBound - range.lowerBound > 1
            return Position(offset: clamped, atEnd: (scrolls || noRoomIsEnd) && range.upperBound - clamped <= 1)
        }

        /// Where this position lands in `range`: the end of it when it was kept at the end, the offset
        /// clamped into it otherwise.
        func resolved(in range: ClosedRange<CGFloat>) -> CGFloat {
            atEnd ? range.upperBound : min(max(offset, range.lowerBound), range.upperBound)
        }

        /// Kept at the start of its range, where the scroll view rests anyway, so restoring it moves
        /// nothing and there is nothing to hide.
        func isAtStart(of range: ClosedRange<CGFloat>) -> Bool {
            !atEnd && offset <= range.lowerBound + 0.5
        }
    }

    private struct StackRecord {
        var treeRoot: String
        var components: [String]
        var position: Position
    }

    private var stacks: [String: StackRecord] = [:]
    private var lists: [String: Position] = [:]
    /// `lists`' keys, oldest first — what `listCapacity` drops from.
    private var listOrder: [String] = []

    /// How many folders' list positions are kept: one small entry per folder ever scrolled in the
    /// session, oldest dropped first, so a long session cannot grow the table without bound.
    static let listCapacity = 500

    /// A restore's fallback: how many checks, `restoreStep` apart, before the position goes back
    /// regardless. A restore normally lands as soon as the content lays out (see
    /// `PaneStackScrollMemoryProbe.isSettled` and `ColumnListProbe`). Counted, not clocked, for
    /// `revealHoldChecks`' reason: a starved main thread stretches the budget instead of burning it.
    static let restoreAttempts = 60
    static let restoreStep: TimeInterval = 0.05

    func recordStack(surface: String, treeRoot: String, components: [String], position: Position) {
        stacks[surface] = StackRecord(treeRoot: PaneBrowsePath.normalized(treeRoot),
                                      components: components, position: position)
    }

    /// The position to put back — only onto the very stack it was taken on, under the same tree root.
    /// `nil` for a surface seen for the first time, and for one whose stack has changed since.
    func stackPosition(surface: String, treeRoot: String, components: [String]) -> Position? {
        guard let record = stacks[surface], record.treeRoot == PaneBrowsePath.normalized(treeRoot),
              record.components == components else { return nil }
        return record.position
    }

    func recordList(directory: String, position: Position) {
        let key = PaneBrowsePath.normalized(directory)
        guard lists.updateValue(position, forKey: key) == nil else { return }
        listOrder.append(key)
        if listOrder.count > Self.listCapacity { lists[listOrder.removeFirst()] = nil }
    }

    func listPosition(directory: String) -> Position? {
        lists[PaneBrowsePath.normalized(directory)]
    }

    /// Whether the event being handled is the user scrolling, which drops a position still waiting
    /// to land: a restore after that would yank the view back.
    ///
    /// A fresh wheel or trackpad scroll only. `NSApp.currentEvent` outlives its handling, so the
    /// keystroke or click that switched workspaces still reads as current while the rebuilt pane
    /// lays out, and counting it would drop every restore.
    static func isUserScroll(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .scrollWheel else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < 0.25
    }
}

/// A scroll view held clear while its kept position waits to land.
///
/// A restore lands on the turn after the layout pass that finds the content settled, never inside
/// the pass (see the probes' `applyRestore`), so a rebuilt pane's first frame would show the stack
/// at its first column and the lists at the top, then jump. The scroll view is drawn clear from the
/// pass that reads the kept position until the position lands.
///
/// Lifted on every way out (landed, dropped, the pane leaving the window) and at the fallback's
/// first check that finds the content unsettled: a late jump is better than a missing pane.
@MainActor
struct PaneScrollVeil {
    private weak var covered: NSScrollView?

    /// Holds `scroller` clear until `lift()`.
    mutating func cover(_ scroller: NSScrollView) {
        lift()
        scroller.alphaValue = 0
        covered = scroller
    }

    mutating func lift() {
        covered?.alphaValue = 1
        covered = nil
    }
}

extension NSClipView {
    /// Where this clip's origin can rest horizontally — the band `BoundedResolveView.legalOrigin`
    /// clamps to.
    var restingRangeX: ClosedRange<CGFloat> {
        let y = bounds.origin.y
        let low = BoundedResolveView.legalOrigin(for: NSPoint(x: -.greatestFiniteMagnitude, y: y), clip: self).x
        let high = BoundedResolveView.legalOrigin(for: NSPoint(x: .greatestFiniteMagnitude, y: y), clip: self).x
        return low...max(low, high)
    }

    /// Where this clip's origin can rest vertically.
    var restingRangeY: ClosedRange<CGFloat> {
        let x = bounds.origin.x
        let low = BoundedResolveView.legalOrigin(for: NSPoint(x: x, y: -.greatestFiniteMagnitude), clip: self).y
        let high = BoundedResolveView.legalOrigin(for: NSPoint(x: x, y: .greatestFiniteMagnitude), clip: self).y
        return low...max(low, high)
    }
}

/// A pane's handle on the window's memory: the memory, and which surface this pane is — see
/// `EnvironmentValues.paneScrollMemory`.
public struct PaneScrollMemorySlot: Equatable, Sendable {
    public let memory: PaneScrollMemory
    /// Names the pane the offsets belong to — a workspace and a side. Only compared, never parsed.
    public let surface: String

    public init(memory: PaneScrollMemory, surface: String) {
        self.memory = memory
        self.surface = surface
    }

    public static func == (lhs: PaneScrollMemorySlot, rhs: PaneScrollMemorySlot) -> Bool {
        lhs.memory === rhs.memory && lhs.surface == rhs.surface
    }
}

private struct PaneScrollMemoryKey: EnvironmentKey {
    /// No memory: a pane mounted without one keeps no positions. Every test harness, and any host
    /// that has not opted in.
    static let defaultValue: PaneScrollMemorySlot? = nil
}

extension EnvironmentValues {
    /// Where this pane's scroll offsets are kept across the pane being rebuilt, or `nil` for none.
    /// Set by `ContentView` around each pane; see `PaneScrollMemory`.
    public var paneScrollMemory: PaneScrollMemorySlot? {
        get { self[PaneScrollMemoryKey.self] }
        set { self[PaneScrollMemoryKey.self] = newValue }
    }
}

// MARK: - The stack's probe

/// Records the column stack's horizontal position for this pane's surface, and puts it back when the
/// pane is rebuilt over the same stack. (Each column's list is kept by `ColumnListProbe`.) Mounted
/// inside the stack's `ScrollView`, beside `PaneColumnsOverscrollReturn`, so the same ancestor walk
/// finds the stack's scroll view, not a column's list.
///
/// The restore lands once the stack's content reaches `contentWidth`, resolved against the stack as
/// it is then. It is dropped if the user scrolls first or the stack changes before it lands (a
/// drill, a ‹), and it waits out an axis-lock hold, inside which `enforceHold` would revert it.
struct PaneStackScrollMemoryProbe: NSViewRepresentable {
    let slot: PaneScrollMemorySlot
    let treeRoot: String
    let components: [String]
    /// How wide the stack's content is once its columns have laid out: every column's width and the
    /// deselect filler after them.
    let contentWidth: CGFloat
    let holdGate: PaneColumnHoldGate
    /// Whether this mount may put a kept position back. Read ONCE, when the pane mounts — see
    /// `PaneColumnsView.stackRestores`.
    let restores: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(restores: restores)
        view.configure(slot: slot, treeRoot: treeRoot, components: components,
                       contentWidth: contentWidth, holdGate: holdGate)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(slot: slot, treeRoot: treeRoot, components: components,
                       contentWidth: contentWidth, holdGate: holdGate)
        view.rearm()
    }

    final class ProbeView: BoundedResolveView {
        private let restores: Bool
        private var slot: PaneScrollMemorySlot?
        private var treeRoot = ""
        private var components: [String] = []
        private var contentWidth: CGFloat = 0
        private var holdGate: PaneColumnHoldGate?
        private weak var scroller: NSScrollView?
        private var observer: NSObjectProtocol?
        /// The kept position waiting to be put back, read ONCE per mount — before anything this mount
        /// does can be recorded over it. Recording is held while it waits, for the same reason.
        private var pending: PaneScrollMemory.Position?
        private var hasReadPending = false
        private var attemptsLeft = 0
        private var veil = PaneScrollVeil()

        init(restores: Bool) {
            self.restores = restores
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Test seam: the scroll view this probe found, so a mounted test can assert it is the STACK's.
        var resolvedScroller: NSScrollView? { scroller }

        /// Test seam: how many fallback checks the last restore used before it landed. One that landed
        /// on its content settling uses a few at most; one that used them all waited for a layout
        /// that never came, and stalled the restore for the whole fallback.
        private(set) var checksUsedByLastRestore: Int?

        func configure(slot: PaneScrollMemorySlot, treeRoot: String, components: [String],
                       contentWidth: CGFloat, holdGate: PaneColumnHoldGate) {
            if pending != nil, components != self.components || treeRoot != self.treeRoot {
                drop(because: "the stack changed before it landed")
            }
            self.slot = slot
            self.treeRoot = treeRoot
            self.components = components
            self.contentWidth = contentWidth
            self.holdGate = holdGate
        }

        override func windowDidExit() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            scroller = nil
            pending = nil
            veil.lift()
            hasReadPending = false
        }

        override func resolvePass() {
            guard window != nil, let slot else { return }
            if scroller?.window !== window || observer == nil {
                guard spendSearchBudget(),
                      let found = PaneColumnsOverscrollReturn.WatchdogView.findStackScrollView(from: self)
                else { return }
                if let observer { NotificationCenter.default.removeObserver(observer) }
                let clip = found.contentView
                clip.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                }
                scroller = found
            }
            if !hasReadPending {
                hasReadPending = true
                let kept = slot.memory.stackPosition(surface: slot.surface, treeRoot: treeRoot,
                                                     components: components)
                if restores {
                    pending = kept
                } else if kept != nil {
                    Logger.shared.debug("[columns] scroll memory: \(slot.surface) stack left to a reveal")
                }
                if let pending, let scroller, restoreCanMove(pending, clip: scroller.contentView) {
                    veil.cover(scroller)
                }
                if pending != nil {
                    attemptsLeft = PaneScrollMemory.restoreAttempts
                    scheduleRestore()
                }
            }
            // Laid out whenever the columns are, which is when they may have settled. Never applied
            // from a layout pass; only handed to the next turn.
            if pending != nil, isSettled() { scheduleRestore(immediately: true) }
        }

        /// Whether putting `position` back can move the stack, and so whether hiding it hides
        /// anything. Not when it is kept at its left edge, nor at the end of a row of columns that
        /// fits the viewport (recorded as at its end by `noRoomIsEnd`, and that end is its start).
        /// Covering those would blank the whole Columns pane for a frame on each switch back.
        private func restoreCanMove(_ position: PaneScrollMemory.Position, clip: NSClipView) -> Bool {
            if position.isAtStart(of: clip.restingRangeX) { return false }
            if position.atEnd, clip.bounds.width > 0, contentWidth <= clip.bounds.width + 1,
               clip.bounds.origin.x <= clip.restingRangeX.lowerBound + 0.5 { return false }
            return true
        }

        private func scrolled() {
            if pending != nil, PaneScrollMemory.isUserScroll(NSApp.currentEvent) {
                drop(because: "scrolled first")
            }
            record()
        }

        private func drop(because reason: String) {
            pending = nil
            veil.lift()
            if let slot { Logger.shared.debug("[columns] scroll memory: \(slot.surface) stack position dropped — \(reason)") }
        }

        private func record() {
            guard pending == nil, let slot, let clip = scroller?.contentView else { return }
            slot.memory.recordStack(surface: slot.surface, treeRoot: treeRoot, components: components,
                                    position: .resting(at: clip.bounds.origin.x, in: clip.restingRangeX,
                                                       noRoomIsEnd: true))
        }

        /// Whether the columns have laid out: the stack's content is as wide as the pane made it, and
        /// the viewport has a width to measure against.
        private func isSettled() -> Bool {
            guard let clip = scroller?.contentView, let document = clip.documentView,
                  clip.bounds.width > 0 else { return false }
            return abs(document.frame.width - contentWidth) <= 1
        }

        private func scheduleRestore(immediately: Bool = false) {
            if immediately {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.applyRestore(fromLayout: true) }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + PaneScrollMemory.restoreStep) { [weak self] in
                    MainActor.assumeIsolated { self?.applyRestore(fromLayout: false) }
                }
            }
        }

        /// Puts the stack back once its columns have laid out, never from inside a layout pass or a
        /// bounds notification: `setBoundsOrigin` from the notification recurses until the app dies
        /// (see `PaneColumnsOverscrollReturn`).
        ///
        /// Two callers: the layout pass that found the columns settled (`fromLayout`), and the counted
        /// fallback, which re-arms until they settle and the stack is not held, or its checks run out.
        /// Only the fallback waits, so a held stack never starts a second chain.
        private func applyRestore(fromLayout: Bool) {
            guard let position = pending, let scroller, let slot else { return }
            if !isSettled() || holdGate?.isStackHeld == true {
                guard !fromLayout else { return }
                veil.lift()
                attemptsLeft -= 1
                if attemptsLeft > 0 {
                    scheduleRestore()
                    return
                }
                Logger.shared.debug("[columns] scroll memory: \(slot.surface) stack waited out \(PaneScrollMemory.restoreAttempts) checks; putting its position back anyway")
            }
            // Released before the move, so the move's own notification records where it landed.
            pending = nil
            checksUsedByLastRestore = PaneScrollMemory.restoreAttempts - attemptsLeft
            let clip = scroller.contentView
            let x = position.resolved(in: clip.restingRangeX)
            clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
            scroller.reflectScrolledClipView(clip)
            veil.lift()
            record()
            Logger.shared.debug("[columns] scroll memory: \(slot.surface) stack back at x=\(Int(x.rounded()))\(position.atEnd ? ", its end" : "")")
        }
    }
}
