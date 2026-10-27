import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A response body as it arrives, byte by byte or line by line (server-sent events, streamed JSON): URLSession's
/// `bytes(for:)` on Apple platforms, a data delegate on swift-corelibs-foundation, which lacks it.
///
/// ```swift
/// let (body, response) = try await HTTPBytes.response(for: request)
/// for try await line in body.lines { … }
/// ```
public struct HTTPBytes: AsyncSequence, Sendable {
  public typealias Element = UInt8

  #if canImport(FoundationNetworking)
    let chunks: AsyncThrowingStream<Data, any Error>
  #else
    let bytes: URLSession.AsyncBytes
  #endif

  /// Sends `request` and answers once the response's headers are in; the body follows through the sequence.
  public static func response(for request: URLRequest, session: URLSession = .shared) async throws
    -> (HTTPBytes, URLResponse)
  {
    #if canImport(FoundationNetworking)
      let receiver = Receiver()
      let delegateSession = URLSession(configuration: session.configuration, delegate: receiver, delegateQueue: nil)
      let task = delegateSession.dataTask(with: request)
      let response = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          receiver.start(task, continuation)
        }
      } onCancel: {
        task.cancel()
      }
      delegateSession.finishTasksAndInvalidate()
      return (HTTPBytes(chunks: receiver.chunks), response)
    #else
      let (bytes, response) = try await session.bytes(for: request)
      return (HTTPBytes(bytes: bytes), response)
    #endif
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    #if canImport(FoundationNetworking)
      var chunks: AsyncThrowingStream<Data, any Error>.AsyncIterator
      var buffer = Data()
      var index = 0

      public mutating func next() async throws -> UInt8? {
        while index >= buffer.count {
          guard let chunk = try await chunks.next() else { return nil }
          buffer = chunk
          index = 0
        }
        defer { index += 1 }
        return buffer[buffer.startIndex + index]
      }
    #else
      var bytes: URLSession.AsyncBytes.AsyncIterator

      public mutating func next() async throws -> UInt8? { try await bytes.next() }
    #endif
  }

  public func makeAsyncIterator() -> AsyncIterator {
    #if canImport(FoundationNetworking)
      AsyncIterator(chunks: chunks.makeAsyncIterator())
    #else
      AsyncIterator(bytes: bytes.makeAsyncIterator())
    #endif
  }

  /// The body's lines, without their line breaks (`\n`, `\r\n`, `\r`).
  public var lines: AsyncThrowingStream<String, any Error> {
    #if canImport(FoundationNetworking)
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            var line: [UInt8] = []
            var afterReturn = false
            for try await byte in self {
              if afterReturn, byte == 10 {
                afterReturn = false
                continue
              }
              afterReturn = byte == 13
              if byte == 10 || byte == 13 {
                continuation.yield(String(decoding: line, as: UTF8.self))
                line.removeAll(keepingCapacity: true)
              } else {
                line.append(byte)
              }
            }
            if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    #else
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            for try await line in bytes.lines { continuation.yield(line) }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    #endif
  }
}

#if canImport(FoundationNetworking)
  /// Hands the response over once, then the body's chunks as they come.
  private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private var waiting: CheckedContinuation<URLResponse, any Error>?

    override init() {
      (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    }

    func start(_ task: URLSessionDataTask, _ waiting: CheckedContinuation<URLResponse, any Error>) {
      lock.withLock { self.waiting = waiting }
      task.resume()
    }

    private func answer(_ result: Result<URLResponse, any Error>) {
      let waiting = lock.withLock { () -> CheckedContinuation<URLResponse, any Error>? in
        defer { self.waiting = nil }
        return self.waiting
      }
      waiting?.resume(with: result)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      answer(.success(response))
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      if let error {
        answer(.failure(error))
        continuation.finish(throwing: error)
      } else {
        if let response = task.response { answer(.success(response)) }
        continuation.finish()
      }
    }
  }
#endif
