import CryptoKit
import Foundation
import Testing

import TarteletteCLI
@testable import TarteletteInstall

/// What a fake release archive holds.
enum ArchiveContents: Sendable, CustomStringConvertible {
  /// `tart.app` and `LICENSE`, like the real archive.
  case standard
  /// `tart.app` is a symbolic link to a folder elsewhere.
  case appIsSymlink
  case withoutLicense
  case withoutApp
  /// `tart.app`, `LICENSE` and a `README`.
  case withExtraEntry
  /// `LICENSE` is a symbolic link into `tart.app`.
  case licenseIsSymlink
  /// Bytes that aren't a gzipped tar archive.
  case notAnArchive

  var description: String {
    switch self {
    case .standard: "standard"
    case .appIsSymlink: "tart.app is a symlink"
    case .withoutLicense: "no LICENSE"
    case .withoutApp: "no tart.app"
    case .withExtraEntry: "an extra README"
    case .licenseIsSymlink: "LICENSE is a symlink"
    case .notAnArchive: "not an archive"
    }
  }
}

/// Answers downloads from a table instead of the network, and records them.
final class StubDownloader: TartDownloading, @unchecked Sendable {
  enum Answer {
    case file(Data)
    case failure(any Error)
    /// Writes part of the file, signals `stalled`, then waits until the task is cancelled.
    case stallUntilCancelled
  }

  private let lock = NSLock()
  private var answers: [URL: Answer] = [:]
  private var recorded: [(url: URL, limit: Int64)] = []
  let (stalled, stalledContinuation) = AsyncStream.makeStream(of: Void.self)

  func answer(_ url: URL, with answer: Answer) {
    lock.withLock { answers[url] = answer }
  }

  var calls: [(url: URL, limit: Int64)] { lock.withLock { recorded } }

  func download(
    from url: URL, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let answer = lock.withLock {
      recorded.append((url, limit))
      return answers[url]
    }
    switch answer {
    case .file(let data):
      progress(Int64(data.count / 2))
      progress(Int64(data.count))
      try data.write(to: destination, options: .withoutOverwriting)
    case .failure(let error):
      throw error
    case .stallUntilCancelled:
      try Data("partial".utf8).write(to: destination)
      stalledContinuation.yield()
      try await Task.sleep(for: .seconds(3600))
    case nil:
      throw TartInstallError.httpStatus(404)
    }
  }
}

/// A signature check that accepts or rejects every bundle, and records what it checked.
final class FakeVerifier: TartSignatureVerifying, @unchecked Sendable {
  private let lock = NSLock()
  private var rejection: TartInstallError?
  private var checked: [URL] = []

  func reject(with error: TartInstallError?) { lock.withLock { rejection = error } }
  var checkedApps: [URL] { lock.withLock { checked } }

  func verify(appAt url: URL) throws {
    let rejection = lock.withLock {
      checked.append(url)
      return self.rejection
    }
    if let rejection { throw rejection }
  }
}

/// A fixed list of running executables.
final class FakeRunningExecutables: RunningExecutablesProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var paths: [String] = []

  func set(_ paths: [String]) { lock.withLock { self.paths = paths } }
  func runningExecutablePaths() -> [String] { lock.withLock { paths } }
}

/// A scratch managed layout, fake releases and the installer's test doubles.
struct InstallerFixture {
  let scratch: ScratchDirectory
  let layout: ManagedTartLayout
  let downloader = StubDownloader()
  let verifier = FakeVerifier()
  let running = FakeRunningExecutables()

  init() throws {
    scratch = try ScratchDirectory("installer")
    layout = ManagedTartLayout(root: scratch.appending("Managed"))
  }

  var installer: ManagedTartInstaller {
    ManagedTartInstaller(layout: layout, downloader: downloader, verifier: verifier, runningExecutables: running)
  }

  /// Paths inside the managed root, spelled independently of `ManagedTartLayout`.
  func managed(_ path: String) -> URL { scratch.appending("Managed/\(path)") }

  /// The path the kernel reports for a process executing `path`: every symbolic link resolved,
  /// including `/var` → `/private/var`.
  func realPath(_ path: String) -> String {
    guard let resolved = realpath(managed(path).path, nil) else { return managed(path).path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// Where `current` points, as written in the link.
  var currentDestination: String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: managed("current").path)
  }

  var stagingIsEmpty: Bool {
    ((try? FileManager.default.contentsOfDirectory(atPath: managed("staging").path)) ?? []).isEmpty
  }

  func remove() { scratch.remove() }

