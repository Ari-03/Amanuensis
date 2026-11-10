import Foundation

/// Serves every request from `Server`, so these checks never touch the network.
private final class DownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = Server.shared.reply(to: request) else { return }  // never answers
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        if reply.drops {
            // Immediately after the data, URLSession can drop it with the task; a real connection
            // delivers bytes before it fails.
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private struct Reply {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// The connection drops after `body`.
    var drops = false
}

/// The file and how the fake server behaves for each request, by its index. Records each Range and
/// Accept-Encoding header.
private final class Server: @unchecked Sendable {
    static let shared = Server()
    private let lock = NSLock()
    private var behave: @Sendable (Int, String?) -> Reply? = { _, _ in nil }
    private var seen: [String?] = []
    private var codings: [String?] = []

    var ranges: [String?] { lock.withLock { seen } }
    /// Every request's Accept-Encoding since the checks started.
    var encodings: [String?] { lock.withLock { codings } }

    func reset(_ behave: @escaping @Sendable (_ index: Int, _ range: String?) -> Reply?) {
        lock.withLock {
            self.behave = behave
            seen = []
        }
    }

    func reply(to request: URLRequest) -> Reply? {
        let range = request.value(forHTTPHeaderField: "Range")
        let (index, behave) = lock.withLock {
            seen.append(range)
            codings.append(request.value(forHTTPHeaderField: "Accept-Encoding"))
            return (seen.count - 1, self.behave)
        }
        return behave(index, range)
    }
}

private let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

/// The offset a "bytes=N-" header asks for.
private func offset(_ range: String?) -> Int? {
    range.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) }
}

/// A server that honors Range, dropping its first response after `dropAt` bytes when given.
private func honoring(_ index: Int, _ range: String?, dropAt: Int? = nil) -> Reply {
    if let start = offset(range) {
        return Reply(
            status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
            body: body.subdata(in: start..<body.count))
    }
    if index == 0, let dropAt { return Reply(status: 200, body: body.prefix(dropAt), drops: true) }
    return Reply(status: 200, body: body)
}

private struct NotFound: Error {}

