import AppKit
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
/// - **The stack's horizontal offset, per SURFACE** — one workspace's pane. The same stack is a
///   different width in Browse than in Organize's rail, so one shared offset would be wrong
///   everywhere but where it was taken. It is kept with the column stack it was taken on, and put back
///   only onto that same stack; a pane whose stack changed while it was away reveals its deepest column
///   instead, the way a drill does (`PaneColumnsView.revealDeepestColumn`).
/// - **Each column's vertical offset, per FOLDER.** Rows are one height on every surface, and Browse,
///   the rail and Compare's left pane are one pane over one tree — the reasoning that keeps the tree's
///   open folders per side rather than per workspace (`ContentView`'s `hostExpanded`).
///
/// For the session only: the column stack itself is not kept across launches, so an offset would have
/// nothing to belong to. A plain class, so recording on every scroll frame invalidates no view.
@MainActor
public final class PaneScrollMemory {
    /// `nonisolated` so `@State`'s initializer — which runs outside the actor — can build one.
    nonisolated public init() {}

    private struct StackRecord {
        var components: [String]
        var originX: CGFloat
    }

    private var stacks: [String: StackRecord] = [:]
    private var lists: [String: CGFloat] = [:]

    func recordStack(surface: String, components: [String], originX: CGFloat) {
        stacks[surface] = StackRecord(components: components, originX: originX)
    }

    /// The offset to put back — only onto the very stack it was taken on. `nil` for a surface seen for
    /// the first time, and for one whose stack has changed since.
    func stackOrigin(surface: String, components: [String]) -> CGFloat? {
        guard let record = stacks[surface], record.components == components else { return nil }
        return record.originX
    }

    func recordList(directory: String, originY: CGFloat) {
        lists[PaneBrowsePath.normalized(directory)] = originY
    }

    func listOrigin(directory: String) -> CGFloat? {
        lists[PaneBrowsePath.normalized(directory)]
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

// MARK: - The two probes

/// The FALLBACK for a restore: how many times it re-checks, `restoreStep` apart, before putting back
/// whatever the scroll view can hold. Columns and rows arrive a beat after the pane mounts, and a
/// restore made before they are there would be clamped to nothing and lost.
///
/// **The restore itself is event-driven; this only bounds it.** It lands the moment the scroll view
/// can hold the offset — on the stack probe's layout pass as the columns lay out, on the list's table
/// changing frame as its rows arrive. The first version waited on these timed checks alone, twenty of
/// them, and under a loaded main thread (a full test suite, measured: each mount took 18–43 s instead of
/// 3) the pane had not laid out when they ran out, so every restore landed at zero. Counted rather than
/// clocked for `revealHoldChecks`' reason: a starved main thread stretches the budget instead of burning
/// it.
private let restoreAttempts = 60
private let restoreStep: TimeInterval = 0.05

/// Records the column STACK's horizontal offset for this pane's surface, and puts it back when the pane
/// is rebuilt over the same stack.
///
/// Mounted inside the stack's `ScrollView`, beside `PaneColumnsOverscrollReturn`, so the same ancestor
/// walk finds the stack's scroll view rather than a column's list.
struct PaneStackScrollMemoryProbe: NSViewRepresentable {
    let slot: PaneScrollMemorySlot
    let components: [String]
    /// False while a reveal the host asked for is pending: that is an explicit navigation, and it wins.
    let restores: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.configure(slot: slot, components: components, restores: restores)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(slot: slot, components: components, restores: restores)
        view.rearm()
    }

    final class ProbeView: BoundedResolveView {
        private var slot: PaneScrollMemorySlot?
        private var components: [String] = []
        private var restores = true
        private weak var scroller: NSScrollView?
        private var observer: NSObjectProtocol?
        /// The offset waiting to be put back, read ONCE per mount — before anything this mount does can
        /// be recorded over it. Recording is held while it waits, for the same reason.
        private var pending: CGFloat?
        private var hasReadPending = false
        private var attemptsLeft = 0

        /// Test seam: the scroll view this probe found, so a mounted test can assert it is the STACK's.
        var resolvedScroller: NSScrollView? { scroller }

        func configure(slot: PaneScrollMemorySlot, components: [String], restores: Bool) {
            self.slot = slot
            self.components = components
            self.restores = restores
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
                    MainActor.assumeIsolated { self?.record() }
                }
                scroller = found
            }
            if !hasReadPending {
                hasReadPending = true
                pending = restores ? slot.memory.stackOrigin(surface: slot.surface, components: components) : nil
                if pending != nil {
                    attemptsLeft = restoreAttempts
                    scheduleRestore()
                }
            }
            // This probe lives inside the stack's content, so it is laid out whenever the columns are
            // — which is exactly when the offset may have become holdable. Never applied from here
            // (this is a layout pass); only handed to the next turn.
            if pending != nil, roomHolds() { scheduleRestore(immediately: true) }
        }

        private func record() {
            guard pending == nil, let slot, let clip = scroller?.contentView else { return }
            slot.memory.recordStack(surface: slot.surface, components: components, originX: clip.bounds.origin.x)
        }

        /// Whether the stack is wide enough, now, to hold the offset waiting to be put back.
        private func roomHolds() -> Bool {
            guard let target = pending, let clip = scroller?.contentView else { return false }
            return (clip.documentView?.frame.width ?? 0) - clip.bounds.width + 0.5 >= target
        }

