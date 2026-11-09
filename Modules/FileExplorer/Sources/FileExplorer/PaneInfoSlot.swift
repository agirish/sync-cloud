import AppKit
import SwiftUI

/// Where a pane's Info column goes: the room the pane's list keeps for it, and where that room is
/// on screen.
///
/// The app draws Info over the list, never inside it: Space's Quick Look and ↩'s rename stay the
/// list's own, and `FileTreeView` stays `Equatable`, which a view passed into it would undo. The
/// list keeps the room instead. Columns keeps it after the deepest column, inside the scrolling
/// stack, so Info follows the columns and scrolls with them as Finder's preview column does; Tree
/// keeps it at the list's trailing edge. The list writes the room's frame here, in the host's
/// coordinate space (`coordinateSpace`), and the app's overlay reads it.
///
/// Observable, so only the views that read it (the overlay, the action bar's clearance) redraw as
/// the stack scrolls; the list writes it and never reads it.
@MainActor @Observable
public final class PaneInfoSlot {
    /// The name of the host's coordinate space: the view Info is drawn over.
    public static let coordinateSpace = "PaneInfoSlot.host"
    /// The id the column stack gives the room, so a reveal can scroll to it.
    public static let stackID = "PaneInfoSlot.column"

    /// Which edge of Info its divider is on: the trailing edge after a column, as every column's
    /// is; the leading edge at a Tree list's trailing edge.
    public enum DividerEdge: Equatable, Sendable { case leading, trailing }

    /// What a list reports about its room, all in the host's space.
    public struct Room: Equatable, Sendable {
        /// Where the room is.
        public var frame: CGRect
        /// How wide the host is, so the action bar can keep clear of the room.
        public var hostWidth: CGFloat
        /// The visible region of the scroll view holding the room, in Columns: Info is masked to it,
        /// as the columns are clipped to it, when the stack is scrolled back past Info. Nil in Tree,
        /// whose room does not scroll.
        public var viewport: CGRect?
        public var dividerEdge: DividerEdge

        public init(frame: CGRect, hostWidth: CGFloat, viewport: CGRect?, dividerEdge: DividerEdge) {
            self.frame = frame
            self.hostWidth = hostWidth
            self.viewport = viewport
            self.dividerEdge = dividerEdge
        }

        /// How much of the host's trailing side the room covers: what a bar centred beside Info
        /// leaves out. Zero once Info is scrolled out past the host's edge.
        public var trailingClearance: CGFloat { max(0, hostWidth - frame.minX) }
    }

    /// The room the list keeps now, or nil while it keeps none.
    public private(set) var room: Room?

    /// The column stack's scroll view, so a swipe that starts over Info also reaches the columns
    /// it sits among (`forwardsWheelGesturesToColumns`). Info is drawn over the stack, not inside
    /// it, so AppKit sends such a swipe to Info alone. Weak: the stack owns it; nil in Tree.
    @ObservationIgnored public internal(set) weak var stackScroller: NSScrollView?

    /// Which reporter wrote last, so a list that is leaving (Tree giving way to Columns) cannot clear
    /// the room the arriving one has just written.
    private var owner: UUID?

    public init() {}

    func report(_ room: Room, owner: UUID) {
        self.owner = owner
        if self.room != room { self.room = room }
    }

    func withdraw(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        room = nil
    }
}

/// The room a pane's list keeps for Info: how wide, and where to report it. Set by the app's Info
/// host on the list; nil, the default, keeps none, so every other surface that draws a
/// `FileTreeView` is unchanged.
public struct PaneInfoRoom: Equatable, Sendable {
    public let width: CGFloat
    public let slot: PaneInfoSlot

    public init(width: CGFloat, slot: PaneInfoSlot) {
        self.width = width
        self.slot = slot
    }

    nonisolated public static func == (lhs: PaneInfoRoom, rhs: PaneInfoRoom) -> Bool {
        lhs.width == rhs.width && lhs.slot === rhs.slot
    }
}

private struct PaneInfoRoomKey: EnvironmentKey {
    static let defaultValue: PaneInfoRoom? = nil
}

public extension EnvironmentValues {
    var paneInfoRoom: PaneInfoRoom? {
        get { self[PaneInfoRoomKey.self] }
        set { self[PaneInfoRoomKey.self] = newValue }
    }
}

extension View {
    /// Reports this view's frame as the room Info is drawn in.
    func reportsPaneInfoRoom(_ slot: PaneInfoSlot, edge: PaneInfoSlot.DividerEdge) -> some View {
        modifier(PaneInfoRoomReporter(slot: slot, edge: edge))
    }

    /// Keeps this view (the action bar and result message) clear of Info's room: it centres over
    /// what is left of the host, not over Info. Nothing without a room.
    public func clearsPaneInfo() -> some View {
        modifier(PaneInfoClearance())
    }
}

private struct PaneInfoRoomReporter: ViewModifier {
    let slot: PaneInfoSlot
    let edge: PaneInfoSlot.DividerEdge
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: PaneInfoSlot.Room?.self) { proxy in
                let host = NamedCoordinateSpace.named(PaneInfoSlot.coordinateSpace)
                guard let hostBounds = proxy.bounds(of: host) else { return nil }
                let frame = proxy.frame(in: host)
                // The innermost scroll view's bounds come back in this view's own space; moved by
                // this view's origin, they are in the host's.
                let viewport = edge == .trailing
                    ? proxy.bounds(of: .scrollView).map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
                    : nil
                return PaneInfoSlot.Room(frame: frame, hostWidth: hostBounds.width,
                                         viewport: viewport, dividerEdge: edge)
            } action: { room in
                if let room { slot.report(room, owner: owner) } else { slot.withdraw(owner: owner) }
            }
            .onDisappear { slot.withdraw(owner: owner) }
    }
}

private struct PaneInfoClearance: ViewModifier {
    @Environment(\.paneInfoRoom) private var room

    func body(content: Content) -> some View {
        content.padding(.trailing, room?.slot.room?.trailingClearance ?? 0)
    }
}

/// A Tree list's room for Info: a strip at its trailing edge, reported as the room. The rows end
/// where it begins, and the strip shows the list's own surface, as a column's empty space does.
struct PaneInfoTrailingRoom: ViewModifier {
    let room: PaneInfoRoom?

    // One shape with or without a room: a branch here would rebuild the List, and lose its scroll
    // position, each time Info opened or closed.
    func body(content: Content) -> some View {
        content
            .padding(.trailing, room?.width ?? 0)
            .overlay(alignment: .trailing) {
                if let room {
                    Color.clear
                        .frame(width: room.width)
                        .reportsPaneInfoRoom(room.slot, edge: .leading)
                }
            }
    }
}
