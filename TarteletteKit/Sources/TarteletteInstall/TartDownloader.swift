import Foundation

/// Downloads one file of a release.
///
/// The seam through which the installer reaches the network, so its tests never do.
public protocol TartDownloading: Sendable {
  /// Downloads `url` into a new file at `destination`.
  ///
  /// - Parameters:
  ///   - limit: The most bytes to accept. A bigger download stops with `TartInstallError.downloadTooLarge`.
  ///   - progress: Called with the number of bytes received so far.
  /// - Throws: `TartInstallError`, or `CancellationError` when the task is cancelled. Nothing is left at
  ///   `destination` after a failure.
  func download(
    from url: URL, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void
  ) async throws
}

/// Downloads over `https` only with `URLSession`, refusing any redirect to another scheme.
public struct URLSessionTartDownloader: TartDownloading {
  private let makeConfiguration: @Sendable () -> URLSessionConfiguration
  private let userAgent: String

  /// - Parameter userAgent: Should name Tartelette, like `Tartelette/1.1.0`.
  public init(userAgent: String = "Tartelette") {
    self.init(configuration: { .ephemeral }, userAgent: userAgent)
  }

  /// A downloader whose sessions use the given configuration, such as one with stub protocols.
  init(configuration: @escaping @Sendable () -> URLSessionConfiguration, userAgent: String = "Tartelette") {
    self.makeConfiguration = configuration
    self.userAgent = userAgent
  }

  public func download(
    from url: URL, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard Self.isSecure(url) else { throw TartInstallError.insecureURL(url.absoluteString) }
    try Task.checkCancellation()

    let transfer = Transfer(destination: destination, limit: limit, progress: progress)
    let session = URLSession(configuration: makeConfiguration(), delegate: transfer, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let task = session.dataTask(with: request)

    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          transfer.start(task, continuation: continuation)
        }
      } onCancel: {
        transfer.cancel()
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  static func isSecure(_ url: URL?) -> Bool {
    url?.scheme?.lowercased() == "https"
  }
}

/// The state of one download, driven by `URLSession` delegate callbacks.
///
/// Callbacks arrive one at a time on the session's serial delegate queue; the lock guards the
/// fields `cancel()` touches from another thread.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let destination: URL
  private let limit: Int64
  private let progress: @Sendable (Int64) -> Void

  private let lock = NSLock()
  private var task: URLSessionTask?
  private var continuation: CheckedContinuation<Void, any Error>?
  private var cancelled = false

  private var file: FileHandle?
  private var received: Int64 = 0
  private var failure: (any Error)?

  init(destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void) {
    self.destination = destination
    self.limit = limit
    self.progress = progress
  }

  private var fileName: String { destination.lastPathComponent }

  func start(_ task: URLSessionTask, continuation: CheckedContinuation<Void, any Error>) {
    let alreadyCancelled = lock.withLock {
      self.task = task
      self.continuation = continuation
      return cancelled
    }
    if alreadyCancelled {
      lock.withLock { self.continuation = nil }
      continuation.resume(throwing: CancellationError())
      return
    }
    task.resume()
  }

  func cancel() {
    let task = lock.withLock {
      cancelled = true
      return self.task
    }
    task?.cancel()
  }

  /// Stops the transfer with `error`, which `didCompleteWithError` reports.
  private func fail(_ error: any Error, _ task: URLSessionTask) {
    if failure == nil { failure = error }
    task.cancel()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard URLSessionTartDownloader.isSecure(request.url) else {
      fail(TartInstallError.insecureURL(request.url?.absoluteString ?? ""), task)
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard failure == nil else { return completionHandler(.cancel) }
    guard URLSessionTartDownloader.isSecure(response.url) else {
      fail(TartInstallError.insecureURL(response.url?.absoluteString ?? ""), dataTask)
      return completionHandler(.cancel)
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      fail(TartInstallError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0), dataTask)
      return completionHandler(.cancel)
    }
    guard response.expectedContentLength <= limit else {
      fail(TartInstallError.downloadTooLarge(fileName: fileName), dataTask)
      return completionHandler(.cancel)
    }
    do {
      // A new file: never write into one that already exists.
      guard FileManager.default.createFile(atPath: destination.path, contents: nil),
        let handle = FileHandle(forWritingAtPath: destination.path)
      else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path]) }
      file = handle
    } catch {
      fail(TartInstallError.fileSystem(error), dataTask)
      return completionHandler(.cancel)
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil, let file else { return }
    received += Int64(data.count)
    guard received <= limit else { return fail(TartInstallError.downloadTooLarge(fileName: fileName), dataTask) }
    do {
      try file.write(contentsOf: data)
    } catch {
      return fail(TartInstallError.fileSystem(error), dataTask)
    }
    progress(received)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    try? file?.close()
    file = nil
    let (continuation, cancelled) = lock.withLock {
      defer { self.continuation = nil }
      return (self.continuation, self.cancelled)
    }
    if let failure {
      continuation?.resume(throwing: failure)
    } else if cancelled {
      continuation?.resume(throwing: CancellationError())
    } else if let error {
      continuation?.resume(throwing: TartInstallError.network(reason: error.localizedDescription))
    } else {
      continuation?.resume()
    }
  }
}
