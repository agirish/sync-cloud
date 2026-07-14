import Foundation
import Sync
import Events

/// The opt-in **cloud** Filing backend (hybrid phase 2). Sends the folder taxonomy + a batch of
/// files to Claude (Anthropic Messages API) in one request and returns a verdict per file. Used as
/// the primary classifier when the user has enabled it and stored an API key; on any hard failure
/// the caller falls back to the on-device model.
///
/// Raw HTTPS (Swift has no official Anthropic SDK). Request/response shaping lives in
/// `CloudFilingProtocol` (pure, in Sync) so it's unit-tested; this type only does the network call.
enum CloudFilingClassifier {

    /// Cap on files sent to the cloud per scan — bounds the cost of a scan over a folder with a huge
    /// number of loose files. Files beyond the cap keep their on-device / heuristic suggestion.
    private static let maxFiles = 150

    /// The model the user picked (cost vs quality), defaulting to the best.
    private static var model: String {
        UserDefaults.standard.string(forKey: FileSyncManager.cloudModelDefaultsKey) ?? CloudFilingProtocol.defaultModel
    }

    /// Classifies `files` against `taxonomyFolders`. Returns nil on a hard error (no key, network
    /// failure, non-200, unreadable body) so the caller can fall back; an empty dictionary means the
    /// model placed nothing.
    static func classify(taxonomyFolders: [String], files allFiles: [FilingCandidateFile]) async -> [String: FilingVerdict]? {
        guard let key = AnthropicKeychain.read() else { return nil }
        guard !allFiles.isEmpty else { return [:] }

        // Hard budget cap (X6, belt-and-suspenders): even if the pre-flight UI gate was somehow
        // bypassed, never make a cloud call once EITHER the monthly or the total (lifetime) cap has
        // been reached. Returning nil reuses the existing graceful on-device fallback. A monthly cap
        // of 0 = unlimited; the total cap defaults to $5 (see `totalBudgetCap(in:)`).
        let monthlyCap = UserDefaults.standard.double(forKey: FileSyncManager.monthlyBudgetCapKey)
        let totalCap = FileSyncManager.totalBudgetCap(in: .standard)
        let monthlySpent = FilingSpendBudget.monthlySpend(entries: FilingSpendStore.entries(), now: Date())
        let totalSpent = FilingSpendStore.totals().costUSD
        if FilingSpendBudget.isOverCap(spent: monthlySpent, capUSD: monthlyCap) {
            Logger.shared.info("Cloud Filing paused — monthly budget cap \(FilingSpendFormat.cost(monthlyCap)) reached (\(FilingSpendFormat.cost(monthlySpent)) spent this month) — using on-device suggestions")
            return nil
        }
        if FilingSpendBudget.isOverCap(spent: totalSpent, capUSD: totalCap) {
            Logger.shared.info("Cloud Filing paused — total budget cap \(FilingSpendFormat.cost(totalCap)) reached (\(FilingSpendFormat.cost(totalSpent)) spent lifetime) — using on-device suggestions")
            return nil
        }

        let files = Array(allFiles.prefix(maxFiles))   // same array feeds requestBody + parse (indices)

        let body = CloudFilingProtocol.requestBody(model: model, taxonomyFolders: taxonomyFolders, files: files)
        guard let url = URL(string: CloudFilingProtocol.endpoint),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(CloudFilingProtocol.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = httpBody

        let excerptCount = files.filter {
            ($0.contentSnippet?.isEmpty == false) && !FilingEngine.canRemember(fileName: $0.fileName)
        }.count
        let cappedNote = allFiles.count > files.count ? " (capped from \(allFiles.count))" : ""
        Logger.shared.info("Cloud Filing → \(model): \(files.count) file(s)\(cappedNote), \(excerptCount) with content excerpt")

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse else { return nil }
            let requestID = http.value(forHTTPHeaderField: "request-id") ?? "—"

            guard http.statusCode == 200 else {
                let detail = CloudFilingProtocol.errorMessage(responseData: data)
                Logger.shared.warning("Cloud Filing HTTP \(http.statusCode) [\(requestID)]: \(detail ?? "no detail") — falling back on-device")
                return nil
            }

            let verdicts = CloudFilingProtocol.parseVerdicts(responseData: data, files: files)
            let usage = CloudFilingProtocol.parseUsage(responseData: data)
            let stop = CloudFilingProtocol.stopReason(responseData: data)

            // One rich summary line: model · files · tokens (incl. cache) · est cost · latency · placed.
            var summary = "Cloud Filing done [\(requestID)]: \(model) · \(files.count) files"
            if let u = usage {
                summary += " · \(u.inputTokens) in"
                if u.cacheReadTokens > 0 { summary += " (+\(u.cacheReadTokens) cache-read)" }
                if u.cacheCreationTokens > 0 { summary += " (+\(u.cacheCreationTokens) cache-write)" }
                summary += " / \(u.outputTokens) out tok"
                if let cost = CloudFilingProtocol.estimatedCostUSD(model: model, usage: u) {
                    summary += " · ~$\(String(format: "%.3f", cost))"
                }
            }
            summary += " · \(String(format: "%.1f", elapsed))s · placed \(verdicts?.count ?? 0)/\(files.count)"
            if stop == "max_tokens" { summary += " · ⚠️ TRUNCATED (max_tokens)" }
            Logger.shared.info(summary)

            // Record spend for the Filing UI (history + total).
            if let u = usage {
                FilingSpendStore.record(FilingSpendEntry(
                    timestamp: Date(), model: model, fileCount: files.count, placedCount: verdicts?.count ?? 0,
                    inputTokens: u.inputTokens, outputTokens: u.outputTokens,
                    cacheReadTokens: u.cacheReadTokens, cacheCreationTokens: u.cacheCreationTokens,
                    estimatedCostUSD: CloudFilingProtocol.estimatedCostUSD(model: model, usage: u) ?? 0))
            }

            if stop == "max_tokens" {
                Logger.shared.warning("Cloud Filing response was truncated (max_tokens) — some files may be left unplaced. Try fewer files per scan or a shorter folder.")
            }
            return verdicts
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            Logger.shared.warning("Cloud Filing request failed after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription) — falling back on-device")
            return nil
        }
    }
}
