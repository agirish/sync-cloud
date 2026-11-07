import Foundation
import Sync
import Events

/// The opt-in cloud Filing backend. Sends the folder taxonomy and a batch of files to Claude
/// (Anthropic Messages API) in one request and returns a verdict per file. The primary classifier
/// once the user enables it and stores an API key; on any hard failure the caller falls back to the
/// on-device model.
///
/// Raw HTTPS (Swift has no official Anthropic SDK). Request/response shaping lives in
/// `CloudFilingProtocol` (pure, in Sync) so it's unit-tested; this type only does the network call.
enum CloudFilingClassifier {

    /// Cap on files sent to the cloud per scan — bounds the cost of a scan over a folder with a huge
    /// number of loose files. Files beyond the cap keep their on-device / heuristic suggestion.
    private static let maxFiles = 150

    /// The injectable edges of `classify`: the Keychain read, the defaults domain (model, caps,
    /// spend store), the clock and the HTTPS transport, each defaulting to the real one. Tests swap
    /// them to run the whole decision path without a network call or the login Keychain.
    /// `@unchecked Sendable`: UserDefaults is documented thread-safe; the closures are `@Sendable`.
    struct Environment: @unchecked Sendable {
        var readAPIKey: @Sendable () -> String? = { AnthropicKeychain.read() }
        var defaults: UserDefaults = .standard
        var now: @Sendable () -> Date = { Date() }
        var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    }

    /// Classifies `files` against `taxonomyFolders`. Returns nil on a hard error (no key, network
    /// failure, non-200, unreadable body) so the caller can fall back; an empty dictionary means the
    /// model placed nothing.
    static func classify(taxonomyFolders: [String], files: [FilingCandidateFile]) async -> [String: FilingVerdict]? {
        await classify(taxonomyFolders: taxonomyFolders, files: files, environment: Environment())
    }

    /// The worker behind `classify`, same contract. Production passes `Environment()`; tests
    /// inject fakes.
    static func classify(taxonomyFolders: [String], files allFiles: [FilingCandidateFile],
                         environment env: Environment) async -> [String: FilingVerdict]? {
        guard let key = env.readAPIKey() else { return nil }
        guard !allFiles.isEmpty else { return [:] }

        // Hard budget cap, even if the pre-flight UI gate was bypassed: no cloud call once either
        // the monthly or the lifetime cap is reached; nil falls back on-device. A monthly cap of 0
        // is unlimited; the total cap defaults to $5 (`totalBudgetCap(in:)`).
        // **No paid call if the spend record can't be read:** a cap enforced against nothing would
        // re-arm the $5 lifetime cap from scratch. `FilingSpendStore` keeps the bytes, so this is
        // recoverable.
        if FilingSpendStore.isUnreadable(defaults: env.defaults) {
            Logger.shared.warning("Cloud Filing paused — the recorded spend could not be read, so "
                                  + "neither budget cap can be enforced. The unreadable values are "
                                  + "kept under their \".unreadable\" keys; clear or repair them in "
                                  + "Settings to resume. Using on-device suggestions.")
            return nil
        }
        let monthlyCap = env.defaults.double(forKey: FileSyncManager.monthlyBudgetCapKey)
        let totalCap = FileSyncManager.totalBudgetCap(in: env.defaults)
        let monthlySpent = FilingSpendBudget.monthlySpend(entries: FilingSpendStore.entries(defaults: env.defaults), now: env.now())
        let totalSpent = FilingSpendStore.totals(defaults: env.defaults).costUSD
        if FilingSpendBudget.isOverCap(spent: monthlySpent, capUSD: monthlyCap) {
            Logger.shared.info("Cloud Filing paused — monthly budget cap \(FilingSpendFormat.cost(monthlyCap)) reached (\(FilingSpendFormat.cost(monthlySpent)) spent this month) — using on-device suggestions")
            return nil
        }
        if FilingSpendBudget.isOverCap(spent: totalSpent, capUSD: totalCap) {
            Logger.shared.info("Cloud Filing paused — total budget cap \(FilingSpendFormat.cost(totalCap)) reached (\(FilingSpendFormat.cost(totalSpent)) spent lifetime) — using on-device suggestions")
            return nil
        }

        let files = Array(allFiles.prefix(maxFiles))   // same array feeds requestBody + parse (indices)

        // The model the user picked (cost vs quality), defaulting to the best.
        let model = CloudFilingProtocol.currentModel(
            for: env.defaults.string(forKey: FileSyncManager.cloudModelDefaultsKey) ?? CloudFilingProtocol.defaultModel)
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

        // Every file whose page goes out, named or not: the request sends them all.
        let excerptCount = files.filter { $0.contentSnippet?.isEmpty == false }.count
        let cappedNote = allFiles.count > files.count ? " (capped from \(allFiles.count))" : ""
        Logger.shared.info("Cloud Filing → \(model): \(files.count) file(s)\(cappedNote), \(excerptCount) with content excerpt")

        let start = Date()
        do {
            let (data, response) = try await env.transport(request)
            let elapsed = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse else {
                // Was silent on a paid call: the scan just stopped with nothing in the log.
                Logger.shared.warning("Cloud Filing: the API's reply was not an HTTP response, so the call was dropped")
                return nil
            }
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
                // An unknown model id (reachable by hand-setting it) means an unknown cost, not a
                // free scan. The call is still recorded, since its tokens are real, and
                // `costUnpriced` stops its $0 reading as "this cost nothing" to the budget caps.
                let priced = CloudFilingProtocol.estimatedCostUSD(model: model, usage: u)
                if priced == nil {
                    Logger.shared.warning("Cloud Filing: no price table for model “\(model)”, so this "
                                        + "scan's cost is unknown and is recorded as $0.00. Lifetime "
                                        + "spend is now a floor rather than a total, and both budget "
                                        + "caps under-count by whatever this call cost.")
                }
                FilingSpendStore.record(FilingSpendEntry(
                    timestamp: env.now(), model: model, fileCount: files.count, placedCount: verdicts?.count ?? 0,
                    inputTokens: u.inputTokens, outputTokens: u.outputTokens,
                    cacheReadTokens: u.cacheReadTokens, cacheCreationTokens: u.cacheCreationTokens,
                    estimatedCostUSD: priced ?? 0, costUnpriced: priced == nil),
                    defaults: env.defaults)
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
