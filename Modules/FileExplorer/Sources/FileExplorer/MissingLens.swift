import AppKit
import Design
import SwiftUI
import Sync

/// Organize ▸ Missing: the statements each account folder lacks, read from file names.
///
/// One row per account with a cell a month for the last three years, and a detail column listing
/// every gap. It lists and counts; the only things it changes are what is counted (Hide Account,
/// Stop Tracking, Not Expected, Count as Missing), never a file. ``MissingLensModel`` decides what
/// is drawn; this lays it out.
struct MissingLensView: View {
    @ObservedObject var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }
    private var density: ListDensityMetrics { (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics }

    let providerName: String?
    /// The header card's live query: free text over accounts and months.
    let query: String
    /// Whether an account path, relative to the walked root, is inside Organize's scope.
    let inScope: (String) -> Bool
    /// Starts the names-only walk.
    let onFind: () -> Void
    /// Reveals an absolute path in Finder.
    let onReveal: (String) -> Void
    /// Opens another lens scoped to an absolute folder: To File for a waiting statement, Renames
    /// for unnamed files.
    let onShowIn: (OrganizeLens, String) -> Void

    @State private var filter: MissingFilter = .missing
    /// The year check: nil for the whole history.
    @State private var year: Int?
    /// The selected account's path, relative to the walked root.
    @State private var selection: String?

    private typealias Account = MissingStatements.Account
    private typealias Gap = MissingStatements.Gap

    var body: some View {
        VStack(spacing: 0) {
            if let report = syncManager.missingReport {
                reportBody(MissingLensModel(report: report, filter: filter, query: query, year: year, inScope: inScope))
            } else if syncManager.isFindingMissingStatements {
                readingState
            } else {
                introState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .columnSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    // MARK: Before a report

    private var introState: some View {
        LensSetupCard(
            intro: LensIntros.missing(providerName: providerName),
            accent: glassHue.accentColor,
            triggerTitle: OrganizePass.missing.runTitle,
            triggerSymbol: OrganizeLens.missing.symbol,
            triggerHelp: "Read the names of the statements in every account folder and list the months that never arrived. No file is opened.",
            samplesTitle: "What the list looks like",
            samplesAccessibility: "Example of the list: an account, the months it lacks, and how many statements that is. These are samples, not your accounts.",
            onStart: onFind
        ) {
            LensSetupSampleRow {
                Image(systemName: "calendar.badge.exclamationmark").frame(width: 16)
                Text("Utilities · Power").scaledFont(.caption).lineLimit(1)
                Text("Aug–Dec 2025").scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                Text("5").scaledFont(.caption.monospaced()).foregroundStyle(.secondary)
            }
            LensSetupSampleRow {
                Image(systemName: "calendar.badge.exclamationmark").frame(width: 16)
                Text("Bank · Checking 1234").scaledFont(.caption).lineLimit(1)
                Text("Mar 2025").scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                Text("1").scaledFont(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var readingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(syncManager.missingLifecycle.status ?? "Reading names…")
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Button("Cancel") { syncManager.cancelFindingMissingStatements() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: The report

    @ViewBuilder
    private func reportBody(_ model: MissingLensModel) -> some View {
        let groups = model.groups
        let selected = selectedAccount(in: model, groups: groups)
        VStack(spacing: 0) {
            topBar(model)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if groups.isEmpty {
                        emptyState(model)
                    } else {
                        list(model, groups: groups, selected: selected)
                    }
                    Divider()
                    legend
                }
                Divider()
                detail(model, selected)
                    .frame(width: 290)
            }
        }
    }

    /// The selected account, or the first row when the selection is no longer listed.
    private func selectedAccount(in model: MissingLensModel, groups: [MissingLensModel.Group]) -> MissingStatements.Account? {
        let listed = groups.flatMap(\.accounts)
        return listed.first { $0.path == selection } ?? listed.first
    }

    private func topBar(_ model: MissingLensModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.summary)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if syncManager.isFindingMissingStatements {
                    ProgressView().controlSize(.small)
                }
                Button(OrganizePass.missing.rescanTitle, systemImage: "arrow.clockwise", action: onFind)
                    .help("Read the names again. Nothing is opened.")
                    .accessibilityLabel(OrganizePass.missing.rescanAccessibilityLabel(for: .missing))
                    .disabled(syncManager.isFindingMissingStatements)
                Button("Copy List", systemImage: "doc.on.doc") { copy(model.copyText(rootName: rootName)) }
                    .help("Copy the list as text, one account a line. Hidden accounts and gaps marked Not Expected are left out.")
                    .disabled(model.count(for: .missing) == 0)
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                ForEach(MissingFilter.allCases) { item in
                    filterChip(item, count: model.count(for: item))
                }
                Spacer(minLength: 0)
                yearPicker(model)
            }
            if let note = model.notCheckedNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, density.cardListPadding + 4)
        .padding(.vertical, 10)
    }

    /// The year check: narrow the lens to what one year lacks, for closing its books.
    private func yearPicker(_ model: MissingLensModel) -> some View {
        Picker("Year", selection: $year) {
            Text("All Years").tag(Int?.none)
            ForEach(model.years, id: \.year) { choice in
                Text("\(String(choice.year)) · \(choice.counted)").tag(Int?.some(choice.year))
            }
            // A year picked and since emptied stays in the list, so the picker can show it.
            if let year, !model.years.contains(where: { $0.year == year }) {
                Text(String(year)).tag(Int?.some(year))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Show only what one year is missing.")
        .accessibilityLabel("Year")
    }

    private func filterChip(_ item: MissingFilter, count: Int) -> some View {
        let isOn = filter == item
        return Button {
            filter = item
            selection = nil
        } label: {
            HStack(spacing: 5) {
                Text(item.title).scaledFont(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                Text("\(count)").scaledFont(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? glassHue.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(MissingLensModel.count(count, "account"))")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: The list

    private func list(_ model: MissingLensModel, groups: [MissingLensModel.Group], selected: MissingStatements.Account?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    groupHeader(group)
                    ForEach(group.accounts, id: \.path) { account in
                        row(account, in: group.section, model: model, isSelected: account.path == selected?.path)
                    }
                }
            }
            .padding(.horizontal, density.cardListPadding)
            .padding(.vertical, 6)
        }
    }

    private func groupHeader(_ group: MissingLensModel.Group) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(group.section.title).scaledFont(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(MissingLensModel.count(group.accounts.count, "account") + (group.section.note.map { " · \($0)" } ?? ""))
                .scaledFont(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ account: MissingStatements.Account, in section: MissingLensModel.Section,
                     model: MissingLensModel, isSelected: Bool) -> some View {
        Button {
            selection = account.path
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(MissingLensModel.title(account))
                        .scaledFont(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(MissingLensModel.subtitle(account, in: section))
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MissingMonthStrip(cells: model.cells(for: account), earlier: model.earlierTag(for: account),
                                  accent: glassHue.accentColor)
                pill(account, in: section)
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, density.cardListPadding > 8 ? 6 : 4)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(isSelected ? glassHue.accentColor.opacity(0.15) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MissingLensModel.spoken(account))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { rowMenu(account, model: model) }
    }

    @ViewBuilder
    private func pill(_ account: MissingStatements.Account, in section: MissingLensModel.Section) -> some View {
        switch section {
        case .expectedNext:
            tag(account.gaps.first { $0.kind == .expectedNext }.map { $0.first.label } ?? "", color: glassHue.accentColor)
        case .notTracked:
            tag(account.newest.label, color: .secondary)
        case .hiddenAccounts:
            tag("hidden", color: .secondary)
        case .notExpected:
            tag("not expected", color: .secondary)
        default:
            if account.counted > 0 {
                tag("\(account.counted)", color: SemanticColor.warning)
            } else {
                tag(MissingLensModel.section(of: account) == nil ? "complete" : "not counted", color: .secondary)
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .scaledFont(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            // The colour stays in the wash; a word inked in its own wash is too faint to read.
            .foregroundStyle(PillVariant.labelInk(for: color))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.22)))
            .lineLimit(1)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.filed, "filed")
            legendItem(.missing, "missing, counted")
            legendItem(.uncounted, "silence, not counted")
            legendItem(.partial, "one of two")
            legendItem(.waiting, "waiting in To File")
            legendItem(.expectedNext, "expected next")
            legendItem(.noneExpected, "none expected")
            Spacer(minLength: 0)
        }
        .scaledFont(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, density.cardListPadding + 8)
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }

    private func legendItem(_ cell: MissingLensModel.Cell, _ label: String) -> some View {
        HStack(spacing: 5) {
            MissingMonthStrip.cellView(cell, accent: glassHue.accentColor)
            Text(label)
        }
    }

    private func emptyState(_ model: MissingLensModel) -> some View {
        let words: (String, String)
        switch filter {
        case .missing:
            words = model.accounts.isEmpty
                ? ("Nothing here follows the naming yet", "Missing reads statements named like 3. Mar 2026. Renames can name them.")
                : ("Nothing is missing", "\(MissingLensModel.count(model.visible.count, "account")) checked.")
        case .expectedNext: words = ("Nothing is expected", "No tracked account is waiting for its newest month.")
        case .notTracked: words = ("Every account is tracked", "Stop Tracking moves an account here until its next statement arrives.")
        case .hidden: words = ("Nothing is hidden", "Hide Account moves an account here, out of every list and count. A gap marked Not Expected is listed here too.")
        case .all: words = ("No accounts here", "No folder in this scope holds four or more named statements.")
        }
        return EmptyStateView(icon: "calendar.badge.checkmark", tint: SemanticColor.success, title: words.0, message: words.1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The detail column

    @ViewBuilder
    private func detail(_ model: MissingLensModel, _ account: MissingStatements.Account?) -> some View {
        if let account {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MissingLensModel.title(account)).scaledFont(.system(size: 15, weight: .semibold))
                        Text(account.path.replacingOccurrences(of: "/", with: " › "))
                            .scaledFont(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !account.gaps.isEmpty || !account.missingSummaries.isEmpty {
                        Text("Not here").scaledFont(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 3) {
                            ForEach(Array(account.gaps.enumerated()), id: \.offset) { _, gap in
                                gapLine(gap, in: account)
                            }
                            ForEach(account.missingSummaries, id: \.self) { year in
                                lineBox(left: "0. Summary \(String(year))", right: "not counted", strong: false) { EmptyView() }
                            }
                        }
                    } else {
                        note("**Nothing missing.** \(MissingLensModel.count(account.statements, "statement")), \(account.first.label) to \(account.newest.label).")
                    }
                    notes(for: account)
                    years(model.filedByYear(account))
                    actions(for: account, model: model)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select an account to see what is not here.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func lineBox<Extra: View>(left: String, right: String, strong: Bool, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(left).scaledFont(.system(size: 12))
                Spacer(minLength: 8)
                Text(right)
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(strong ? SemanticColor.warning : Color.secondary)
            }
            extra()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Color.primary.opacity(0.045)))
    }

    private func gapLine(_ gap: MissingStatements.Gap, in account: MissingStatements.Account) -> some View {
        lineBox(left: MissingLensModel.text(gap), right: MissingLensModel.status(gap), strong: gap.isCounted) {
            if canChoose(account) {
                gapActions(gap, in: account)
            }
        }
    }

    @ViewBuilder
    private func gapActions(_ gap: MissingStatements.Gap, in account: MissingStatements.Account) -> some View {
        let text = MissingLensModel.text(gap)
        let off = Set(gap.notExpected)
        HStack(spacing: 12) {
            switch gap.kind {
            case .waiting:
                if let file = gap.waitingFile {
                    link("Show in To File") { onShowIn(.toFile, (absolute(file) as NSString).deletingLastPathComponent) }
                }
            case .expectedNext:
                EmptyView()
            case .silence:
                if gap.unnamedFiles > 0 {
                    link("Show in Renames") { onShowIn(.renames, absolute(account.path)) }
                } else if gap.isCounted {
                    link("Stop Counting") {
                        change("Stop Counting", "\(text) is back to a silence.") { $0.setCounted(false, months: gap.months, in: account.path) }
                    }
                } else {
                    link("Count as Missing") {
                        change("Count as Missing", "\(text) now counts as \(MissingLensModel.count(gap.months.count, "missing month")).") {
                            $0.setCounted(true, months: gap.months, in: account.path)
                        }
                    }
                }
            case .missing, .behind, .open, .csvOnly:
                if gap.unnamedFiles > 0 {
                    link("Show in Renames") { onShowIn(.renames, absolute(account.path)) }
                } else {
                    if gap.isCounted {
                        link("Not Expected") {
                            change("Not Expected", "\(text) is off the count.") {
                                $0.setExpected(false, months: gap.months.filter { !off.contains($0) }, in: account.path)
                            }
                        }
                    }
                    if !off.isEmpty {
                        link("Expect Again") {
                            change("Expect Again", "\(text) counts again.") { $0.setExpected(true, months: gap.notExpected, in: account.path) }
                        }
                    }
                }
            }
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .scaledFont(.system(size: 11.5))
            .foregroundStyle(glassHue.accentColor)
    }

    private func note(_ markdown: String) -> some View {
        Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
            .scaledFont(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func notes(for account: MissingStatements.Account) -> some View {
        let kinds = Set(account.gaps.map(\.kind))
        if let doubted = account.gaps.first(where: { $0.unnamedFiles > 0 }) {
            note("**\(MissingLensModel.count(doubted.unnamedFiles, "unnamed PDF"))** beside \(MissingLensModel.text(doubted)). One may be what is missing, so this is not counted until they are named.")
        }
        if kinds.contains(.open) {
            note("**No steady rhythm.** Every month since its \(account.newest.label) statement counts, until its next statement arrives or you press Stop Tracking.")
        }
        if kinds.contains(.behind) {
            note("Steady through **\(account.newest.label)**, then nothing.")
        }
        if kinds.contains(.csvOnly) {
            note("A CSV is here for that month without its PDF statement.")
        }
        if account.gaps.contains(where: { $0.estimate != nil }) {
            note("Too long to count for certain. The estimate assumes it kept the rhythm it had before and after.")
        }
        if account.isCard, account.gaps.contains(where: { $0.kind == .silence && !$0.isCounted }) {
            note("A card sends nothing in months it was not used, so a silence here may not be missing at all.")
        }
        if let year = account.summaryOnlyYears.first {
            note("\(String(year)) holds only its summary, so that year is left out of the timeline.")
        }
        switch account.tracking {
        case .quiet: note("**Not tracked.** Quiet since \(account.newest.label), before the first check. Nothing is expected after it.")
        case .stopped: note("**Not tracked.** Stopped by you. Its next statement starts tracking again.")
        case .tracked: EmptyView()
        }
        if account.isHidden {
            note("**Hidden.** It is left out of every list, the count and Copy List until you show it again.")
        }
    }

    private func years(_ rows: [(year: Int, filed: Int, missing: Int, summaryOnly: Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Months filed, by year").scaledFont(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(rows, id: \.year) { row in
                HStack(spacing: 8) {
                    Text(String(row.year)).frame(width: 34, alignment: .leading)
                    GeometryReader { box in
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.secondary.opacity(0.55))
                                .frame(width: box.size.width * CGFloat(min(row.filed, 12)) / 12)
                            Rectangle().fill(SemanticColor.warning)
                                .frame(width: box.size.width * CGFloat(min(row.missing, 12 - min(row.filed, 12))) / 12)
                            Spacer(minLength: 0)
                        }
                        .background(Color.primary.opacity(0.07))
                        .clipShape(Capsule())
                    }
                    .frame(height: 6)
                    Text(row.summaryOnly ? "–" : "\(row.filed)")
                        .frame(width: 22, alignment: .trailing)
                        .foregroundStyle(row.missing > 0 ? SemanticColor.warning : Color.secondary)
                }
                .scaledFont(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Months filed, by year: " + rows.map { "\($0.year), \($0.filed)" }.joined(separator: "; "))
    }

    @ViewBuilder
    private func actions(for account: MissingStatements.Account, model: MissingLensModel) -> some View {
        let title = MissingLensModel.title(account)
        if !syncManager.missingChoicesAreKept {
            note("Hiding an account, stopping it and marking a gap are kept with a folder’s survey. This folder has none of its own, so the list here is as the names read.")
        }
        FlowButtons {
            if canChoose(account) {
                if account.tracking == .tracked {
                    Button("Stop Tracking") {
                        change("Stop Tracking", "\(title) is not tracked. Its next statement starts it again.") {
                            $0.setTracking(false, for: account, from: model.report.asOf)
                        }
                    }
                    .help("Stop expecting statements after \(account.newest.label). Earlier gaps stay.")
                } else {
                    Button("Start Tracking") {
                        change("Start Tracking", "\(title) is tracked.") { $0.setTracking(true, for: account, from: model.report.asOf) }
                    }
                    .help("Expect a statement from here on.")
                }
                Button("Hide Account") {
                    change("Hide Account", "\(title) is hidden. Find it under Hidden.") { $0.hidden.insert(account.path) }
                }
                .help("Leave this account out of every list, the count and Copy List.")
            } else if account.isHidden, syncManager.missingChoicesAreKept {
                Button("Show Again") {
                    change("Show Again", "\(title) is back in the lists.") { $0.hidden.remove(account.path) }
                }
            }
            Button("Reveal in Finder") { onReveal(absolute(account.path)) }
            Button("Copy") { copy(MissingLensModel.line(account)) }
                .help("Copy this account’s line.")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func rowMenu(_ account: MissingStatements.Account, model: MissingLensModel) -> some View {
        Button("Copy") { copy(MissingLensModel.line(account)) }
        Button("Reveal in Finder") { onReveal(absolute(account.path)) }
        if canChoose(account) {
            Divider()
            if account.tracking == .tracked {
                Button("Stop Tracking") {
                    change("Stop Tracking", "\(MissingLensModel.title(account)) is not tracked. Its next statement starts it again.") {
                        $0.setTracking(false, for: account, from: model.report.asOf)
                    }
                }
            }
            Button("Hide Account") {
                change("Hide Account", "\(MissingLensModel.title(account)) is hidden. Find it under Hidden.") { $0.hidden.insert(account.path) }
            }
        }
    }

    // MARK: Plumbing

    /// Whether this account's choices can be changed: they are kept here, and it is not hidden.
    private func canChoose(_ account: MissingStatements.Account) -> Bool {
        syncManager.missingChoicesAreKept && !account.isHidden
    }

    private func change(_ actionName: String, _ message: String, _ body: (inout MissingStatements.Choices) -> Void) {
        syncManager.changeMissingChoices(actionName: actionName, message: message, body)
    }

    private var rootName: String { syncManager.missingRoot?.lastPathComponent ?? providerName ?? "this folder" }

    private func absolute(_ relative: String) -> String {
        (syncManager.missingRoot?.path as NSString? ?? "").appendingPathComponent(relative)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        syncManager.banner = .success("Copied.")
    }
}

// MARK: - The month strip

/// Three years of months, one cell each, with a tag for findings older than that.
///
/// The cells differ in shape as well as color (solid, hollow, short), so the strip reads with
/// Differentiate Without Color on. Decorative to VoiceOver: the row's label says it in words.
struct MissingMonthStrip: View {
    let cells: [MissingLensModel.Cell]
    let earlier: String?
    let accent: Color

    static let cellSize = CGSize(width: 6, height: 14)

    var body: some View {
        HStack(spacing: 6) {
            Text(earlier ?? "")
                .scaledFont(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(PillVariant.labelInk(for: SemanticColor.warning))
                .padding(.horizontal, earlier == nil ? 0 : 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(SemanticColor.warning.opacity(earlier == nil ? 0 : 0.22)))
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
            ForEach(0..<max(cells.count / 12, 0), id: \.self) { year in
                HStack(spacing: 2) {
                    ForEach(0..<12, id: \.self) { month in
                        Self.cellView(cells[year * 12 + month], accent: accent)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    static func cellView(_ cell: MissingLensModel.Cell, accent: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        Group {
            switch cell {
            case .filed: shape.fill(Color.secondary.opacity(0.5))
            case .missing: shape.fill(SemanticColor.warning)
            case .uncounted: shape.strokeBorder(SemanticColor.warning.opacity(0.75), lineWidth: 1.5)
            case .waiting: shape.strokeBorder(accent, lineWidth: 2)
            case .expectedNext: shape.strokeBorder(accent.opacity(0.8), lineWidth: 1)
            case .partial:
                VStack(spacing: 0) {
                    Color.secondary.opacity(0.5)
                    SemanticColor.warning
                }
                .clipShape(shape)
            case .noneExpected: Capsule().fill(Color.secondary.opacity(0.28)).frame(height: 3)
            case .blank: Color.clear
            }
        }
        .frame(width: cellSize.width, height: cellSize.height)
    }
}

/// Buttons that wrap onto further lines when the column is narrow.
private struct FlowButtons<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content() }
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }
}
