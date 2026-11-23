import SwiftUI

/// A person's fact tiles in People (name, date of birth, home address, phone, email), each the
/// same three lines tall, laid out by the width they have:
///
/// - ``wideWidth`` and up, all five in one row, the address given the most room;
/// - from ``gridWidth``, a grid of four columns: Name (2) · Date of birth · Phone, then Home
///   address (2) · Email (2), so the long values share the left half;
/// - narrower, two columns: Name · Date of birth, the address across both, Phone · Email;
/// - under ``narrowWidth``, one column.
///
/// A one-column tile needs about 190 pt for “18 December 1974” and its copy icon, which is
/// where the four-column grid starts.
///
/// Every tile in a row is given the row's height, so they match at any text size. A section
/// without a phone (Archive, Household, a name as read) takes Name · Date of birth · Address (2).
struct VaultFactsLayout: Layout {
    enum Slot: Int, Comparable {
        case name, birth, address, phone, email
        static func < (a: Slot, b: Slot) -> Bool { a.rawValue < b.rawValue }
    }

    struct SlotKey: LayoutValueKey { static let defaultValue: Slot = .name }

    static let wideWidth: CGFloat = 1180
    static let gridWidth: CGFloat = 784
    static let narrowWidth: CGFloat = 400
    var spacing: CGFloat = 8

    /// Each tile's place: its index among the subviews, the row it is on, and its x and width.
    struct Place: Equatable {
        var index: Int
        var row: Int
        var x: CGFloat
        var width: CGFloat
    }

    /// Where `slots` go at `width`: the arrangement, worked out without measuring anything.
    static func places(_ slots: [Slot], width: CGFloat, spacing: CGFloat) -> [Place] {
        let present = Set(slots)
        // One row: every fact a person has, weighted by what it holds.
        if width >= wideWidth, present == [.name, .birth, .address, .phone, .email] {
            let weights: [Slot: CGFloat] = [.name: 1.5, .birth: 1, .address: 2.4, .phone: 1, .email: 1.5]
            let order = slots.indices.sorted { slots[$0] < slots[$1] }
            let room = width - spacing * CGFloat(order.count - 1)
            let total = order.reduce(0) { $0 + weights[slots[$1]]! }
            var x: CGFloat = 0
            return order.map { index in
                let w = room * weights[slots[index]]! / total
                defer { x += w + spacing }
                return Place(index: index, row: 0, x: x, width: w)
            }
        }
        let columns = width >= gridWidth ? 4 : width >= narrowWidth ? 2 : 1
        let withPhone = present.contains(.phone) || present.contains(.email)
        func span(_ slot: Slot) -> Int {
            switch slot {
            // Beside a phone, the name takes half a row of four; without one, Name · Date of
            // birth · Address (2) fill it. In two columns, Name sits beside the date of birth.
            case .name: return withPhone && columns == 4 ? 2 : 1
            case .birth, .phone: return 1
            case .address: return 2
            case .email: return columns == 4 ? 2 : 1
            }
        }
        // Four columns: Name · Date of birth · Phone fill the first row. Two: Name · Date of
        // birth, the address, then Phone · Email.
        let gridOrder: [Slot] = columns == 4 ? [.name, .birth, .phone, .address, .email] : [.name, .birth, .address, .phone, .email]
        let order = slots.indices.sorted { gridOrder.firstIndex(of: slots[$0])! < gridOrder.firstIndex(of: slots[$1])! }
        let column = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var row = 0, at = 0
        var out: [Place] = []
        for index in order {
            let s = min(span(slots[index]), columns)
            if at + s > columns { row += 1; at = 0 }
            out.append(Place(index: index, row: row, x: CGFloat(at) * (column + spacing),
                             width: column * CGFloat(s) + spacing * CGFloat(s - 1)))
            at += s
        }
        return out
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (places: [Place], heights: [CGFloat]) {
        let places = Self.places(subviews.map { $0[SlotKey.self] }, width: width, spacing: spacing)
        var heights: [CGFloat] = Array(repeating: 0, count: (places.map(\.row).max() ?? -1) + 1)
        for place in places {
            let size = subviews[place.index].sizeThatFits(ProposedViewSize(width: place.width, height: nil))
            heights[place.row] = max(heights[place.row], size.height)
        }
        return (places, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        guard !subviews.isEmpty else { return CGSize(width: width, height: 0) }
        let heights = arrange(subviews, width: width).heights
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (places, heights) = arrange(subviews, width: bounds.width)
        var tops: [CGFloat] = []
        var y = bounds.minY
        for height in heights { tops.append(y); y += height + spacing }
        for place in places {
            subviews[place.index].place(at: CGPoint(x: bounds.minX + place.x, y: tops[place.row]),
                                        proposal: ProposedViewSize(width: place.width, height: heights[place.row]))
        }
    }
}

extension View {
    /// Which fact this tile is, for ``VaultFactsLayout``.
    func factSlot(_ slot: VaultFactsLayout.Slot) -> some View {
        layoutValue(key: VaultFactsLayout.SlotKey.self, value: slot)
    }
}