  /// Publishes a fake release of `version` and teaches the downloader its two files.
  ///
  /// - Parameters:
  ///   - bundleVersion: The version `tart.app` claims; `version` by default.
  ///   - checksum: The archive SHA-256 the checksums file lists; the real one by default.
  func publish(
    _ version: String, contents: ArchiveContents = .standard, bundleVersion: String? = nil, checksum: String? = nil
  ) throws -> TartRelease {
    let archive = try Self.makeArchive(
      version: bundleVersion ?? version, contents: contents, in: scratch.appending("server-\(UUID().uuidString)"))
    let digest = checksum ?? SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    let checksums = Data("\(digest)  tart.tar.gz\n".utf8)

    let base = "https://example.com/openai/tart/releases/download/\(version)-\(UUID().uuidString)"
    let archiveURL = URL(string: "\(base)/tart.tar.gz")!
    let checksumsURL = URL(string: "\(base)/tart_\(version)_checksums.txt")!
    downloader.answer(archiveURL, with: .file(archive))
    downloader.answer(checksumsURL, with: .file(checksums))
    return TartRelease(
      version: TartVersion(version)!, tag: version, publishedAt: nil,
      pageURL: URL(string: "https://github.com/openai/tart/releases/tag/\(version)")!,
      archive: TartReleaseAsset(name: "tart.tar.gz", downloadURL: archiveURL, size: Int64(archive.count)),
      checksums: TartReleaseAsset(
        name: "tart_\(version)_checksums.txt", downloadURL: checksumsURL, size: Int64(checksums.count)))
  }

  /// The script standing in for the `tart` executable of `version`.
  static func executable(_ version: String) -> Data { Data("#!/bin/sh\necho \(version)\n".utf8) }
  static let license = Data("Functional Source License, Version 1.1, ALv2 Future License\n".utf8)

  /// A gzipped tar archive laid out like `tart.tar.gz`, built with `/usr/bin/tar`.
  static func makeArchive(version: String, contents: ArchiveContents, in directory: URL) throws -> Data {
    let fileManager = FileManager.default
    let payload = directory.appendingPathComponent("payload", isDirectory: true)
    try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
    if case .notAnArchive = contents { return Data("<html>Not Found</html>".utf8) }

    let app = payload.appendingPathComponent(contents == .appIsSymlink ? "elsewhere.app" : "tart.app")
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.github.cirruslabs.tart", "CFBundleExecutable": "tart",
      "CFBundleShortVersionString": version,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let tart = macOS.appendingPathComponent("tart")
    try executable(version).write(to: tart)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tart.path)
    if contents != .licenseIsSymlink { try license.write(to: payload.appendingPathComponent("LICENSE")) }

    var entries = ["tart.app", "LICENSE"]
    switch contents {
    case .appIsSymlink:
      try fileManager.createSymbolicLink(
        atPath: payload.appendingPathComponent("tart.app").path, withDestinationPath: "elsewhere.app")
    case .withoutLicense: entries = ["tart.app"]
    case .withoutApp: entries = ["LICENSE"]
    case .withExtraEntry:
      try Data("read me".utf8).write(to: payload.appendingPathComponent("README"))
      entries.append("README")
    case .licenseIsSymlink:
      try fileManager.createSymbolicLink(
        atPath: payload.appendingPathComponent("LICENSE").path, withDestinationPath: "tart.app/Contents/Info.plist")
    case .standard, .notAnArchive: break
    }

    let archive = directory.appendingPathComponent("tart.tar.gz")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-czf", archive.path, "-C", payload.path] + entries
    try tar.run()
    tar.waitUntilExit()
    try #require(tar.terminationStatus == 0)
    return try Data(contentsOf: archive)
  }
}

extension ArchiveContents: Equatable {}

/// Everything under the managed root except scratch space and the lock: `versions/`, `current` and
/// the manifest, compared byte for byte.
struct LayoutSnapshot: Equatable, CustomStringConvertible {
  var entries: [String: String] = [:]

  init(_ root: URL) {
    let fileManager = FileManager.default
    guard let walker = fileManager.enumerator(atPath: root.path) else { return }
    for case let path as String in walker {
      if path == ".lock" || path == "staging" || path.hasPrefix("staging/") { continue }
      let url = root.appendingPathComponent(path)
      let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
      switch type {
      case .typeSymbolicLink?:
        entries[path] = "link → " + ((try? fileManager.destinationOfSymbolicLink(atPath: url.path)) ?? "?")
      case .typeDirectory?:
        entries[path] = "directory"
      default:
        let data = (try? Data(contentsOf: url)) ?? Data()
        entries[path] = "file " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }
    }
  }

  var description: String { entries.keys.sorted().map { "\($0): \(entries[$0]!)" }.joined(separator: "\n") }
}
