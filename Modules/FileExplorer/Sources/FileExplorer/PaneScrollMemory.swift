import AppKit
import Events
import SwiftUI
import Sync

/// Where a pane's columns were scrolled, kept while the pane itself is rebuilt.
///
/// A workspace switch rebuilds the pane. `ContentView` mounts it in a structurally different layout
/// arm for each of Browse, Organize, Edit and Compare, so SwiftUI tears the old pane down and builds
/// a new one. The folder survives — `browsePath` lives in `FileSyncManager` — but a scroll offset lived
/// only in the scroll view that held it, so every switch came back with the column stack at its first
/// column and every list at its top. This is the piece that outlives the pane: owned by the window's
/// `ContentView`, handed to each pane through `paneScrollMemory`, read back when the pane is rebuilt.
///
/// Two answers, kept differently on purpose:
///
/// - **The stack's horizontal position, per SURFACE** — one workspace's pane. The same stack is a
///   different width in Browse than in Organize's rail, so one shared position would be wrong
///   everywhere but where it was taken. It is kept with the tree root and column stack it was taken
///   on, and put back only onto that same stack; a pane whose stack changed while it was away reveals
///   its deepest column instead, the way a drill does (`PaneColumnsView.revealDeepestColumn`).
/// - **Each column's vertical position, per FOLDER** — shared by every surface and both sides. Rows are
///   one height everywhere, so a folder's position means the same thing wherever it is listed, and one
///   folder opening at different places depending on which workspace last scrolled it would be a
///   second thing to remember about it. That also means a column reopened later in the session — a
///   sibling clicked and the folder clicked again — opens where it was left, as Finder's does.
///
/// **A position is kept as what it MEANS, not only as a number.** A stack mostly rests at its far end
/// — every drill's reveal parks it there — and a list often rests at its bottom. Those are kept as "at
/// the end" and put back at the end of whatever the stack or list is NOW. A preview that has opened
/// since, a narrower window, a column resized in another workspace, a folder that lost files: each moves
/// where the end is, and a raw offset would land short of it — the first column showing, the deepest
/// one hidden behind the preview. Anything else is kept as the offset and put back clamped to what fits.
///
/// For the session only: the offsets belong to scroll views that do not outlive the launch. A plain
/// class, so recording on every scroll frame invalidates no view.
@MainActor
public final class PaneScrollMemory {
    /// `nonisolated` so `@State`'s initializer — which runs outside the actor — can build one.
    nonisolated public init() {}

    /// A kept position: where the scroll view rested, and whether that was the end of its range.
    struct Position: Equatable {
        var offset: CGFloat
        var atEnd: Bool

        /// The position of a scroll view resting at `offset` in `range`: clamped into it — an elastic
        /// overscroll is not a place — and at its end when within a point of it.
        static func resting(at offset: CGFloat, in range: ClosedRange<CGFloat>) -> Position {
            let clamped = min(max(offset, range.lowerBound), range.upperBound)
            return Position(offset: clamped, atEnd: range.upperBound - clamped <= 1)
        }

