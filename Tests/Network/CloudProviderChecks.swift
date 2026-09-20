import Foundation

/// URLProtocol supplies every response, so these checks neither use Keychain nor contact providers.
private final class ProviderProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = ProtocolFixture()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.fixture.respond(to: request) {
        case .json(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let destination):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": destination.absoluteString]
            )!
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .pending:
            break
        }
    }

    override func stopLoading() {}
}

private enum FixtureResponse: Sendable {
    case json(Int, String)
    case redirect(URL)
    case pending
}

/// URLProtocol calls this from its own queue. Keep the handler and dispatch count under one lock.
private final class ProtocolFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> FixtureResponse = { _ in
        preconditionFailure("Unexpected network request")
    }
    private var dispatchCount = 0

    var count: Int { lock.withLock { dispatchCount } }

    func reset(_ handler: @escaping @Sendable (URLRequest) -> FixtureResponse) {
        lock.withLock {
            self.handler = handler
            dispatchCount = 0
        }
    }

    func respond(to request: URLRequest) -> FixtureResponse {
        let handler = lock.withLock {
            dispatchCount += 1
            return self.handler
        }
        return handler(request)
    }
}

@MainActor
private final class CloudPermission { var enabled = false }

@main
struct CloudProviderChecks {
    @MainActor
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderProtocol.self]
        let permission = CloudPermission()
        let provider = CloudProviders(
            allowCloud: { permission.enabled }, configuration: configuration,
            credential: { _ in "placeholder-credential" }
        )
        let fixture = ProviderProtocol.fixture
        var checks = 0

        // A local-only validation attempt cannot even reach the mock transport.
        fixture.reset { _ in preconditionFailure("Local-only mode dispatched a request") }
        do {
            _ = try await provider.validate(provider: .openAI, modelID: "gpt-transcribe")
            preconditionFailure("Expected the local-only policy error")
        } catch CloudProviders.ProviderError.localOnly {
            precondition(fixture.count == 0)
            checks += 1
        }
        permission.enabled = true

        do {
            _ = try await provider.validate(provider: .openAI, modelID: "../../bad")
            preconditionFailure("Expected invalid model ID to be rejected")
        } catch CloudProviders.ProviderError.invalidConfiguration {
            precondition(fixture.count == 0)
            checks += 1
        }

        // Validation is metadata-only. It must never reuse recorded audio or transcript text.
        fixture.reset { request in
            precondition(request.httpMethod == "GET")
            precondition(request.httpBody == nil && request.httpBodyStream == nil)
            precondition(request.url?.absoluteString == "https://api.anthropic.com/v1/models/claude-test")
            precondition(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            return .json(200, #"{"id":"claude-test"}"#)
        }
        let connection = try await provider.validate(provider: .anthropic, modelID: "claude-test")
        precondition(connection.contains("Inference has not been tested"))
        checks += 1

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("private-recording-name.wav")
        try Data([0, 1, 2, 3]).write(to: audioURL)
        var model = ModelDescriptor(
            id: "test", name: "test", provider: "test", purpose: .speech, location: .cloud,
            family: .openAI, summary: "", apiModelID: "gpt-transcribe"
        )
        fixture.reset { request in
            precondition(request.httpMethod == "POST")
            precondition(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
            let body = String(decoding: requestBody(request), as: UTF8.self)
            precondition(body.contains("name=\"languages[]\""))
            precondition(body.contains("name=\"keywords[]\""))
            precondition(!body.contains("name=\"language\""))
            precondition(!body.contains("invalid<keyword"))
            precondition(!body.contains("private-recording-name"))
            precondition(body.contains("filename=\"recording.wav\""))
            return .json(200, #"{"text":" Hello there. "}"#)
        }
        let transcript = try await provider.transcribe(
            audioURL: audioURL, model: model,
            vocabulary: [.init(word: "Amanuensis"), .init(word: "invalid<keyword")]
        )
        precondition(transcript == "Hello there.")
        checks += 1

        model.purpose = .cleanup
        model.apiModelID = "gpt-test"
        var mode = DictationMode(name: "test", preset: .message)
        mode.customPrompt = "hidden-custom-instruction"
        fixture.reset { request in
            precondition(request.url?.path == "/v1/responses")
            let body = try! JSONDecoder().decode(CleanupRequest.self, from: requestBody(request))
            precondition(body.model == "gpt-test" && body.input == "um edited")
            precondition(!body.store)
            precondition(!body.instructions.contains("hidden-custom-instruction"))
            return .json(
                200,
                #"{"status":"completed","output":[{"type":"reasoning"},{"content":[{"type":"output_text","text":"Edited."}]}]}"#
            )
        }
        let result = try await provider.clean(text: "um edited", model: model, mode: mode)
        precondition(result == "Edited.")
        checks += 1

        mode.preset = .custom
        fixture.reset { request in
            let body = try! JSONDecoder().decode(CleanupRequest.self, from: requestBody(request))
            precondition(body.instructions.contains("hidden-custom-instruction"))
            return .json(200, #"{"status":"incomplete","output":[]}"#)
        }
        do {
            _ = try await provider.clean(text: "test", model: model, mode: mode)
            preconditionFailure("Expected incomplete OpenAI output to be rejected")
        } catch CloudProviders.ProviderError.incompleteOutput {
            checks += 1
        }

        model.family = .anthropic
        fixture.reset { _ in
            .json(200, #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"Incomplete"}]}"#)
        }
        do {
            _ = try await provider.clean(text: "test", model: model, mode: mode)
            preconditionFailure("Expected incomplete Claude output to be rejected")
        } catch CloudProviders.ProviderError.incompleteOutput {
            checks += 1
        }

        fixture.reset { _ in .json(401, #"{"error":"sensitive-response-marker"}"#) }
        do {
            _ = try await provider.validate(provider: .groq, modelID: "whisper-large-v3")
            preconditionFailure("Expected rejected credentials to produce HTTP 401")
        } catch CloudProviders.ProviderError.http(let status) {
            precondition(status == 401)
            let message = CloudProviders.ProviderError.http(status).localizedDescription
            precondition(!message.contains("sensitive-response-marker"))
            precondition(!message.contains("placeholder-credential"))
            checks += 1
        }

        fixture.reset { _ in .pending }
        let task = Task { try await provider.validate(provider: .openAI, modelID: "gpt-test") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.count == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(fixture.count == 1, "The cancellation check never reached its mock transport")
        provider.cancel()
        do {
            _ = try await task.value
            preconditionFailure("Expected cancellation to stop the pending request")
        } catch is CancellationError {
            checks += 1
        }

        // Exercise the production session delegate, not a test double, when a provider redirects.
        fixture.reset { request in
            precondition(request.url?.host == "api.openai.com", "A provider redirect was followed")
            return .redirect(URL(string: "https://redirect.invalid/credentials")!)
        }
        do {
            _ = try await provider.validate(provider: .openAI, modelID: "gpt-test")
            preconditionFailure("Expected redirect rejection")
        } catch CloudProviders.ProviderError.http(let status) {
            precondition(status == 302)
            precondition(fixture.count == 1)
            checks += 1
        }
        print("Passed \(checks) cloud provider checks. No API calls or Keychain access.")
    }

    private struct CleanupRequest: Decodable {
        let model: String
        let input: String
        let instructions: String
        let store: Bool
    }

    nonisolated private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            precondition(count >= 0, "Could not read the mock request body")
            if count == 0 { break }
            body.append(contentsOf: bytes.prefix(count))
        }
        return body
    }
}
