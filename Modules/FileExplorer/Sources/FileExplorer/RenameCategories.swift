import Foundation
import Sync

/// The rename backlog, reorganized category-first (v4.0 polish P10): sections by what the pass
/// would *do* — naming, reshuffling, padding — because the three operations ask different things
/// of the user, and 132 visually identical folder rows asked them to discover that by opening
/// every chevron. Within a section, folders group under their immediate parent directory.
///
/// **The plan stays the atomic unit.** A folder's steps are chosen against each other, so half a
/// plan is not a smaller plan — a section therefore holds whole folders, classified by the most
/// consequential kind of step their plan contains, and every button applies whole plans. A
/// mixed folder's pads ride along with its namings, exactly as they do when its own row button
/// is clicked; what the section changes is where you *find* the folder, not what applying it does.
enum RenameCategories {

    /// Most consequential first — the same rule `RenameBacklogTally` orders its prose by:
    /// naming gives a raw name a slot (a judgment about intent), a reshuffle touches files that
    /// were already correct, a pad only respells. This is also the section order on screen.
    enum Category: Int, CaseIterable, Equatable {
        case name, reshuffle, pad

        /// The step kind that puts a plan in this category.
        var kind: RenameStep.Kind {
            switch self {
            case .name: return .placed
            case .reshuffle: return .renumbered
            case .pad: return .tidied
            }
        }

        /// The pill's word, matching the tally's vocabulary exactly — one measurement, one name.
        var label: String {
            switch self {
            case .name: return "to name"
            case .reshuffle: return "to reshuffle"
            case .pad: return "to pad"
            }
        }

        /// The section's one-line definition — what this kind of change asks of you.
        var definition: String {
            switch self {
            case .name: return "Files that don't follow their folder's convention — a judgment about intent."
            case .reshuffle: return "Renumbers files that already have numbers — shifts their neighbours."
            case .pad: return "Leading zeros so one-digit ordinals sort before “10.” — mechanical."
            }
        }
    }

    /// One parent directory's folders inside a section.
    struct Group: Equatable {
        /// The immediate parent of the member folders' relative paths — "" at the root.
        let parent: String
        let plans: [RenamePlan]
        var fileCount: Int { plans.reduce(0) { $0 + $1.steps.count } }
    }

    struct Section: Equatable {
        let category: Category
        let groups: [Group]
        var plans: [RenamePlan] { groups.flatMap(\.plans) }
        var fileCount: Int { plans.reduce(0) { $0 + $1.steps.count } }
        /// Steps of the section's own kind — the pill's number. A mixed folder contributes its
        /// pads to `fileCount` (the button applies them) but not to this claim.
        var kindCount: Int {
            let kind = category.kind
            return plans.reduce(0) { $0 + $1.steps.filter { $0.kind == kind }.count }
        }
    }

    /// A plan's category: the most consequential kind of step it contains, nil for a plan of
    /// nothing but skips (those are the "left alone" footnote, not a section row).
    static func category(of plan: RenamePlan) -> Category? {
        for category in Category.allCases where plan.steps.contains(where: { $0.kind == category.kind }) {
            return category
        }
        return nil
    }

    /// The screen: sections in consequence order, present only when they report (the
    /// sections-vanish-at-zero rule), each grouped by immediate parent directory in path order,
    /// plans in path order within their group. Every plan with steps lands in exactly one
    /// section; skip-only plans are `leftAlone`.
    static func sections(_ plans: [RenamePlan]) -> [Section] {
        var buckets: [Category: [RenamePlan]] = [:]
        for plan in plans {
            guard let category = category(of: plan) else { continue }
            buckets[category, default: []].append(plan)
        }
        return Category.allCases.compactMap { category in
            guard let members = buckets[category], !members.isEmpty else { return nil }
            let byParent = Dictionary(grouping: members) { parent(of: $0.relativePath) }
            let groups = byParent.keys.sorted().map { key in
                Group(parent: key,
                      plans: byParent[key]!.sorted { $0.relativePath < $1.relativePath })
            }
            return Section(category: category, groups: groups)
        }
    }

    /// Plans the pass looked at and declined to touch entirely.
    static func leftAlone(_ plans: [RenamePlan]) -> [RenamePlan] {
        plans.filter { $0.steps.isEmpty && !$0.skips.isEmpty }
    }

    /// The immediate parent of a relative path — "" at the root.
    static func parent(of relativePath: String) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "/" ? "" : parent
    }

    /// The leaf a group row emphasizes; the group header already states the parent.
    static func leaf(of relativePath: String) -> String {
        (relativePath as NSString).lastPathComponent
    }

    /// The row's inline proof: one step of the section's own kind (never a ridden-along pad
    /// standing in for a naming), preferring the first in plan order.
    static func sampleStep(_ plan: RenamePlan, category: Category) -> RenameStep? {
        plan.steps.first { $0.kind == category.kind }
    }

    // MARK: Collapse defaults

    /// Whether a category's groups start collapsed. **Pad does, alone**: it is the mechanical
    /// bulk this screen exists to accept wholesale — its own definition line says so — and six
    /// hundred always-open rows are what made review a scroll instead of a read. The judgment
    /// categories (fix, name, reshuffle) start open, because their rows are the ones that need
    /// eyes before their buttons. Everything stays one chevron from the other state.
    static func groupsStartCollapsed(_ category: Category) -> Bool {
        category == .pad
    }

    /// Resolves a group's collapsed state from the default and the user's toggles. Stored as a
    /// TOGGLED set rather than a collapsed set, so the per-category default keeps applying to
    /// groups that arrive with the next scan instead of freezing whatever the first render saw.
    static func isCollapsed(category: Category, toggled: Bool) -> Bool {
        groupsStartCollapsed(category) != toggled
    }
}
