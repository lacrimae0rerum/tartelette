import Foundation
import TarteletteCore

/// A guest that clipboard and file operations target.
public struct GuestEndpoint: Sendable, Hashable {
  public var vmName: String
  public var os: VMOperatingSystem
  public var transport: any GuestTransport

  public init(vmName: String, os: VMOperatingSystem, transport: any GuestTransport) {
    self.vmName = vmName
    self.os = os
    self.transport = transport
  }

  public static func == (lhs: GuestEndpoint, rhs: GuestEndpoint) -> Bool {
    lhs.vmName == rhs.vmName && lhs.os == rhs.os && lhs.transport.label == rhs.transport.label
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(vmName)
    hasher.combine(os)
    hasher.combine(transport.label)
  }
}

/// The guest pasteboard right after the bridge wrote to it.
public struct GuestClipboardState: Sendable, Equatable {
  /// The guest's change counter (macOS) or content token (Linux) after the write.
  public var changeCount: Int
  public var fingerprint: String

  public init(changeCount: Int, fingerprint: String) {
    self.changeCount = changeCount
    self.fingerprint = fingerprint
  }
}

/// Moves clipboard contents and files between the host and a guest over a `GuestTransport`.
///
/// Every transfer is verified with SHA-256. Small payloads (≤ `chunkSize`) travel in one command.
/// Larger ones first try one fast stream and, if the checksum disagrees, fall back to
/// `chunkSize` blocks with per-block checksums and retries. This works around tart #1347, where
/// macOS 12–15 guests silently drop 64 KiB blocks from exec streams above ~256 KiB.
public actor ClipboardBridge {
  public struct Options: Sendable {
    /// Largest block moved by a single guest command on the slow path.
    public var chunkSize: Int
    /// Largest base64 size returned inline by the macOS read script.
    public var inlineLimit: Int
    public var maxRetries: Int
    /// Try a single verified stream before chunking large transfers.
    public var allowsFastPath: Bool
    /// Overrides the guest staging directory (default: `GuestScripts.defaultStagingRoot`).
    public var guestStagingRoot: String?
    /// Uses a named guest pasteboard instead of the general one (macOS guests; used by tests).
    public var guestPasteboardName: String?

    public init(
      chunkSize: Int = 128 * 1024,
      inlineLimit: Int = 96 * 1024,
      maxRetries: Int = 3,
      allowsFastPath: Bool = true,
      guestStagingRoot: String? = nil,
      guestPasteboardName: String? = nil
    ) {
      self.chunkSize = chunkSize
      self.inlineLimit = inlineLimit
      self.maxRetries = maxRetries
      self.allowsFastPath = allowsFastPath
      self.guestStagingRoot = guestStagingRoot
      self.guestPasteboardName = guestPasteboardName
    }
  }

  public let fileStagingDirectory: URL
  public let options: Options
  /// How many transfers needed the chunked fallback (diagnostics and tests).
  public private(set) var chunkedTransferCount = 0

  public init(fileStagingDirectory: URL, options: Options = Options()) {
    self.fileStagingDirectory = fileStagingDirectory
    self.options = options
  }

  // MARK: Clipboard

  /// Replaces the guest clipboard with `payload`.
  public func pushToGuest(_ payload: ClipboardPayload, endpoint: GuestEndpoint) async throws -> GuestClipboardState {
    switch endpoint.os {
    case .macOS: try await pushToMacOS(payload, endpoint: endpoint)
    case .linux: try await pushToLinux(payload, endpoint: endpoint)
    case .unknown: throw GuestTransportError.unsupported("The guest operating system is unknown.")
    }
  }

  /// Reads the guest clipboard. Files are copied into a unique folder under `fileStagingDirectory`.
  ///
  /// - Parameter maxBytes: Throws `GuestTransportError.tooLarge` before transferring anything bigger.
  public func pullFromGuest(_ endpoint: GuestEndpoint, maxBytes: Int? = nil) async throws -> ClipboardPayload? {
    switch endpoint.os {
    case .macOS: try await pullFromMacOS(endpoint, maxBytes: maxBytes)
    case .linux: try await pullFromLinux(endpoint, maxBytes: maxBytes)
    case .unknown: throw GuestTransportError.unsupported("The guest operating system is unknown.")
    }
  }

  /// The guest's pasteboard change count (macOS) or a content token (Linux).
  public func guestChangeCount(_ endpoint: GuestEndpoint) async throws -> Int {
    let command: [String]
    switch endpoint.os {
    case .macOS: command = GuestScripts.macOSChangeCount(pasteboardName: options.guestPasteboardName)
    case .linux: command = GuestScripts.linuxChangeCount()
    case .unknown: throw GuestTransportError.unsupported("The guest operating system is unknown.")
    }
    let output = try await checked(endpoint, command, timeout: .seconds(15))
    return try decode(ChangeCountReply.self, from: output.stdout).changeCount
  }

  // MARK: Files

  /// Copies host files or folders into `guestDirectory` (never overwriting) and returns their guest paths.
  public func sendFiles(_ files: [URL], to endpoint: GuestEndpoint, guestDirectory: String) async throws -> [String] {
    guard !files.isEmpty else { return [] }
    let archive = try temporaryHostFile(extension: "tgz")
    defer { try? FileManager.default.removeItem(at: archive) }
    try await HostArchiver.archive(files, to: archive)
    let data = try Data(contentsOf: archive)
    let guestArchive = stagingPath(endpoint, "\(UUID().uuidString).tgz")
    try await upload(data, to: guestArchive, endpoint: endpoint)
    let output = try await checked(
      endpoint, GuestScripts.extractArchive(guestArchive, into: guestDirectory, os: endpoint.os),
      timeout: timeout(for: data.count))
    return output.stdoutString.split(whereSeparator: \.isNewline).map(String.init)
  }

  /// Copies guest files or folders into a new folder inside `directory` and returns the local URLs.
  public func receiveFiles(_ guestPaths: [String], from endpoint: GuestEndpoint, into directory: URL) async throws -> [URL] {
    guard !guestPaths.isEmpty else { return [] }
    let guestArchive = stagingPath(endpoint, "\(UUID().uuidString).tgz")
    _ = try await checked(
      endpoint, GuestScripts.createArchive(guestArchive, paths: guestPaths, os: endpoint.os), timeout: .seconds(600))
    let data: Data
    do {
      data = try await download(guestArchive, endpoint: endpoint)
    } catch {
      _ = try? await endpoint.transport.run(GuestScripts.remove([guestArchive], os: endpoint.os), standardInput: nil, timeout: .seconds(15))
      throw error
    }
    _ = try? await endpoint.transport.run(GuestScripts.remove([guestArchive], os: endpoint.os), standardInput: nil, timeout: .seconds(15))

    let archive = try temporaryHostFile(extension: "tgz")
    defer { try? FileManager.default.removeItem(at: archive) }
    try data.write(to: archive)
    return try await HostArchiver.extract(archive, into: directory.appendingPathComponent(UUID().uuidString, isDirectory: true))
  }

  // MARK: Verified transfer

  /// Writes `data` to a guest file, verifying the result with SHA-256.
  public func upload(_ data: Data, to guestPath: String, endpoint: GuestEndpoint) async throws {
    let expected = Digest.sha256(data)
    let os = endpoint.os
    let small = data.count <= options.chunkSize
    if small || options.allowsFastPath {
      let attempts = small ? options.maxRetries : 1
      for _ in 0..<attempts {
        let output = try await checked(endpoint, GuestScripts.writeFile(guestPath, os: os), input: data, timeout: timeout(for: data.count))
        if output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == expected { return }
      }
      if small { throw GuestTransportError.integrityCheckFailed("upload of \(data.count) bytes to \(guestPath)") }
    }

    chunkedTransferCount += 1
    _ = try await checked(endpoint, GuestScripts.truncateFile(guestPath, os: os), timeout: .seconds(15))
    for (index, chunk) in chunks(of: data).enumerated() {
      let chunkHash = Digest.sha256(chunk)
      var verified = false
      for _ in 0..<options.maxRetries {
        let output = try await checked(
          endpoint, GuestScripts.writeChunk(guestPath, index: index, chunkSize: options.chunkSize, os: os),
          input: chunk, timeout: .seconds(30))
        if output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == chunkHash {
          verified = true
          break
        }
      }
      if !verified { throw GuestTransportError.integrityCheckFailed("block \(index) of \(guestPath)") }
    }
    let info = try await fileInfo(guestPath, endpoint: endpoint)
    guard info.size == data.count, info.sha256 == expected else {
      throw GuestTransportError.integrityCheckFailed("upload of \(data.count) bytes to \(guestPath)")
    }
  }

  /// Reads a guest file, verifying the result with SHA-256.
  public func download(_ guestPath: String, endpoint: GuestEndpoint) async throws -> Data {
    let info = try await fileInfo(guestPath, endpoint: endpoint)
    let os = endpoint.os
    let small = info.size <= options.chunkSize
    if small || options.allowsFastPath {
      let attempts = small ? options.maxRetries : 1
      for _ in 0..<attempts {
        let output = try await checked(endpoint, GuestScripts.readFile(guestPath, os: os), timeout: timeout(for: info.size))
        if output.stdout.count == info.size, Digest.sha256(output.stdout) == info.sha256 { return output.stdout }
      }
      if small { throw GuestTransportError.integrityCheckFailed("download of \(guestPath)") }
    }

    chunkedTransferCount += 1
    let hashes = try await checked(
      endpoint, GuestScripts.chunkHashes(guestPath, chunkSize: options.chunkSize, os: os), timeout: timeout(for: info.size)
    ).stdoutString.split(whereSeparator: \.isNewline).map(String.init)
    var data = Data(capacity: info.size)
    for (index, expected) in hashes.enumerated() {
      var block: Data?
      for _ in 0..<options.maxRetries {
        let output = try await checked(
          endpoint, GuestScripts.readChunk(guestPath, index: index, chunkSize: options.chunkSize, os: os), timeout: .seconds(30))
        if Digest.sha256(output.stdout) == expected {
          block = output.stdout
          break
        }
      }
      guard let block else { throw GuestTransportError.integrityCheckFailed("block \(index) of \(guestPath)") }
      data.append(block)
    }
    guard data.count == info.size, Digest.sha256(data) == info.sha256 else {
      throw GuestTransportError.integrityCheckFailed("download of \(guestPath)")
    }
    return data
  }

  // MARK: macOS guests

  private func pushToMacOS(_ payload: ClipboardPayload, endpoint: GuestEndpoint) async throws -> GuestClipboardState {
    var guestFiles: [String] = []
    if !payload.files.isEmpty {
      guestFiles = try await sendFiles(payload.files, to: endpoint, guestDirectory: stagingPath(endpoint, UUID().uuidString))
    }
    let body = try JSONEncoder().encode(
      MacOSWritePayload(
        items: payload.items.map { .init(type: $0.type, data: $0.data.base64EncodedString()) }, files: guestFiles))

    let command: [String]
    var input: Data?
    if body.count <= options.chunkSize {
      command = GuestScripts.macOSWrite(pasteboardName: options.guestPasteboardName)
      input = body
    } else {
      let staged = stagingPath(endpoint, "\(UUID().uuidString).json")
      try await upload(body, to: staged, endpoint: endpoint)
      command = GuestScripts.macOSWrite(pasteboardName: options.guestPasteboardName, payloadFile: staged)
    }
    let output = try await checked(endpoint, command, input: input, timeout: timeout(for: body.count))
    let reply = try decode(ChangeCountReply.self, from: output.stdout)
    return GuestClipboardState(changeCount: reply.changeCount, fingerprint: payload.fingerprint)
  }

  private func pullFromMacOS(_ endpoint: GuestEndpoint, maxBytes: Int?) async throws -> ClipboardPayload? {
    let output = try await checked(
      endpoint,
      GuestScripts.macOSRead(
        pasteboardName: options.guestPasteboardName, stagingDirectory: stagingRoot(endpoint),
        inlineLimit: options.inlineLimit),
      timeout: .seconds(60))
    let manifest = try decode(GuestManifest.self, from: output.stdout)

    if !manifest.files.isEmpty {
      let paths = manifest.files.compactMap(\.path)
      let total = manifest.files.reduce(0) { $0 + ($1.size ?? 0) }
      if let maxBytes, total > maxBytes { throw GuestTransportError.tooLarge(bytes: total, limit: maxBytes) }
      let local = try await receiveFiles(paths, from: endpoint, into: fileStagingDirectory)
      return ClipboardPayload(files: ordered(local, like: paths))
    }

    var entries = manifest.items
    if let staged = manifest.staged {
      // Base64 inflates by 4/3; compare the decoded size with the limit.
      if let maxBytes, staged.size * 3 / 4 > maxBytes {
        _ = try? await endpoint.transport.run(GuestScripts.remove([staged.path], os: .macOS), standardInput: nil, timeout: .seconds(15))
        throw GuestTransportError.tooLarge(bytes: staged.size * 3 / 4, limit: maxBytes)
      }
      let data = try await download(staged.path, endpoint: endpoint)
      _ = try? await endpoint.transport.run(GuestScripts.remove([staged.path], os: .macOS), standardInput: nil, timeout: .seconds(15))
      entries = try decode(StagedItems.self, from: data).items
    }
    let items = entries.compactMap { entry -> ClipboardRepresentation? in
      guard let encoded = entry.data, let data = Data(base64Encoded: encoded) else { return nil }
      return ClipboardRepresentation(type: entry.type, data: data)
    }
    let total = items.reduce(0) { $0 + $1.data.count }
    if let maxBytes, total > maxBytes { throw GuestTransportError.tooLarge(bytes: total, limit: maxBytes) }
    return items.isEmpty ? nil : ClipboardPayload(items: items)
  }

  // MARK: Linux guests

  private func pushToLinux(_ payload: ClipboardPayload, endpoint: GuestEndpoint) async throws -> GuestClipboardState {
    let mime: String
    let data: Data
    if !payload.files.isEmpty {
      let paths = try await sendFiles(payload.files, to: endpoint, guestDirectory: stagingPath(endpoint, UUID().uuidString))
      mime = "text/uri-list"
      data = Data(paths.map { URL(fileURLWithPath: $0).absoluteString }.joined(separator: "\r\n").utf8)
    } else if let text = payload.data(for: ClipboardRepresentation.plainText) {
      (mime, data) = ("text/plain", text)
    } else if let png = payload.data(for: ClipboardRepresentation.png) {
      (mime, data) = ("image/png", png)
    } else if let html = payload.data(for: ClipboardRepresentation.html) {
      (mime, data) = ("text/html", html)
    } else {
      throw GuestTransportError.unsupported("Linux guests accept text, HTML, PNG images and files.")
    }
    let staged = stagingPath(endpoint, "\(UUID().uuidString).bin")
    try await upload(data, to: staged, endpoint: endpoint)
    let output = try await checked(endpoint, GuestScripts.linuxWrite(mime: mime, stagedFile: staged), timeout: .seconds(30))
    let reply = try decode(ChangeCountReply.self, from: output.stdout)
    return GuestClipboardState(changeCount: reply.changeCount, fingerprint: payload.fingerprint)
  }

  private func pullFromLinux(_ endpoint: GuestEndpoint, maxBytes: Int?) async throws -> ClipboardPayload? {
    let output = try await checked(endpoint, GuestScripts.linuxRead(stagingDirectory: stagingRoot(endpoint)), timeout: .seconds(30))
    let manifest = try decode(GuestManifest.self, from: output.stdout)
    let stagedPaths = manifest.items.compactMap(\.path)
    defer {
      if !stagedPaths.isEmpty {
        Task { [transport = endpoint.transport] in
          _ = try? await transport.run(GuestScripts.remove(stagedPaths, os: .linux), standardInput: nil, timeout: .seconds(15))
        }
      }
    }

    let filePaths = manifest.files.compactMap { $0.uri.flatMap(URL.init(string:))?.path ?? $0.path }
    if !filePaths.isEmpty {
      let local = try await receiveFiles(filePaths, from: endpoint, into: fileStagingDirectory)
      if let maxBytes {
        let total = local.reduce(0) { $0 + ClipboardPayload.byteCount(of: $1) }
        if total > maxBytes { throw GuestTransportError.tooLarge(bytes: total, limit: maxBytes) }
      }
      return ClipboardPayload(files: ordered(local, like: filePaths))
    }

    let total = manifest.items.reduce(0) { $0 + ($1.size ?? 0) }
    if let maxBytes, total > maxBytes { throw GuestTransportError.tooLarge(bytes: total, limit: maxBytes) }
    var items: [ClipboardRepresentation] = []
    for entry in manifest.items {
      guard let path = entry.path else { continue }
      items.append(ClipboardRepresentation(type: entry.type, data: try await download(path, endpoint: endpoint)))
    }
    return items.isEmpty ? nil : ClipboardPayload(items: items)
  }

  // MARK: Helpers

  private func fileInfo(_ path: String, endpoint: GuestEndpoint) async throws -> (size: Int, sha256: String) {
    let output = try await checked(endpoint, GuestScripts.fileInfo(path, os: endpoint.os), timeout: .seconds(120))
    let fields = output.stdoutString.split(whereSeparator: \.isWhitespace)
    guard fields.count == 2, let size = Int(fields[0]) else {
      throw GuestTransportError.unexpectedOutput(output.stdoutString)
    }
    return (size, String(fields[1]))
  }

  /// Runs a guest command and throws unless it exits successfully.
  private func checked(
    _ endpoint: GuestEndpoint, _ command: [String], input: Data? = nil, timeout: Duration
  ) async throws -> CommandOutput {
    let output = try await endpoint.transport.run(command, standardInput: input, timeout: timeout)
    guard output.succeeded else {
      if endpoint.os == .linux, output.status == GuestScripts.linuxUnsupportedStatus {
        throw GuestTransportError.unsupported(output.diagnostic)
      }
      throw GuestTransportError.commandFailed(status: output.status, message: GuestProbe.friendlyReason(for: output.diagnostic, status: output.status))
    }
    return output
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw GuestTransportError.unexpectedOutput(String(decoding: data.prefix(200), as: UTF8.self))
    }
  }

  private func chunks(of data: Data) -> [Data] {
    stride(from: 0, to: data.count, by: options.chunkSize).map { offset in
      data.subdata(in: (data.startIndex + offset)..<(data.startIndex + min(offset + options.chunkSize, data.count)))
    }
  }

  private func stagingRoot(_ endpoint: GuestEndpoint) -> String {
    options.guestStagingRoot ?? GuestScripts.defaultStagingRoot(for: endpoint.os)
  }

  private func stagingPath(_ endpoint: GuestEndpoint, _ name: String) -> String {
    stagingRoot(endpoint) + "/" + name
  }

  private func temporaryHostFile(extension pathExtension: String) throws -> URL {
    try FileManager.default.createDirectory(at: fileStagingDirectory, withIntermediateDirectories: true)
    return fileStagingDirectory.appendingPathComponent(".transfer-\(UUID().uuidString).\(pathExtension)")
  }

  /// A generous timeout: 30 s plus one second per 2 MB.
  private func timeout(for bytes: Int) -> Duration {
    .seconds(30 + bytes / 2_000_000)
  }

  /// Sorts extracted entries to follow the guest's original order.
  private func ordered(_ local: [URL], like guestPaths: [String]) -> [URL] {
    let order = Dictionary(guestPaths.enumerated().map { ($1.split(separator: "/").last.map(String.init) ?? $1, $0) }) { first, _ in first }
    return local.sorted { (order[$0.lastPathComponent] ?? .max) < (order[$1.lastPathComponent] ?? .max) }
  }
}

// MARK: Wire formats

struct ChangeCountReply: Decodable {
  var changeCount: Int
}

struct MacOSWritePayload: Encodable {
  struct Item: Encodable {
    var type: String
    var data: String
  }

  var items: [Item]
  var files: [String]
}

struct GuestManifest: Decodable {
  struct Entry: Decodable {
    var type: String
    var data: String?
    var path: String?
    var size: Int?
  }

  struct FileEntry: Decodable {
    var path: String?
    var uri: String?
    var size: Int?
  }

  struct Staged: Decodable {
    var path: String
    var size: Int
  }

  var changeCount: Int
  var items: [Entry]
  var files: [FileEntry]
  var staged: Staged?

  enum CodingKeys: String, CodingKey { case changeCount, items, files, staged }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    changeCount = try container.decode(Int.self, forKey: .changeCount)
    items = try container.decodeIfPresent([Entry].self, forKey: .items) ?? []
    files = try container.decodeIfPresent([FileEntry].self, forKey: .files) ?? []
    staged = try container.decodeIfPresent(Staged.self, forKey: .staged)
  }
}

struct StagedItems: Decodable {
  var items: [GuestManifest.Entry]
}
