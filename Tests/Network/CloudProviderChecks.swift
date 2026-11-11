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
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

private enum FixtureResponse: Sendable {
    case json(Int, String)
    case redirect(URL)
    case pending
    case fail(URLError.Code)
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
private final class CloudPermission {
    var enabled = false
    var compatibleBaseURL: String?
}

@main
struct CloudProviderChecks {
    @MainActor
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderProtocol.self]
        let permission = CloudPermission()
        let provider = CloudProviders(
            allowCloud: { permission.enabled }, configuration: configuration,
            credential: { _ in "placeholder-credential" },
            compatibleBaseURL: { permission.compatibleBaseURL }
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
            precondition(body.contains("name=\"languages[]\"\r\n\r\nfr\r\n"))
            precondition(body.contains("name=\"keywords[]\""))
            precondition(!body.contains("name=\"language\""))
            precondition(!body.contains("invalid<keyword"))
            precondition(!body.contains("private-recording-name"))
            precondition(body.contains("filename=\"recording.wav\""))
            return .json(200, #"{"text":" Hello there. "}"#)
        }
        let transcript = try await provider.transcribe(
            audioURL: audioURL, model: model, language: .code("fr"),
            vocabulary: [.init(word: "Amanuensis"), .init(word: "invalid<keyword")]
        )
        precondition(transcript == "Hello there.")
        checks += 1

        // Detection omits the language, which both APIs then detect. Older models take a single language.
        for apiModelID in ["gpt-transcribe", "whisper-1"] {
            model.apiModelID = apiModelID
            fixture.reset { request in
                let body = String(decoding: requestBody(request), as: UTF8.self)
                precondition(!body.contains("name=\"languages[]\"") && !body.contains("name=\"language\""))
                return .json(200, #"{"text":"Bonjour."}"#)
            }
            _ = try await provider.transcribe(
                audioURL: audioURL, model: model, language: .automatic, vocabulary: [])
            checks += 1
        }
        model.family = .groq
        model.apiModelID = "whisper-large-v3-turbo"
        fixture.reset { request in
            let body = String(decoding: requestBody(request), as: UTF8.self)
            precondition(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
            precondition(body.contains("name=\"language\"\r\n\r\nde\r\n"))
            precondition(!body.contains("name=\"languages[]\""))
            return .json(200, #"{"text":"Hallo."}"#)
        }
        _ = try await provider.transcribe(
            audioURL: audioURL, model: model, language: .code("de"), vocabulary: [])
        checks += 1
        model.family = .openAI

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
            // Cleanup keeps the transcript's language instead of assuming English.
            precondition(body.instructions.contains("same language as the transcript"))
            precondition(!body.instructions.contains("English"))
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
            // A custom prompt, such as one asking for a translation, overrides the reply-language default.
            precondition(
                body.instructions.contains(
                    "take precedence over the rules above, including the reply language"))
            precondition(!body.instructions.contains("Never translate"))
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
        checks += try await compatibleServerChecks(
            provider: provider, permission: permission, audioURL: audioURL)
        print("Passed \(checks) cloud provider checks. No API calls or Keychain access.")
    }

    /// The OpenAI-compatible provider: its two inference requests, model listing, address rules, key
    /// handling and policy. A loopback address is still an API for local-only.
    @MainActor
    private static func compatibleServerChecks(
        provider: CloudProviders, permission: CloudPermission, audioURL: URL
    ) async throws -> Int {
        let fixture = ProviderProtocol.fixture
        var checks = 0
        var speech = ModelDescriptor(
            id: "compatible-transcribe", name: "Compatible", provider: "OpenAI-compatible", purpose: .speech,
            location: .cloud, family: .openAICompatible, summary: "", apiModelID: "whisper-large-v3")

        fixture.reset { _ in preconditionFailure("An unconfigured server was contacted") }
        do {
            _ = try await provider.transcribe(
                audioURL: audioURL, model: speech, language: .english, vocabulary: [])
            preconditionFailure("Expected a missing base URL to be reported")
        } catch CloudProviders.ProviderError.notConfigured {
            checks += 1
        }

        // An address that fails validation is never used, even if one was saved somehow.
        permission.compatibleBaseURL = "http://192.168.1.20:11434/v1"
        do {
            _ = try await provider.listModels(provider: .openAICompatible)
            preconditionFailure("Expected plain http to a remote host to be refused")
        } catch CloudProviders.ProviderError.notConfigured {
            precondition(fixture.count == 0)
            checks += 1
        }

        permission.compatibleBaseURL = "http://127.0.0.1:11434/v1"
        permission.enabled = false
        do {
            _ = try await provider.listModels(provider: .openAICompatible)
            preconditionFailure("Expected local-only to refuse a loopback server")
        } catch CloudProviders.ProviderError.localOnly {
            precondition(fixture.count == 0)
            checks += 1
        }
        permission.enabled = true

        fixture.reset { request in
            precondition(request.url?.absoluteString == "http://127.0.0.1:11434/v1/audio/transcriptions")
            precondition(
                request.value(forHTTPHeaderField: "Authorization") == "Bearer placeholder-credential")
            let body = String(decoding: requestBody(request), as: UTF8.self)
            // The same fields as Groq and older OpenAI models: one language and a vocabulary prompt.
            precondition(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3\r\n"))
            precondition(body.contains("name=\"language\"\r\n\r\nde\r\n"))
            precondition(body.contains("name=\"prompt\"\r\n\r\nAmanuensis\r\n"))
            precondition(!body.contains("languages[]") && !body.contains("keywords[]"))
            return .json(200, #"{"text":" Hallo. "}"#)
        }
        let heard = try await provider.transcribe(
            audioURL: audioURL, model: speech, language: .code("de"), vocabulary: [.init(word: "Amanuensis")])
        precondition(heard == "Hallo.")
        checks += 1

        speech.purpose = .cleanup
        speech.apiModelID = "llama3.2:3b"
        var mode = DictationMode(name: "test", preset: .mail)
        mode.customPrompt = "hidden-custom-instruction"
        fixture.reset { request in
            precondition(request.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
            let body = try! JSONDecoder().decode(ChatRequestBody.self, from: requestBody(request))
            precondition(body.model == "llama3.2:3b" && body.stream == false)
            precondition(body.messages.map(\.role) == ["system", "user"])
            precondition(body.messages[0].content.contains("same language as the transcript"))
            precondition(!body.messages[0].content.contains("hidden-custom-instruction"))
            precondition(body.messages[1].content == "um hello")
            return .json(
                200,
                #"{"choices":[{"message":{"role":"assistant","content":" Hello. "},"finish_reason":"stop"}]}"#
            )
        }
        let cleaned = try await provider.clean(text: "um hello", model: speech, mode: mode)
        precondition(cleaned == "Hello.")
        checks += 1

        for (reply, expected) in [
            (#"{"choices":[{"message":{"content":"Hel"},"finish_reason":"length"}]}"#, "incomplete"),
            (#"{"choices":[{"message":{"content":null,"refusal":"no"},"finish_reason":"stop"}]}"#, "refused"),
            (#"{"choices":[]}"#, "empty"),
        ] {
            fixture.reset { _ in .json(200, reply) }
            do {
                _ = try await provider.clean(text: "um hello", model: speech, mode: mode)
                preconditionFailure("Expected \(expected) output to be rejected")
            } catch let error as CloudProviders.ProviderError {
                switch (error, expected) {
                case (.incompleteOutput, "incomplete"), (.refused, "refused"), (.emptyOutput, "empty"):
                    checks += 1
                default: preconditionFailure("Unexpected \(error) for \(expected)")
                }
            }
        }

        // The model list feeds the picker. The saved key goes only to the saved address.
        fixture.reset { request in
            precondition(request.httpMethod == "GET" && request.httpBody == nil)
            precondition(request.url?.absoluteString == "http://127.0.0.1:11434/v1/models")
            precondition(
                request.value(forHTTPHeaderField: "Authorization") == "Bearer placeholder-credential")
            return .json(
                200,
                #"{"object":"list","data":[{"id":"whisper-1"},{"id":"llama3.2:3b"},{"id":"bad id"},{"id":"whisper-1"}]}"#
            )
        }
        let listed = try await provider.listModels(provider: .openAICompatible)
        precondition(listed == ["llama3.2:3b", "whisper-1"])
        checks += 1

        let other = try APIBaseURL.parse("https://router.example.com/api/v1").get()
        fixture.reset { request in
            precondition(request.url?.absoluteString == "https://router.example.com/api/v1/models")
            precondition(
                request.value(forHTTPHeaderField: "Authorization") == nil, "Saved key sent to a new host")
            return .json(200, #"{"data":[]}"#)
        }
        let unsavedHost = try await provider.listModels(provider: .openAICompatible, server: other)
        precondition(unsavedHost.isEmpty)
        fixture.reset { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer typed-key")
            return .json(200, #"{"data":[{"id":"m"}]}"#)
        }
        _ = try await provider.listModels(provider: .openAICompatible, server: other, key: " typed-key ")
        checks += 1

        // Validation names what it checked: the server's list, not inference.
        fixture.reset { request in
            precondition(request.url?.path == "/v1/models")
            return .json(200, #"{"data":[{"id":"whisper-1"}]}"#)
        }
        let validated = try await provider.validate(provider: .openAICompatible, modelID: "whisper-1")
        precondition(
            validated.contains("lists this model") && validated.contains("Inference has not been tested"))
        do {
            _ = try await provider.validate(provider: .openAICompatible, modelID: "other-model")
            preconditionFailure("Expected an unlisted model to be reported")
        } catch CloudProviders.ProviderError.modelNotListed {
            checks += 1
        }

        // OpenRouter-style IDs contain a slash; they travel as JSON and multipart values, never in a path.
        let slashID = "openai/gpt-4.1-mini"
        fixture.reset { _ in .json(200, #"[{"id":"openai/gpt-4.1-mini"},{"id":"meta-llama/llama-3.1-8b"}]"#) }
        let bareList = try await provider.listModels(provider: .openAICompatible)
        precondition(bareList == ["meta-llama/llama-3.1-8b", slashID], "A bare list or a slash ID was lost")
        let checked = try await provider.validate(provider: .openAICompatible, modelID: slashID)
        precondition(checked.contains("lists this model"))
        speech.purpose = .speech
        speech.apiModelID = slashID
        fixture.reset { request in
            let body = String(decoding: requestBody(request), as: UTF8.self)
            precondition(body.contains("name=\"model\"\r\n\r\nopenai/gpt-4.1-mini\r\n"))
            return .json(200, #"{"text":"Hi."}"#)
        }
        _ = try await provider.transcribe(
            audioURL: audioURL, model: speech, language: .english, vocabulary: [])
        speech.purpose = .cleanup
        // Reasons other than length and content_filter, and an empty refusal, are a finished edit.
        fixture.reset { request in
            let body = try! JSONDecoder().decode(ChatRequestBody.self, from: requestBody(request))
            precondition(body.model == slashID)
            return .json(
                200, #"{"choices":[{"message":{"content":"Hi.","refusal":""},"finish_reason":"eos"}]}"#)
        }
        let finished = try await provider.clean(text: "hi", model: speech, mode: mode)
        precondition(finished == "Hi.")
        // A fixed provider's single-model lookup puts the ID in the path, so a slash stays refused there.
        fixture.reset { _ in preconditionFailure("A slash ID reached a URL path") }
        do {
            _ = try await provider.validate(provider: .openAI, modelID: slashID)
            preconditionFailure("Expected a slash ID to be refused in a path")
        } catch CloudProviders.ProviderError.invalidConfiguration {
            checks += 1
        }

        // A missing /v1 or a stopped server names those causes rather than the model or the internet.
        for failure in [FixtureResponse.json(404, #"{"error":"not found"}"#), .fail(.cannotConnectToHost)] {
            fixture.reset { _ in failure }
            do {
                _ = try await provider.listModels(provider: .openAICompatible)
                preconditionFailure("Expected the server to be reported unreachable")
            } catch CloudProviders.ProviderError.serverNotFound {
                let message = CloudProviders.ProviderError.serverNotFound.localizedDescription
                precondition(message.contains("/v1") && message.contains("server is running"))
                checks += 1
            }
        }

        // OpenAI and Groq share the picker; their list comes from their fixed host with their key.
        fixture.reset { request in
            precondition(request.url?.absoluteString == "https://api.groq.com/openai/v1/models")
            precondition(
                request.value(forHTTPHeaderField: "Authorization") == "Bearer placeholder-credential")
            return .json(200, #"{"data":[{"id":"whisper-large-v3-turbo"}]}"#)
        }
        let groqModels = try await provider.listModels(provider: .groq)
        precondition(groqModels == ["whisper-large-v3-turbo"])
        checks += 1

        fixture.reset { request in
            precondition(request.url?.host == "127.0.0.1", "A compatible server redirect was followed")
            return .redirect(URL(string: "https://redirect.invalid/models")!)
        }
        do {
            _ = try await provider.listModels(provider: .openAICompatible)
            preconditionFailure("Expected redirect rejection")
        } catch CloudProviders.ProviderError.http(let status) {
            precondition(status == 302 && fixture.count == 1)
            checks += 1
        }
        permission.compatibleBaseURL = nil
        return checks
    }

    private struct ChatRequestBody: Decodable {
        let model: String
        let stream: Bool
        let messages: [Message]
        struct Message: Decodable {
            let role: String
            let content: String
        }
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
