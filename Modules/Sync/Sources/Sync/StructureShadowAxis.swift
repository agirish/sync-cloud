import Foundation

/// A year hiding inside a role name, beside siblings that spell it bare (ROADMAP v5 §4.3, built
/// as one of §5.2's detectors).
///
/// `IRS Docs - 2023` beside `2023` is a year folder that should be `2023`: a merge when the bare
/// year exists, a rename when it doesn't. A report, not a fix to the shape detector (adding the
/// rule to `isAxisValued` doesn't change its findings), so its value is naming the folder.
///
/// It must stay narrow: hundreds of names carry a non-bare year correctly (`01. Jan 2019`
/// statements, `2005 - 2006` fiscal years). Two conditions keep it quiet:
/// - the name carries **exactly one** year token — two is a range, which is an axis value of its
///   own, never a shadow of a single year;
/// - a **bare-year sibling exists** in the same family, so the family itself testifies that bare
///   years are its convention. `01. Jan 2019` sits among other months, not among years, and
///   never fires.
enum StructureShadowAxis {

    static func findings(in profile: FolderProfile,
                         childrenByParent: [String: [String]]) -> [StructureFinding] {
        var out: [StructureFinding] = []
        for (family, children) in childrenByParent {
            let bareYears = Set(children.map { ($0 as NSString).lastPathComponent }
                .filter { StructureDivergence.isBareYear($0) })
            guard !bareYears.isEmpty else { continue }

            for child in children {
                let name = (child as NSString).lastPathComponent
                guard !StructureDivergence.isBareYear(name),
                      let year = embeddedYear(in: name) else { continue }
                out.append(StructureFinding(
                    kind: .shadowAxis, family: family, subject: child,
                    detail: .shadowAxis(target: year, targetExists: bareYears.contains(year))))
            }
        }
        return out
    }

    /// The one year a name carries, or nil when it carries none or more than one.
    static func embeddedYear(in name: String) -> String? {
        let years = StructureDetectors.tokens(name).filter { StructureDivergence.isBareYear($0) }
        guard years.count == 1 else { return nil }
        return years[0]
    }
}
