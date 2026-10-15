import Foundation
import Testing

@testable import TarteletteInstall

@Suite("Downloading release files")
struct URLSessionTartDownloaderTests {
  let downloader = URLSessionTartDownloader(configuration: { StubURLProtocol.configuration() })

  /// Records the progress reports of one download.
  final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    var reports: [Int64] { lock.withLock { values } }
    func record(_ value: Int64) { lock.withLock { values.append(value) } }
  }

  @Test func writesTheFileAndReportsTheBytesReceived() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz")
    StubURLProtocol.register(url, .respond(chunks: [Data("hello ".utf8), Data("tart".utf8)]))
    let destination = scratch.appending("tart.tar.gz")
    let log = ProgressLog()

    try await downloader.download(from: url, to: destination, limit: 100, progress: log.record)

    #expect(try Data(contentsOf: destination) == Data("hello tart".utf8))
    #expect(log.reports.last == 10)
    #expect(log.reports == log.reports.sorted())
  }

  @Test func followsARedirectToAnotherHTTPSAddress() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz")
    let mirror = StubURLProtocol.uniqueURL("objects/tart.tar.gz")
    StubURLProtocol.register(url, .redirect(to: mirror))
    StubURLProtocol.register(mirror, .respond(chunks: [Data("tart".utf8)]))
    let destination = scratch.appending("tart.tar.gz")

    try await downloader.download(from: url, to: destination, limit: 100, progress: { _ in })

    #expect(try Data(contentsOf: destination) == Data("tart".utf8))
  }

  @Test func refusesAnAddressThatIsntHTTPSWithoutConnecting() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz", scheme: "http")
    StubURLProtocol.register(url, .respond(chunks: [Data("tart".utf8)]))
    let destination = scratch.appending("tart.tar.gz")

    let error = await #expect(throws: TartInstallError.self) {
      try await downloader.download(from: url, to: destination, limit: 100, progress: { _ in })
    }
    #expect(error == .insecureURL(url.absoluteString))
    #expect(!StubURLProtocol.wasRequested(url))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func refusesARedirectToAnAddressThatIsntHTTPS() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz")
    let plain = StubURLProtocol.uniqueURL("tart.tar.gz", scheme: "http")
    StubURLProtocol.register(url, .redirect(to: plain))
    StubURLProtocol.register(plain, .respond(chunks: [Data("tart".utf8)]))
    let destination = scratch.appending("tart.tar.gz")

    let error = await #expect(throws: TartInstallError.self) {
      try await downloader.download(from: url, to: destination, limit: 100, progress: { _ in })
    }
    #expect(error == .insecureURL(plain.absoluteString))
    #expect(!StubURLProtocol.wasRequested(plain))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func reportsAnUnsuccessfulStatusAndKeepsNothing() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz")
    StubURLProtocol.register(url, .respond(status: 404, chunks: [Data("Not Found".utf8)]))
    let destination = scratch.appending("tart.tar.gz")

    let error = await #expect(throws: TartInstallError.self) {
      try await downloader.download(from: url, to: destination, limit: 100, progress: { _ in })
    }
    #expect(error == .httpStatus(404))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func stopsADownloadThatGrowsBeyondTheLimit() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz")
    let chunk = Data(repeating: 0x2A, count: 64)
    StubURLProtocol.register(url, .respond(chunks: Array(repeating: chunk, count: 4)))
    let destination = scratch.appending("tart.tar.gz")
    let log = ProgressLog()

    let error = await #expect(throws: TartInstallError.self) {
      try await downloader.download(from: url, to: destination, limit: 100, progress: log.record)
    }
    #expect(error == .downloadTooLarge(fileName: "tart.tar.gz"))
    #expect(log.reports.allSatisfy { $0 <= 100 })
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func refusesADownloadAnnouncedLargerThanTheLimit() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz")
    StubURLProtocol.register(
      url, .respond(headers: ["Content-Length": "5000"], chunks: [Data("tart".utf8)], finish: false))
    let destination = scratch.appending("tart.tar.gz")

    let error = await #expect(throws: TartInstallError.self) {
      try await downloader.download(from: url, to: destination, limit: 100, progress: { _ in })
    }
    #expect(error == .downloadTooLarge(fileName: "tart.tar.gz"))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func reportsANetworkFailure() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz")
    StubURLProtocol.register(url, .fail(.notConnectedToInternet))
    let destination = scratch.appending("tart.tar.gz")

    let error = await #expect(throws: TartInstallError.self) {
      try await downloader.download(from: url, to: destination, limit: 100, progress: { _ in })
    }
    guard case .network = error else {
      Issue.record("Expected a network error, got \(String(describing: error))")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  /// Bounded, so a download that never reports progress fails the test instead of hanging it, and
  /// the scratch folder is still removed.
  @Test(.timeLimit(.minutes(1)))
  func cancellingStopsTheDownloadAndKeepsNothing() async throws {
    let scratch = try ScratchDirectory("download")
    defer { scratch.remove() }
    let url = StubURLProtocol.uniqueURL("tart.tar.gz")
    StubURLProtocol.register(url, .respond(chunks: [Data("part".utf8)], finish: false))
    let destination = scratch.appending("tart.tar.gz")
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)

    let download = Task {
      defer { startedContinuation.finish() }
      try await downloader.download(from: url, to: destination, limit: 100) { _ in startedContinuation.yield() }
    }
    for await _ in started { break }
    download.cancel()

    await #expect(throws: CancellationError.self) { try await download.value }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
}