        /// Where this position lands in `range`: the end of it when it was kept at the end, the offset
        /// clamped into it otherwise.
        func resolved(in range: ClosedRange<CGFloat>) -> CGFloat {
            atEnd ? range.upperBound : min(max(offset, range.lowerBound), range.upperBound)
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

    /// A restore's FALLBACK: how many times it re-checks, `restoreStep` apart, before putting the
    /// position back with whatever the scroll view holds. It is a backstop, not the mechanism — a
    /// restore lands as soon as the columns or rows have laid out, which each probe is told directly
    /// (see `PaneStackScrollMemoryProbe.isSettled` and `ColumnListProbe`). Counted rather than
    /// clocked, for `revealHoldChecks`' reason: a starved main thread stretches the budget instead of
    /// burning it — under a loaded full test suite, a mount measured 18–43 s instead of 3.
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

    /// Whether the event being handled is the user scrolling — what drops a kept position still
    /// waiting to land: the user has put the view where they want it, and a restore landing after that
    /// would yank it back.
    ///
    /// A wheel or trackpad scroll only, and a fresh one. `NSApp.currentEvent` outlives its handling,
    /// and the keystroke or click that switched workspaces is still "current" while the rebuilt pane
    /// lays out — anything but a scroll read from it would drop every restore it was meant to make.
    static func isUserScroll(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .scrollWheel else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < 0.25
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
    /// No memory: a pane mounted without one scrolls exactly as it always did — every test harness,
    /// and any host that has not opted in.
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

/// Records the column STACK's horizontal position for this pane's surface, and puts it back when the
/// pane is rebuilt over the same stack. (Each column's own list is kept by `ColumnListProbe`.)
///
/// Mounted inside the stack's `ScrollView`, beside `PaneColumnsOverscrollReturn`, so the same ancestor
/// walk finds the stack's scroll view rather than a column's list.
///
/// **The restore lands as soon as the columns have laid out** — the stack's content reaching the width
/// the pane computed for it (`contentWidth`) — at the kept position resolved against the stack as it
/// is now. Until then there is nothing to measure the end against. It is dropped if the user scrolls
/// first, or if the stack changes under it (a drill, a ‹) before it lands: it spoke for the stack that
/// was. And it waits out an axis-lock hold rather than landing inside one, where `enforceHold` would
/// revert it.
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

        init(restores: Bool) {
            self.restores = restores
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Test seam: the scroll view this probe found, so a mounted test can assert it is the STACK's.
        var resolvedScroller: NSScrollView? { scroller }

        /// Test seam: how many fallback checks the last restore used before it landed. A restore that
        /// landed on its content settling uses a few at most; one that ran them all out waited for a
        /// room that was never coming, which is the three-second stall this probe was rebuilt to end.
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
                if pending != nil {
                    attemptsLeft = PaneScrollMemory.restoreAttempts
                    scheduleRestore()
                }
            }
            // This probe lives inside the stack's content, so it is laid out whenever the columns are
            // — which is exactly when they may have settled. Never applied from here (this is a layout
            // pass); only handed to the next turn.
            if pending != nil, isSettled() { scheduleRestore(immediately: true) }
        }

        private func scrolled() {
            if pending != nil, PaneScrollMemory.isUserScroll(NSApp.currentEvent) {
                drop(because: "scrolled first")
            }
            record()
        }

        private func drop(because reason: String) {
            pending = nil
            if let slot { Logger.shared.debug("[columns] scroll memory: \(slot.surface) stack position dropped — \(reason)") }
        }

        private func record() {
            guard pending == nil, let slot, let clip = scroller?.contentView else { return }
            slot.memory.recordStack(surface: slot.surface, treeRoot: treeRoot, components: components,
                                    position: .resting(at: clip.bounds.origin.x, in: clip.restingRangeX))
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

        /// Puts the stack back once its columns have laid out, and never from inside a layout pass or a
        /// bounds notification — `PaneColumnsOverscrollReturn` records what calling `setBoundsOrigin`
        /// from the notification did (it recursed until the app died).
        ///
        /// Two callers: the layout pass that found the columns settled (`fromLayout`), and the counted
        /// fallback, which re-arms itself until they settle and the stack is not held, or its checks
        /// run out. Only the fallback waits — a layout pass that finds the stack held leaves it to the
        /// one chain already counting, rather than starting a second.
        private func applyRestore(fromLayout: Bool) {
            guard let position = pending, let scroller, let slot else { return }
            if !isSettled() || holdGate?.isStackHeld == true {
                guard !fromLayout else { return }
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
            record()
            Logger.shared.debug("[columns] scroll memory: \(slot.surface) stack back at x=\(Int(x.rounded()))\(position.atEnd ? ", its end" : "")")
        }
    }
}