@main @MainActor
struct FileDownloadChecks {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func run(_ file: URL, expectedSize: Int64? = Int64(body.count)) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProtocol.self]
        try await FileDownload.fetch(
            URL(string: "https://example.invalid/model.safetensors")!, to: file, expectedSize: expectedSize,
            configuration: configuration,
            checkResponse: { response in
                if (response as? HTTPURLResponse)?.statusCode == 404 { throw NotFound() }
            }, progress: { _ in })
    }

    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "file-download-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var number = 0
        func newFile(_ contents: Data? = nil) -> URL {
            number += 1
            let url = folder.appendingPathComponent("\(number).part")
            if let contents { FileManager.default.createFile(atPath: url.path, contents: contents) }
            return url
        }

        // A dropped connection resumes at the byte on disk and the file comes out whole.
        Server.shared.reset { honoring($0, $1, dropAt: 120_000) }
        var file = newFile()
        try await run(file)
        check(Server.shared.ranges == [nil, "bytes=120000-"], "resume asked for \(Server.shared.ranges)")
        check(try Data(contentsOf: file) == body, "the resumed file differs from the original")

        // A server that ignores Range sends the whole file again, which replaces the partial bytes.
        Server.shared.reset { index, _ in
            index == 0
                ? Reply(status: 200, body: body.prefix(100_000), drops: true) : Reply(status: 200, body: body)
        }
        file = newFile()
        try await run(file)
        check(
            Server.shared.ranges == [nil, "bytes=100000-"], "ignored range asked for \(Server.shared.ranges)")
        check(try Data(contentsOf: file) == body, "a whole-file reply was appended to the partial bytes")

        // A range that starts elsewhere is not appended; the next attempt starts over.
        Server.shared.reset { index, range in
            index == 1
                ? Reply(
                    status: 206, headers: ["Content-Range": "bytes 0-\(body.count - 1)/\(body.count)"],
                    body: body)
                : honoring(index, range, dropAt: 100_000)
        }
        file = newFile()
        try await run(file)
        check(
            Server.shared.ranges == [nil, "bytes=100000-", nil],
            "wrong range asked for \(Server.shared.ranges)")
        check(try Data(contentsOf: file) == body, "a misplaced range was appended")

        // A server whose file ends before ours answers 416; the download starts over.
        Server.shared.reset { index, range in
            index == 0 ? Reply(status: 416) : honoring(index, range)
        }
        file = newFile(body.prefix(50_000))
        try await run(file, expectedSize: nil)
        check(Server.shared.ranges == ["bytes=50000-", nil], "416 asked for \(Server.shared.ranges)")
        check(try Data(contentsOf: file) == body, "416 left the wrong bytes")

        // Every attempt drops: the error is thrown after a fixed number of attempts, the bytes stay on
        // disk, and a later call (Retry) continues from them.
        Server.shared.reset { _, range in
            let start = offset(range) ?? 0
            return Reply(
                status: start == 0 ? 200 : 206,
                headers: start == 0
                    ? [:] : ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
                body: body.subdata(in: start..<(start + 50_000)), drops: true)
        }
        file = newFile()
        do {
            try await run(file)
            check(false, "a download that always drops succeeded")
        } catch {
            check((error as? URLError)?.code == .networkConnectionLost, "always dropping threw \(error)")
        }
        check(
            Server.shared.ranges.count == FileDownload.attempts, "made \(Server.shared.ranges.count) attempts"
        )
        let kept = try Data(contentsOf: file)
        check(kept == body.prefix(50_000 * FileDownload.attempts), "kept \(kept.count) bytes")
        Server.shared.reset { honoring($0, $1) }
        try await run(file)
        check(Server.shared.ranges == ["bytes=200000-"], "retry asked for \(Server.shared.ranges)")
        check(try Data(contentsOf: file) == body, "retry did not complete the file")

        // A body that ends early without an error, then a correct resume: the file is whole at once,
        // with no further attempts.
        Server.shared.reset { index, range in
            index == 0 ? Reply(status: 200, body: body.prefix(100_000)) : honoring(index, range)
        }
        file = newFile()
        try await run(file)
        check(Server.shared.ranges == [nil, "bytes=100000-"], "short body asked for \(Server.shared.ranges)")
        check(try Data(contentsOf: file) == body, "a short body then a resume left the wrong bytes")

        // A negative size from the hub is refused without a request or a crash.
        Server.shared.reset { honoring($0, $1) }
        file = newFile()
        do {
            try await run(file, expectedSize: -1)
            check(false, "a negative size succeeded")
        } catch {
            check(error is FileDownload.InvalidSize, "a negative size threw \(error)")
        }
        check(Server.shared.ranges.isEmpty, "a negative size made a request")

        // An HTTP error is the caller's error and is not retried.
        Server.shared.reset { _, _ in Reply(status: 404) }
        file = newFile(body.prefix(10))
        do {
            try await run(file)
            check(false, "404 succeeded")
        } catch {
            check(error is NotFound, "404 threw \(error)")
        }
        check(Server.shared.ranges.count == 1, "404 was retried")

        // A complete file makes no request; one longer than the file starts over without Range.
        Server.shared.reset { honoring($0, $1) }
        file = newFile(body)
        try await run(file)
        check(Server.shared.ranges.isEmpty, "a complete file was downloaded again")
        file = newFile(body + Data([1, 2, 3]))
        try await run(file)
        check(Server.shared.ranges == [nil], "an oversized file asked for \(Server.shared.ranges)")
        check(try Data(contentsOf: file) == body, "an oversized file was not replaced")

        // Cancel ends a request the server never answers, without retrying.
        Server.shared.reset { _, _ in nil }
        file = newFile()
        let task = Task { try await run(file) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let started = ContinuousClock.now
        let result = await task.result
        if case .failure(let error) = result {
            check((error as? URLError)?.code == .cancelled, "cancel threw \(error)")
        } else {
            check(false, "a canceled download succeeded")
        }
        check(ContinuousClock.now - started < .seconds(1), "cancel waited for a retry")
        check(Server.shared.ranges.count == 1, "cancel retried")

        // Offsets count bytes on disk, so no request may ask for a content coding.
        check(
            !Server.shared.encodings.isEmpty && Server.shared.encodings.allSatisfy { $0 == "identity" },
            "requests asked for \(Set(Server.shared.encodings.map { $0 ?? "nil" }))")

        if failures > 0 { exit(1) }
        print("File download checks passed")
    }
}
