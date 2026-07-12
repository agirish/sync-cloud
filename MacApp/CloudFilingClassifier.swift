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

    /// Classifies `files` against `taxonomyFolders`. Returns nil on a hard error (no key, network
    /// failure, non-200, unreadable body) so the caller can fall back; an empty dictionary means the
    /// model placed nothing.
    static func classify(taxonomyFolders: [String], files: [FilingCandidateFile]) async -> [String: FilingVerdict]? {
        guard let key = AnthropicKeychain.read() else { return nil }
        guard !files.isEmpty else { return [:] }

        let body = CloudFilingProtocol.requestBody(taxonomyFolders: taxonomyFolders, files: files)
        guard let url = URL(string: CloudFilingProtocol.endpoint),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(CloudFilingProtocol.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = httpBody

        Logger.shared.info("Cloud Filing: classifying \(files.count) file(s) via \(CloudFilingProtocol.defaultModel)")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                Logger.shared.warning("Cloud Filing HTTP \(http.statusCode) — falling back on-device")
                return nil
            }
            let verdicts = CloudFilingProtocol.parseVerdicts(responseData: data, files: files)
            if let verdicts {
                Logger.shared.info("Cloud Filing: Claude placed \(verdicts.count) of \(files.count) file(s)")
            }
            return verdicts
        } catch {
            Logger.shared.warning("Cloud Filing request failed: \(error.localizedDescription) — falling back on-device")
            return nil
        }
    }
}
