import Events
import Foundation
import Sync

/// §5.6's transport — the mapping refine's network half, on ``CloudFilingClassifier``'s exact
/// pattern: the request/response shaping is pure and tested in `Sync`
/// (`MappingRefineProtocol`); this type does the key gate, the budget caps, the call and the
/// spend record, and nothing else.
enum CloudMappingRefiner {

    /// Refines `request`'s mapping. nil on a hard failure (no key, caps reached, network,
    /// non-200, unreadable body) — the sheet says the pass failed rather than guessing.
    static func refine(_ request: MappingRefineRequest) async -> [MappingRefineProposal]? {
        guard let key = AnthropicKeychain.read() else { return nil }
        guard !request.rows.isEmpty else { return [] }

        // The same two budget caps the filing refine enforces, against the same store — a mapping
        // refine is a paid call like any other, and an unreadable spend record pauses it for the
        // same reason: a cap enforced against nothing is no cap.
        let defaults = UserDefaults.standard
        if FilingSpendStore.isUnreadable(defaults: defaults) {
            Logger.shared.warning("Mapping refine paused — the recorded spend could not be read, "
                                  + "so neither budget cap can be enforced.")
            return nil
        }
        let monthlyCap = defaults.double(forKey: FileSyncManager.monthlyBudgetCapKey)
        let totalCap = FileSyncManager.totalBudgetCap(in: defaults)
        let entries = FilingSpendStore.entries(defaults: defaults)
        if FilingSpendBudget.isOverCap(
            spent: FilingSpendBudget.monthlySpend(entries: entries, now: Date()),
            capUSD: monthlyCap) {
            Logger.shared.info("Mapping refine paused — monthly budget cap reached")
            return nil
        }
        if FilingSpendBudget.isOverCap(spent: FilingSpendStore.totals(defaults: defaults).costUSD,
                                       capUSD: totalCap) {
            Logger.shared.info("Mapping refine paused — total budget cap reached")
            return nil
        }

        let model = CloudFilingProtocol.currentModel(
            for: defaults.string(forKey: FileSyncManager.cloudModelDefaultsKey)
                ?? CloudFilingProtocol.defaultModel)
        let body = MappingRefineProtocol.requestBody(model: model, request: request)
        guard let url = URL(string: CloudFilingProtocol.endpoint),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(CloudFilingProtocol.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = httpBody

        Logger.shared.info("Mapping refine → \(model): \(request.family), "
            + "\(request.rows.count) name(s), "
            + "\(request.sampleFileNames.values.reduce(0) { $0 + $1.count }) sample file name(s)")
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let elapsed = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse else { return nil }
            let requestID = http.value(forHTTPHeaderField: "request-id") ?? "—"
            guard http.statusCode == 200 else {
                Logger.shared.warning("Mapping refine HTTP \(http.statusCode) [\(requestID)]: "
                    + (CloudFilingProtocol.errorMessage(responseData: data) ?? "no detail"))
                return nil
            }
            let proposals = MappingRefineProtocol.parseProposals(responseData: data,
                                                                 rows: request.rows)
            if let usage = CloudFilingProtocol.parseUsage(responseData: data) {
                let priced = CloudFilingProtocol.estimatedCostUSD(model: model, usage: usage)
                FilingSpendStore.record(FilingSpendEntry(
                    timestamp: Date(), model: model, fileCount: request.rows.count,
                    placedCount: proposals?.count ?? 0,
                    inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                    cacheReadTokens: usage.cacheReadTokens,
                    cacheCreationTokens: usage.cacheCreationTokens,
                    estimatedCostUSD: priced ?? 0, costUnpriced: priced == nil),
                    defaults: defaults)
            }
            Logger.shared.info("Mapping refine done [\(requestID)]: \(model) · "
                + "\(proposals?.count ?? 0)/\(request.rows.count) rows answered · "
                + String(format: "%.1f", elapsed) + "s")
            return proposals
        } catch {
            Logger.shared.warning("Mapping refine failed: \(error.localizedDescription)")
            return nil
        }
    }
}
