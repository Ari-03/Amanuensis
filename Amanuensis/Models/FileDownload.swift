import Foundation

/// Downloads one file to disk, continuing what is already there with an HTTP Range request.
/// `ModelLibrary` fetches each model file through it into the download's staging folder. Within one
/// call, a dropped connection resumes from the bytes on disk a few times before the error is thrown.
/// A server that ignores Range sends the whole file, which replaces the partial one. The caller checks
/// the size and checksum of the finished file; this only moves bytes.
enum FileDownload {
    /// The first request and three resumes.
    static let attempts = 4

    /// Returns once `file` holds the whole body. With `expectedSize`, a partial file of that size is
    /// already complete and one larger starts over; a negative size is refused. `checkResponse` turns an HTTP error status into the
    /// caller's error. `progress` receives the bytes in `file`, a few times a second.
    static func fetch(
        _ url: URL, to file: URL, expectedSize: Int64?,
        configuration: URLSessionConfiguration = .default,
        checkResponse: @escaping @Sendable (URLResponse) throws -> Void,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if let expectedSize, expectedSize < 0 { throw InvalidSize() }
        var attempt = 1
        while true {
            do {
                let size = try await fetchOnce(
                    url, to: file, expectedSize: expectedSize, configuration: configuration,
                    checkResponse: checkResponse, progress: progress)
                if let expectedSize, size < UInt64(expectedSize) { throw Interrupted() }
                return
            } catch  where isTransient(error) && attempt < attempts {
                // Waits 1, 2 and 3 seconds; cancellation ends the wait.
                try await Task.sleep(for: .seconds(attempt))
                attempt += 1
            }
        }
    }

    /// Transport failures worth resuming. Anything else, such as an HTTP error, ends the download.
    static func isTransient(_ error: any Error) -> Bool {
        if error is Interrupted { return true }
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed,
        ].contains(code)
    }

    /// The body ended before the file was complete, or the server's range did not start where the
    /// file on disk ends. The next attempt continues from what is on disk.
    struct Interrupted: LocalizedError {
        var errorDescription: String? { "The download was interrupted. Retry to continue it." }
    }

    /// The server listed a negative size for the file.
    struct InvalidSize: LocalizedError {
        var errorDescription: String? { "The model repository listed an invalid file size." }
    }

    /// One request. Returns the bytes now in the file, counted while writing: a `URL` caches the file
    /// size it last read, so asking the file system again could return a stale answer.
    private static func fetchOnce(
        _ url: URL, to file: URL, expectedSize: Int64?, configuration: URLSessionConfiguration,
        checkResponse: @escaping @Sendable (URLResponse) throws -> Void,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        var offset = try handle.seekToEnd()
        if let expectedSize, offset >= UInt64(expectedSize) {
            if offset == UInt64(expectedSize) {
                try handle.close()
                return offset
            }
            try handle.truncate(atOffset: 0)
            offset = 0
        }
        var request = URLRequest(url: url)
        // Without a content coding, a range and the offset both count the bytes on disk.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let receiver = Receiver(
            handle: handle, offset: offset, checkResponse: checkResponse, progress: progress)
        let session = URLSession(
            configuration: configuration, delegate: receiver, delegateQueue: receiver.queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.queue.addOperation {
                    receiver.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Writes one response's body after the bytes already in the file. Every callback runs on `queue`.
    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        var continuation: CheckedContinuation<UInt64, any Error>?
        private let handle: FileHandle
        private var written: UInt64
        private let checkResponse: @Sendable (URLResponse) throws -> Void
        private let progress: @Sendable (Int64) -> Void
        private var failure: (any Error)?
        private var reportedAt = ContinuousClock.now

        init(
            handle: FileHandle, offset: UInt64,
            checkResponse: @escaping @Sendable (URLResponse) throws -> Void,
            progress: @escaping @Sendable (Int64) -> Void
        ) {
            self.handle = handle
            written = offset
            self.checkResponse = checkResponse
            self.progress = progress
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            do {
                try accept(response)
                completionHandler(.allow)
            } catch {
                failure = error
                completionHandler(.cancel)
            }
        }

        /// 206 must continue at the byte on disk. Any other success is the whole file, so the partial
        /// bytes go. 416 means the server's file ends before ours, so the next attempt starts over.
        private func accept(_ response: URLResponse) throws {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 206:
                guard Self.rangeStart(response) == written else {
                    try restart()
                    throw Interrupted()
                }
            case 200..<300:
                if written > 0 { try restart() }
            case 416:
                try restart()
                throw Interrupted()
            default:
                try checkResponse(response)
                throw URLError(.badServerResponse)
            }
        }

        private func restart() throws {
            try handle.truncate(atOffset: 0)
            written = 0
            progress(0)
        }

        /// The first byte of a "Content-Range: bytes 100-199/200" header.
        private static func rangeStart(_ response: URLResponse) -> UInt64? {
            guard let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
                value.hasPrefix("bytes ")
            else { return nil }
            return UInt64(value.dropFirst("bytes ".count).prefix { $0 != "-" })
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
                written += UInt64(data.count)
            } catch {
                failure = error
                dataTask.cancel()
                return
            }
            let now = ContinuousClock.now
            if now - reportedAt >= .milliseconds(100) {
                reportedAt = now
                progress(Int64(written))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?)
        {
            try? handle.close()
            progress(Int64(written))
            let outcome = failure ?? error
            if let outcome {
                continuation?.resume(throwing: outcome)
            } else {
                continuation?.resume(returning: written)
            }
            continuation = nil
        }
    }
}
