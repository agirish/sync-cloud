import Testing
import Foundation
@testable import Sync

/// A canned-response ``HTTPTransport`` — the key check must NEVER reach the real network in tests.
private struct FakeTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

@Suite struct AnthropicKeyCheckTests {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/models")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: Self.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func transport(status: Int, body: Data = Data()) -> FakeTransport {
        let response = response(status)
        return FakeTransport { _ in (body, response) }
    }

    @Test func emptyOrWhitespaceKeyIsInvalidWithoutTouchingTheTransport() async {
        let called = LockedBox(false)
        let transport = FakeTransport { _ in
            called.withLock { $0 = true }
            return (Data(), URLResponse())
        }

        for key in ["", "   ", " \n\t "] {
            let result = await AnthropicKeyCheck.validate(key, transport: transport)
            #expect(result == .invalid("No key entered."), "\(key.debugDescription)")
        }
        #expect(called.withLock { $0 } == false, "the empty-key guard must fire before any request")
    }

    @Test func requestCarriesTheTrimmedKeyAndVersionHeader() async {
        let captured = LockedBox<URLRequest?>(nil)
        let response = response(200)
        let transport = FakeTransport { request in
            captured.withLock { $0 = request }
            return (Data(), response)
        }

        _ = await AnthropicKeyCheck.validate("  sk-ant-test \n", transport: transport)

        let request = captured.withLock { $0 }
        #expect(request?.url == Self.endpoint)
        #expect(request?.httpMethod == "GET")
        #expect(request?.timeoutInterval == 30)
        #expect(request?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request?.value(forHTTPHeaderField: "anthropic-version") == CloudFilingProtocol.apiVersion)
    }

    @Test func status200IsValid() async {
        let result = await AnthropicKeyCheck.validate("sk-ant-test", transport: transport(status: 200))
        #expect(result == .valid)
    }

    @Test func status429IsValidBecauseItAuthenticated() async {
        // 429 = the key was accepted but rate-limited — still proof the key works.
        let result = await AnthropicKeyCheck.validate("sk-ant-test", transport: transport(status: 429))
        #expect(result == .valid)
    }

    @Test func status401And403AreInvalid() async {
        for status in [401, 403] {
            let result = await AnthropicKeyCheck.validate("sk-ant-test", transport: transport(status: status))
            #expect(result == .invalid("Key rejected (\(status)). Check the key and that billing is set up in the Console."))
        }
    }

    @Test func otherStatusIsFailedWithTheAPIErrorMessage() async {
        let body = try! JSONSerialization.data(withJSONObject:
            ["error": ["type": "overloaded_error", "message": "Overloaded"]])
        let result = await AnthropicKeyCheck.validate("sk-ant-test", transport: transport(status: 529, body: body))
        #expect(result == .failed("Overloaded"))
    }

    @Test func otherStatusWithoutAParsableMessageFallsBackToTheCode() async {
        let result = await AnthropicKeyCheck.validate("sk-ant-test", transport: transport(status: 500))
        #expect(result == .failed("HTTP 500."))
    }

    @Test func transportErrorIsFailedNotInvalid() async {
        // A network problem must never claim the key itself is bad.
        let error = URLError(.notConnectedToInternet)
        let transport = FakeTransport { _ in throw error }
        let result = await AnthropicKeyCheck.validate("sk-ant-test", transport: transport)
        #expect(result == .failed(error.localizedDescription))
    }

    @Test func nonHTTPResponseIsFailed() async {
        let transport = FakeTransport { request in
            (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        let result = await AnthropicKeyCheck.validate("sk-ant-test", transport: transport)
        #expect(result == .failed("No response."))
    }
}
