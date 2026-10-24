// The real network, through URLSession.
import Foundation

public final class URLSessionHTTP: NSObject, HTTP, URLSessionTaskDelegate, @unchecked Sendable {
    /// Larger than any APOD picture; anything bigger is not what we asked for.
    static let maxDownload: Int64 = 200 * 1024 * 1024

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "APOD-for-macOS (https://github.com/smolamSK)"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public override init() {}

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func head(_ url: URL, bytes: Int, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        let (stream, response) = try await session.bytes(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw URLError(.badServerResponse)
        }
        // A server that ignores the range still stops here.
        var data = Data(capacity: bytes)
        for try await byte in stream {
            data.append(byte)
            if data.count >= bytes { break }
        }
        stream.task.cancel()
        return data
    }

    public func download(_ url: URL, to file: URL, timeout: TimeInterval,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { tmp, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    guard let tmp, let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
                        return continuation.resume(throwing: URLError(.badServerResponse))
                    }
                    do {
                        try? FileManager.default.removeItem(at: file)
                        try FileManager.default.moveItem(at: tmp, to: file)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                task.resume()
                // Report progress twice a second, and give up on overlong or oversized downloads.
                Task.detached {
                    let start = Date()
                    var last: Int64 = -1
                    while task.state == .running {
                        try? await Task.sleep(for: .milliseconds(500))
                        let done = task.countOfBytesReceived, total = task.countOfBytesExpectedToReceive
                        if done != last { progress(done, max(total, 0)); last = done }
                        if total > Self.maxDownload || done > Self.maxDownload || Date().timeIntervalSince(start) > timeout {
                            task.cancel()
                        }
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    // https only, also after redirects.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme == "https" ? request : nil
    }
}

private final class TaskBox: @unchecked Sendable {
    var task: URLSessionTask?
}