        private func scheduleRestore(immediately: Bool = false) {
            if immediately {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.applyRestore(fromLayout: true) }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreStep) { [weak self] in
                    MainActor.assumeIsolated { self?.applyRestore(fromLayout: false) }
                }
            }
        }

        /// Puts the stack back once it is wide enough to hold the offset, and never from inside a layout
        /// pass or a bounds notification — `PaneColumnsOverscrollReturn` records what calling
        /// `setBoundsOrigin` from the notification did (it recursed until the app died).
        ///
        /// Two callers: the layout pass that found the room (`fromLayout`), and the counted fallback,
        /// which re-arms itself until the room arrives or its checks run out.
        private func applyRestore(fromLayout: Bool) {
            guard let target = pending, let scroller else { return }
            let clip = scroller.contentView
            if !roomHolds() {
                guard !fromLayout else { return }
                attemptsLeft -= 1
                if attemptsLeft > 0 {
                    scheduleRestore()
                    return
                }
            }
            // Released before the move, so the move's own notification records where it landed.
            pending = nil
            let origin = Self.legalOrigin(for: NSPoint(x: target, y: clip.bounds.origin.y), clip: clip)
            clip.setBoundsOrigin(origin)
            scroller.reflectScrolledClipView(clip)
            record()
        }
    }
}

/// Records one column LIST's vertical offset for its folder, and puts it back when a column for that
/// folder is mounted again.
///
/// A `.background` of the column's `List`, resolved through `PaneListResolver` by frame like the
/// column's other probes — the lists of a stack are siblings, and only their frames tell them apart.
struct ColumnScrollMemoryProbe: NSViewRepresentable {
    let slot: PaneScrollMemorySlot
    let directory: String
    /// False while a search hit or a row reveal is pending: that scroll is an explicit navigation.
    let restores: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.configure(slot: slot, directory: directory, restores: restores)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(slot: slot, directory: directory, restores: restores)
        view.rearm()
    }

    final class ProbeView: BoundedResolveView {
        private var slot: PaneScrollMemorySlot?
        private var directory = ""
        private var restores = true
        private weak var table: NSTableView?
        private var observer: NSObjectProtocol?
        private var pending: CGFloat?
        private var hasReadPending = false
        private var attemptsLeft = 0
        /// The table's frame, watched while a restore waits: a list's height arrives with its rows,
        /// which is exactly when a remembered offset becomes holdable.
        private var frameObserver: NSObjectProtocol?

        func configure(slot: PaneScrollMemorySlot, directory: String, restores: Bool) {
            if directory != self.directory {
                // A different folder is a different memory: start this one's read afresh.
                pending = nil
                hasReadPending = false
            }
            self.slot = slot
            self.directory = directory
            self.restores = restores
        }

        override func windowDidExit() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            observer = nil
            frameObserver = nil
            table = nil
            pending = nil
            hasReadPending = false
        }

        override func resolvePass() {
            guard window != nil, let slot else { return }
            if table?.window !== window || observer == nil {
                guard spendSearchBudget(),
                      let found = PaneListResolver.table(matching: self),
                      let clip = found.enclosingScrollView?.contentView else { return }
                if let observer { NotificationCenter.default.removeObserver(observer) }
                if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
                clip.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.record() }
                }
                found.postsFrameChangedNotifications = true
                frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: found, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.pending != nil, self.roomHolds() else { return }
                        self.scheduleRestore(immediately: true)
                    }
                }
                table = found
            }
            if !hasReadPending {
                hasReadPending = true
                pending = restores ? slot.memory.listOrigin(directory: directory) : nil
                if pending != nil {
                    attemptsLeft = restoreAttempts
                    scheduleRestore()
                }
            }
            if pending != nil, roomHolds() { scheduleRestore(immediately: true) }
        }

        /// Whether the list has its rows, and is tall enough now, to hold the offset waiting.
        private func roomHolds() -> Bool {
            guard let target = pending, let table, table.numberOfRows > 0,
                  let clip = table.enclosingScrollView?.contentView else { return false }
            return (clip.documentView?.frame.height ?? 0) - clip.bounds.height + 0.5 >= target
        }

        private func record() {
            guard pending == nil, let slot, let clip = table?.enclosingScrollView?.contentView else { return }
            slot.memory.recordList(directory: directory, originY: clip.bounds.origin.y)
        }

        private func scheduleRestore(immediately: Bool = false) {
            if immediately {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.applyRestore(fromEvent: true) }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreStep) { [weak self] in
                    MainActor.assumeIsolated { self?.applyRestore(fromEvent: false) }
                }
            }
        }

        /// Puts the list back once its rows are in — a column's rows load a beat after it mounts, and a
        /// restore onto an empty list would clamp to the top and be lost. Called when the table's frame
        /// or a layout pass shows the room (`fromEvent`), and by the counted fallback.
        private func applyRestore(fromEvent: Bool) {
            guard let target = pending, let table, let scroller = table.enclosingScrollView else { return }
            let clip = scroller.contentView
            if !roomHolds() {
                guard !fromEvent else { return }
                attemptsLeft -= 1
                if attemptsLeft > 0 {
                    scheduleRestore()
                    return
                }
            }
            pending = nil
            let origin = Self.legalOrigin(for: NSPoint(x: clip.bounds.origin.x, y: target), clip: clip)
            clip.setBoundsOrigin(origin)
            scroller.reflectScrolledClipView(clip)
            record()
        }
    }
}
