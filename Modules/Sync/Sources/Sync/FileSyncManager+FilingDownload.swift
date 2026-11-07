import Events
import Foundation

// MARK: - Download and Read (TE287, GJ)

extension FileSyncManager {

    /// The loose files at `paths` that are cloud-only placeholders, read with `lstat` so nothing is
    /// fetched. Off the main actor: one stat per file, and a Downloads can hold hundreds.
    nonisolated static func cloudOnlyPaths(_ paths: [String],
                                           statFlags: @escaping MaterializationStatus.StatFlags) async -> Set<String> {
        await Task.detached(priority: .userInitiated) {
            Set(paths.filter { MaterializationStatus.isCloudOnly(atPath: $0, statFlags: statFlags) })
        }.value
    }

    /// Fetches the cloud-only files among `scope`, reads page 1 of each, and routes them again.
    /// Asked for, never part of a scan: the scan places a cloud-only file by name because reading
    /// it would download it, and this click says "download them".
    ///
    /// `scope` is the rows on screen, as with ``applyRecommendedFiling(_:)``, so the button's count
    /// and the files fetched agree. Waits up to ``filingDownloadWait``; a file still on its way stays
    /// marked and is named in the banner, so a second click picks it up. Routes with
    /// ``routeWithPage(_:text:providerRoot:index:)``, Read Scan's pass, so it needs the survey's
    /// index and the scan's root. Returns how many cards got a new home.
    @discardableResult
    public func downloadAndReadFiling(_ scope: [FilingSuggestion]) async -> Int {
        guard !isDownloadingFilingFiles else { return 0 }
        let targets = scope.filter { filingNotDownloaded.contains($0.filePath) }
        guard !targets.isEmpty, let extractor = filingSnippetExtractor else { return 0 }
        // As in Read Scan: the index and root must be the ones these cards were scanned against,
        // or a page routed here lands the file in another account's tree.
        guard filingRouterIndex != nil, let root = filingLastProviderRoot,
              targets.allSatisfy({ $0.providerRoot == root }) else {
            Logger.shared.info("Filing: Download and Read refused — the cached index is from another scan (\(filingLastProviderRoot ?? "none"))")
            banner = .warning("Couldn’t read these files — this list is from an earlier scan. Scan this folder again to read them.")
            return 0
        }
        isDownloadingFilingFiles = true
        defer { isDownloadingFilingFiles = false }
        let generation = filingSuggestionsGeneration

        let (landed, pending, refused) = await fetchCloudOnlyFiles(targets)

        var homed = 0
        var read = 0
        for path in landed {
            // The cards must still be the ones on screen, and the index the one they came from —
            // a rescan or another source's scan can land during any of these awaits.
            guard filingSuggestionsGeneration == generation, filingLastProviderRoot == root,
                  let index = filingRouterIndex else { break }
            filingNotDownloaded.remove(path)
            guard let live = filingSuggestions.first(where: { $0.filePath == path }) else { continue }
            guard let text = await extractor(path), !text.isEmpty else {
                // Downloaded and still nothing: a PDF with no text layer, which is Read Scan's to
                // offer now that the file is on disk.
                if (path as NSString).pathExtension.lowercased() == "pdf" { filingUnreadableScans.insert(path) }
                continue
            }
            guard filingSuggestionsGeneration == generation, filingLastProviderRoot == root else { break }
            read += 1
            // His rules first, as in the scan: a rule that matches by the page, or names its folder
            // from it ("read the file for its month"), says where it goes — not the router's best.
            if let ruled = savedRuleHome(live, text: text, providerRoot: root) {
                filingPageSamples[live.filePath] = String(text.prefix(FilingRouter.contentSampleChars))
                replaceFilingSuggestion(live.id, candidates: [ruled])
                homed += 1
                continue
            }
            if let best = routeWithPage(live, text: text, providerRoot: root, index: index).best {
                replaceFilingSuggestion(live.id, candidates: [best])
                homed += 1
            }
        }

        Logger.shared.info("Filing: Download and Read — \(landed.count) of \(targets.count) downloaded, "
            + "\(read) read, \(homed) with a home from the page"
            + (pending.isEmpty ? "" : ", \(pending.count) still downloading")
            + (refused == 0 ? "" : ", \(refused) refused"))
        banner = Self.downloadAndReadBanner(asked: targets.count, landed: landed.count, homed: homed,
                                            stillDownloading: pending.count, refused: refused)
        return homed
    }

