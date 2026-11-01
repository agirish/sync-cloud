import AppKit
import Events
import FileExplorer
import Settings
import Sync

/// To File's **File Into**: where a scan files the loose files it reads (TE287).
///
/// The scope says where the loose files are; this says where they go. For a cloud source it is
/// that source's anchor, as it always was. For a folder source — the Home folder, Macintosh HD —
/// it is the folder survey's root, because the Home folder's own "tree" is 400,000 entries the
/// scan stopped to ask about and its homes are nowhere the survey learned. A choice in the menu
/// overrides either, per source. ``FilingDestinationRoot`` holds the rule; this is the wiring.
extension ContentView {

    /// The focused lens pane's source id.
    private var lensProviderId: String { lensTargetIsRight ? rightProviderId : leftProviderId }

    /// The survey's folder, expanded — nil when no survey is loaded or it records none.
    private var surveyRootExpanded: String? { syncManager.filingFolderProfile?.recordedFolderPath }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Where a scan on source `id` files into now.
    func filingDestinationRoot(forProviderId id: String) -> String {
        let anchor = providerAnchorExpanded(forProviderId: id)
        guard !anchor.isEmpty else { return "" }
        return FilingDestinationRoot.resolve(
            sourceId: id,
            sourceIsLocalFolder: settings.enabledProviders.first { $0.id == id }?.isLocalFolder ?? false,
            sourceAnchor: anchor, surveyRoot: surveyRootExpanded,
            stored: FilingDestinationRoot.decode(toFileDestinationsJSON),
            isDirectory: Self.isDirectory)
    }

    /// The same, for a caller that holds a source's anchor rather than its id — the row menu's
    /// Organize This Folder, and Ask Claude's Refine, which pass the anchor through
    /// ``organizeFolderAction(_:providerRoot:providerAnchor:)``. An anchor no enabled source has
    /// is filed into as itself, which is what that call did before.
    func filingDestinationRoot(forAnchor anchor: String) -> String {
        guard let id = settings.enabledProviders.first(where: { providerAnchorExpanded(forProviderId: $0.id) == anchor })?.id
        else { return anchor }
        return filingDestinationRoot(forProviderId: id)
    }

    /// File Into for the focused pane.
    var lensFilingDestinationRoot: String { filingDestinationRoot(forProviderId: lensProviderId) }

    /// Whether the scan's tree is the source the other lenses describe — false when it files
    /// elsewhere, so Names and Renames are not answered about another source's tree.
    var lensFilingReportsTreeFindings: Bool { lensFilingDestinationRoot == lensProviderAnchorExpanded }

    /// The name the scan resolves `{provider}` with: the source it files into.
    var lensFilingProviderName: String {
        filingProviderName(into: lensFilingDestinationRoot, anchor: lensProviderAnchorExpanded)
    }

    func filingProviderName(into: String, anchor: String) -> String {
        guard into != anchor else { return lensProviderName }
        let label = FilingDestinationRoot.label(for: into, sources: fileIntoSources)
        // "Documents (iCloud)" → "iCloud"; a folder in no source keeps the pane's name.
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return lensProviderName }
        return String(label[label.index(after: open)..<label.index(before: label.endIndex)])
    }

    /// Every enabled source as (name, root), for naming a destination folder.
    private var fileIntoSources: [(name: String, root: String)] {
        settings.enabledProviders.map { ($0.displayName, providerRootExpanded(forProviderId: $0.id)) }
    }

    /// The menu on To File's readout row.
    var fileIntoChoice: FileIntoChoice? {
        let id = lensProviderId
        let current = filingDestinationRoot(forProviderId: id)
        guard !current.isEmpty else { return nil }
        let sources = fileIntoSources
        let survey = surveyRootExpanded.flatMap { Self.isDirectory($0) ? $0 : nil }
        // Each cloud source's anchor; a folder source's own anchor is the tree TE287 moved away
        // from, and stays reachable through Choose Folder….
        var seen = Set([survey].compactMap { $0 })
        var others: [FileIntoChoice.Option] = []
        for provider in settings.enabledProviders where !provider.isLocalFolder {
            let anchor = providerAnchorExpanded(forProviderId: provider.id)
            guard !anchor.isEmpty, seen.insert(anchor).inserted else { continue }
            others.append(.init(path: anchor, label: FilingDestinationRoot.label(for: anchor, sources: sources)))
        }
        // A folder chosen with Choose Folder… is listed too, so the check mark has a row.
        if !seen.contains(current) {
            others.append(.init(path: current, label: FilingDestinationRoot.label(for: current, sources: sources)))
        }
        return FileIntoChoice(
            path: current,
            label: FilingDestinationRoot.label(for: current, sources: sources),
            survey: survey.map { .init(path: $0, label: FilingDestinationRoot.label(for: $0, sources: sources)) },
            sources: others,
            onPick: { setFileInto($0, forProviderId: id) },
            onChooseOther: { chooseFileIntoFolder(forProviderId: id, startingAt: current) })
    }

    /// Stores `path` as source `id`'s File Into, then scans again if To File has results — the
    /// cards on screen point into the old tree.
    func setFileInto(_ path: String, forProviderId id: String) {
        let before = filingDestinationRoot(forProviderId: id)
        let anchor = providerAnchorExpanded(forProviderId: id)
        let fallback = FilingDestinationRoot.defaultRoot(
            sourceIsLocalFolder: settings.enabledProviders.first { $0.id == id }?.isLocalFolder ?? false,
            sourceAnchor: anchor, surveyRoot: surveyRootExpanded, isDirectory: Self.isDirectory)
        toFileDestinationsJSON = FilingDestinationRoot.encode(
            FilingDestinationRoot.decode(toFileDestinationsJSON), setting: id, to: path, default: fallback)
        guard filingDestinationRoot(forProviderId: id) != before else { return }
        Logger.shared.info("To File: File Into for \(id) set to \(path)")
        if syncManager.hasSuggestedFiling, id == lensProviderId { findFilingSuggestionsAction() }
    }

    private func chooseFileIntoFolder(forProviderId id: String, startingAt folder: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "File Into"
        panel.message = "Choose the folder To File suggests homes in"
        panel.directoryURL = URL(fileURLWithPath: folder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFileInto(url.path, forProviderId: id)
    }
}
