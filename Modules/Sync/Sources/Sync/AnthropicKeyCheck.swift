import Foundation

/// Validates an Anthropic API key with a single free, zero-token request (`GET /v1/models`) — so the
/// user can confirm the key works before relying on it during a scan. Lives in Sync (Foundation
/// only) so Settings can call it without importing the app.
public enum AnthropicKeyCheck {
    public enum Result: Equatable, Sendable {
        case valid
        /// The key was reached but rejected (bad key, no billing/permission).
        case invalid(String)
        /// Couldn't reach Anthropic / transient error — the key may still be fine.
        case failed(String)
    }

    private static let modelsEndpoint = "https://api.anthropic.com/v1/models"

    public static func validate(_ key: String) async -> Result {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid("No key entered.") }
        guard let url = URL(string: modelsEndpoint) else { return .failed("Bad URL.") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
        request.setValue(CloudFilingProtocol.apiVersion, forHTTPHeaderField: "anthropic-version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("No response.") }
            switch http.statusCode {
            case 200, 429:            // 429 = authenticated but rate-limited → the key is valid
                return .valid
            case 401, 403:
                return .invalid("Key rejected (\(http.statusCode)). Check the key and that billing is set up in the Console.")
            default:
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String }
                return .failed(message ?? "HTTP \(http.statusCode).")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