    /// The home his saved rules give `live` now that page 1 is in hand, or nil when none matches:
    /// the scan's own rule pass, run for one file with its page — the same rules, rejections and
    /// walked folders (for a month folder's spelling), so the two agree about the file.
    func savedRuleHome(_ live: FilingSuggestion, text: String, providerRoot root: String) -> FilingDestination? {
        ensureAutomationRulesLoaded()
        let rootURL = URL(fileURLWithPath: root)
        guard !automationRules.isEmpty else { return nil }
        let existing = Set(filingLastExistingFolders.map { root + "/" + $0 }).union([root])
        let file = FileNode(id: live.filePath, name: live.fileName, isDirectory: false,
                            modificationDate: live.modificationDate, fileSize: live.size)
        let rejected = Self.rejectedPaths(forFileNamed: live.fileName, in: filingRejections(under: rootURL))
            .union(filingSessionRejections[live.id] ?? [])
        let suggested = FilingEngine.suggest(
            looseFiles: [file], learned: FilingEngine.LearnedTaxonomy(profiles: [], existingPaths: existing),
            providerRoot: root, contentTokens: filingTokensFromText.map { [live.filePath: $0(text)] } ?? [:],
            automations: automationRules, registry: filingPersonRegistry, identity: filingPersonIdentity,
            automationSnippets: [live.filePath: text], rejectedByFile: rejected.isEmpty ? [:] : [live.filePath: rejected])
        return suggested.first?.candidates.first { $0.remembered }
    }

    /// Asks the provider for each of `targets` and waits up to ``filingDownloadWait`` for them to
    /// land. The download half of ``downloadAndReadFiling(_:)``, shared with Refine with Claude,
    /// which fetches its scope's cloud-only files before reading them. Reads nothing.
    func fetchCloudOnlyFiles(_ targets: [FilingSuggestion]) async -> (landed: [String], pending: Set<String>, refused: Int) {
        let downloader = filingDownloader
        var pending: Set<String> = []
        var refused = 0
        for target in targets {
            do {
                try downloader(target.filePath)
                pending.insert(target.filePath)
            } catch {
                refused += 1
                Logger.shared.warning("Filing: “\(target.fileName)” could not be downloaded: \(error.localizedDescription)")
            }
        }

        // Watched with `isCloudOnlyIfKnown`, not the two-way form: "has it arrived?" must not read
        // a file that cannot be statted — deleted mid-download — as arrived.
        let statFlags = filingStatFlags
        let wait = filingDownloadWait
        var landed: [String] = []
        for check in 0..<max(wait.checks, 1) {
            let watching = pending
            let arrived = await Task.detached(priority: .userInitiated) {
                watching.filter { MaterializationStatus.isCloudOnlyIfKnown(atPath: $0, statFlags: statFlags) == false }
            }.value
            pending.subtract(arrived)
            landed.append(contentsOf: arrived.sorted())
            if pending.isEmpty || Task.isCancelled || check == wait.checks - 1 { break }
            try? await Task.sleep(for: wait.interval)
        }
        return (landed, pending, refused)
    }

    /// What a Download and Read says when it finishes. Static so the wording can be asserted.
    nonisolated static func downloadAndReadBanner(asked: Int, landed: Int, homed: Int,
                                                  stillDownloading: Int, refused: Int) -> OperationBanner {
        func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
        guard landed > 0 else {
            if stillDownloading > 0 {
                return .warning("\(files(stillDownloading)) still downloading — try Download and Read again in a moment.")
            }
            return .warning("Couldn’t download \(files(refused)) — open \(refused == 1 ? "it" : "them") in Finder to download.")
        }
        var text = "Downloaded and read \(files(landed))"
        text += homed == 0 ? "; none matched a folder" : "; \(homed) \(homed == 1 ? "has" : "have") a home from the page"
        if stillDownloading > 0 { text += "; \(stillDownloading) still downloading — try again in a moment" }
        if refused > 0 { text += "; \(refused) couldn’t be downloaded" }
        text += "."
        return stillDownloading + refused == 0 ? .success(text) : .warning(text)
    }
}
