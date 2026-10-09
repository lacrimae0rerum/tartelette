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
  /// Fingerprint of what the guest now holds. Linux guests keep a single flavour, so this can be
  /// the fingerprint of a projection (e.g. plain text only) rather than of the pushed payload.
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
///
/// Clipboard files are staged in per-transfer folders on both sides; only the most recent
/// `Options.stagingFoldersToKeep` are kept, so automatic sync can't fill either disk.
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
    /// How many clipboard file-staging folders to keep on each side (host and guest).
    public var stagingFoldersToKeep: Int

    public init(
      chunkSize: Int = 128 * 1024,
      inlineLimit: Int = 96 * 1024,
      maxRetries: Int = 3,
      allowsFastPath: Bool = true,
      guestStagingRoot: String? = nil,
      guestPasteboardName: String? = nil,
      stagingFoldersToKeep: Int = 5
    ) {
      self.chunkSize = chunkSize
      self.inlineLimit = inlineLimit
      self.maxRetries = maxRetries
      self.allowsFastPath = allowsFastPath
      self.guestStagingRoot = guestStagingRoot
      self.guestPasteboardName = guestPasteboardName
      self.stagingFoldersToKeep = max(1, stagingFoldersToKeep)
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
  /// - Parameters:
  ///   - maxBytes: Throws `GuestTransportError.tooLarge` before transferring anything bigger.
  ///   - includeFiles: When false, a clipboard holding files reads as empty (nil) and nothing is
  ///     copied.
  public func pullFromGuest(_ endpoint: GuestEndpoint, maxBytes: Int? = nil, includeFiles: Bool = true) async throws
    -> ClipboardPayload?
  {
    switch endpoint.os {
    case .macOS: try await pullFromMacOS(endpoint, maxBytes: maxBytes, includeFiles: includeFiles)
    case .linux: try await pullFromLinux(endpoint, maxBytes: maxBytes, includeFiles: includeFiles)
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
    let output = try await checked(endpoint, command, operation: "check the guest clipboard", timeout: .seconds(15))
    return try decode(ChangeCountReply.self, from: output.stdout).changeCount
  }

  // MARK: Files

  /// Copies host files or folders into `guestDirectory` (never overwriting) and returns their guest paths.
  ///
  /// - Throws: `GuestTransferError.duplicateNames` when two items share a name.
  public func sendFiles(_ files: [URL], to endpoint: GuestEndpoint, guestDirectory: String) async throws -> [String] {
    guard !files.isEmpty else { return [] }
    try GuestTransferError.checkUniqueNames(files.map(\.lastPathComponent))
    let archive = try temporaryHostFile(extension: "tgz")
    defer { try? FileManager.default.removeItem(at: archive) }
    try await HostArchiver.archive(files, to: archive)
    let data = try Data(contentsOf: archive)
    let guestArchive = stagingPath(endpoint, "\(UUID().uuidString).tgz")
    do {
      try await upload(data, to: guestArchive, endpoint: endpoint)
    } catch {
      await removeGuest([guestArchive], endpoint)
      throw error
    }
    let output: CommandOutput
    do {
      output = try await checked(
        endpoint, GuestScripts.extractArchive(guestArchive, into: guestDirectory, os: endpoint.os),
        operation: "unpack the copied files", timeout: timeout(for: data.count))
    } catch {
      // The script deletes the archive itself only after a successful extraction.
      await removeGuest([guestArchive], endpoint)
      throw error
    }
    return output.stdoutString.split(whereSeparator: \.isNewline).map(String.init)
  }

  /// Copies guest files or folders into a new folder inside `directory` and returns the local URLs.
  ///
  /// - Throws: `GuestTransferError.duplicateNames` when two items share a name.
  public func receiveFiles(_ guestPaths: [String], from endpoint: GuestEndpoint, into directory: URL) async throws -> [URL] {
    guard !guestPaths.isEmpty else { return [] }
    try GuestTransferError.checkUniqueNames(guestPaths.map { GuestScripts.splitGuestPath($0).name })
    let guestArchive = stagingPath(endpoint, "\(UUID().uuidString).tgz")
    let data: Data
    do {
      _ = try await checked(
        endpoint, GuestScripts.createArchive(guestArchive, paths: guestPaths, os: endpoint.os),
        operation: "pack the guest files", timeout: .seconds(600))
      data = try await download(guestArchive, endpoint: endpoint)
    } catch {
      await removeGuest([guestArchive], endpoint)
      throw error
    }
    await removeGuest([guestArchive], endpoint)

    let archive = try temporaryHostFile(extension: "tgz")
    defer { try? FileManager.default.removeItem(at: archive) }
    try data.write(to: archive)
    let destination = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      return try await HostArchiver.extract(archive, into: destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  // MARK: Verified transfer

  /// Writes `data` to a guest file, verifying the result with SHA-256.
  public func upload(_ data: Data, to guestPath: String, endpoint: GuestEndpoint) async throws {
    let expected = Digest.sha256(data)
    let os = endpoint.os
    let small = data.count <= options.chunkSize
    let operation = "copy data into the guest"
    if small || options.allowsFastPath {
      let attempts = small ? options.maxRetries : 1
      for _ in 0..<attempts {
        let output = try await checked(
          endpoint, GuestScripts.writeFile(guestPath, os: os), input: data, operation: operation,
          timeout: timeout(for: data.count))
        if output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == expected { return }
      }
      if small { throw GuestTransportError.integrityCheckFailed("upload of \(data.count) bytes to \(guestPath)") }
    }

    chunkedTransferCount += 1
    _ = try await checked(endpoint, GuestScripts.truncateFile(guestPath, os: os), operation: operation, timeout: .seconds(15))
    for (index, chunk) in chunks(of: data).enumerated() {
      let chunkHash = Digest.sha256(chunk)
      var verified = false
      for _ in 0..<options.maxRetries {
        let output = try await checked(
          endpoint, GuestScripts.writeChunk(guestPath, index: index, chunkSize: options.chunkSize, os: os),
          input: chunk, operation: operation, timeout: .seconds(30))
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
    let operation = "copy data from the guest"
    if small || options.allowsFastPath {
      let attempts = small ? options.maxRetries : 1
      for _ in 0..<attempts {
        let output = try await checked(
          endpoint, GuestScripts.readFile(guestPath, os: os), operation: operation, timeout: timeout(for: info.size))
        if output.stdout.count == info.size, Digest.sha256(output.stdout) == info.sha256 { return output.stdout }
      }
      if small { throw GuestTransportError.integrityCheckFailed("download of \(guestPath)") }
    }

    chunkedTransferCount += 1
    let hashes = try await checked(
      endpoint, GuestScripts.chunkHashes(guestPath, chunkSize: options.chunkSize, os: os), operation: operation,
      timeout: timeout(for: info.size)
    ).stdoutString.split(whereSeparator: \.isNewline).map(String.init)
    var data = Data(capacity: info.size)
    for (index, expected) in hashes.enumerated() {
      var block: Data?
      for _ in 0..<options.maxRetries {
        let output = try await checked(
          endpoint, GuestScripts.readChunk(guestPath, index: index, chunkSize: options.chunkSize, os: os),
          operation: operation, timeout: .seconds(30))
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
      guestFiles = try await sendFiles(payload.files, to: endpoint, guestDirectory: try await newGuestStagingFolder(endpoint))
    }
    let body = try JSONEncoder().encode(
      MacOSWritePayload(
        items: payload.items.map { .init(type: $0.type, data: $0.data.base64EncodedString()) }, files: guestFiles))

    let command: [String]
    var input: Data?
    var staged: String?
    if body.count <= options.chunkSize {
      command = GuestScripts.macOSWrite(pasteboardName: options.guestPasteboardName)
      input = body
    } else {
      let path = stagingPath(endpoint, "\(UUID().uuidString).json")
      staged = path
      do {
        try await upload(body, to: path, endpoint: endpoint)
      } catch {
        await removeGuest([path], endpoint)
        throw error
      }
      command = GuestScripts.macOSWrite(pasteboardName: options.guestPasteboardName, payloadFile: path)
    }
    // One item for all flavours plus one per file; anything less means the guest dropped some.
    let expectedItems = (payload.items.isEmpty ? 0 : 1) + guestFiles.count
    var reply: MacOSWriteReply?
    for _ in 0..<2 {
      let output: CommandOutput
      do {
        output = try await checked(
          endpoint, command, input: input, operation: "set the guest clipboard", timeout: timeout(for: body.count))
      } catch {
        if let staged { await removeGuest([staged], endpoint) }
        throw error
      }
      let decoded = try decode(MacOSWriteReply.self, from: output.stdout)
      reply = decoded
      // Older scripts don't report the count; trust them as before.
      if (decoded.itemCount ?? expectedItems) >= expectedItems || staged != nil { break }
    }
    guard let reply else { throw GuestTransportError.unexpectedOutput("The guest didn't confirm the clipboard write.") }
    if let count = reply.itemCount, count < expectedItems {
      throw GuestTransportError.unexpectedOutput(
        "The guest clipboard kept \(count) of \(expectedItems) items after the copy.")
    }
    return GuestClipboardState(changeCount: reply.changeCount, fingerprint: payload.fingerprint)
  }

  private func pullFromMacOS(_ endpoint: GuestEndpoint, maxBytes: Int?, includeFiles: Bool) async throws -> ClipboardPayload? {
    let output = try await checked(
      endpoint,
      GuestScripts.macOSRead(
        pasteboardName: options.guestPasteboardName, stagingDirectory: stagingRoot(endpoint),
        inlineLimit: options.inlineLimit),
      operation: "read the guest clipboard", timeout: .seconds(60))
    let manifest = try decode(GuestManifest.self, from: output.stdout)
    // A writer in the guest hasn't handed every file item over yet; don't read a partial copy.
    if manifest.incomplete { throw GuestTransferError.incomplete }

    if !manifest.files.isEmpty {
      guard includeFiles else { return nil }
      let paths = manifest.files.compactMap(\.path)
      let total = manifest.files.reduce(0) { $0 + ($1.size ?? 0) }
      if let maxBytes, total > maxBytes { throw GuestTransportError.tooLarge(bytes: total, limit: maxBytes) }
      pruneHostStaging(keeping: options.stagingFoldersToKeep - 1)
      let local = try await receiveFiles(paths, from: endpoint, into: fileStagingDirectory)
      return ClipboardPayload(files: ordered(local, like: paths))
    }

    var entries = manifest.items
    if let staged = manifest.staged {
      do {
        // Base64 inflates by 4/3; compare the decoded size with the limit.
        if let maxBytes, staged.size * 3 / 4 > maxBytes {
          throw GuestTransportError.tooLarge(bytes: staged.size * 3 / 4, limit: maxBytes)
        }
        let data = try await download(staged.path, endpoint: endpoint)
        await removeGuest([staged.path], endpoint)
        entries = try decode(StagedItems.self, from: data).items
      } catch {
        await removeGuest([staged.path], endpoint)
        throw error
      }
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

  /// Linux clipboard tools serve one flavour per selection owner, so the richest flavour that
  /// carries the content (files, then plain text, then PNG, then HTML) is pushed. The returned
  /// state fingerprints that projection, which lets the sync session recognise it when it comes
  /// back instead of downgrading the host's richer clipboard.
  private func pushToLinux(_ payload: ClipboardPayload, endpoint: GuestEndpoint) async throws -> GuestClipboardState {
    let mime: String
    let data: Data
    let projection: String
    if !payload.files.isEmpty {
      let folder = try await newGuestStagingFolder(endpoint)
      let paths = try await sendFiles(payload.files, to: endpoint, guestDirectory: folder)
      mime = "text/uri-list"
      data = Data(paths.map { URL(fileURLWithPath: $0).absoluteString }.joined(separator: "\r\n").utf8)
      projection = payload.fingerprint
    } else if let flavour = Self.linuxProjection(of: payload) {
      (mime, data) = (flavour.mime, flavour.representation.data)
      projection = ClipboardPayload(items: [flavour.representation]).fingerprint
    } else {
      throw GuestTransportError.unsupported("Linux guests accept text, HTML, PNG images and files.")
    }
    let staged = stagingPath(endpoint, "\(UUID().uuidString).bin")
    do {
      try await upload(data, to: staged, endpoint: endpoint)
      let output = try await checked(
        endpoint, GuestScripts.linuxWrite(mime: mime, stagedFile: staged), operation: "set the guest clipboard",
        timeout: .seconds(30))
      let reply = try decode(ChangeCountReply.self, from: output.stdout)
      return GuestClipboardState(changeCount: reply.changeCount, fingerprint: projection)
    } catch {
      await removeGuest([staged], endpoint)
      throw error
    }
  }

  /// The single flavour a Linux guest receives for a non-file payload.
  static func linuxProjection(of payload: ClipboardPayload) -> (mime: String, representation: ClipboardRepresentation)? {
    for (type, mime) in [
      (ClipboardRepresentation.plainText, "text/plain"), (ClipboardRepresentation.png, "image/png"),
      (ClipboardRepresentation.html, "text/html"),
    ] {
      if let data = payload.data(for: type) { return (mime, ClipboardRepresentation(type: type, data: data)) }
    }
    return nil
  }

  private func pullFromLinux(_ endpoint: GuestEndpoint, maxBytes: Int?, includeFiles: Bool) async throws -> ClipboardPayload? {
    let output = try await checked(
      endpoint, GuestScripts.linuxRead(stagingDirectory: stagingRoot(endpoint)), operation: "read the guest clipboard",
      timeout: .seconds(30))
    let manifest = try decode(GuestManifest.self, from: output.stdout)
    let stagedPaths = manifest.items.compactMap(\.path)
    do {
      let payload = try await readLinuxManifest(manifest, endpoint: endpoint, maxBytes: maxBytes, includeFiles: includeFiles)
      await removeGuest(stagedPaths, endpoint)
      return payload
    } catch {
      await removeGuest(stagedPaths, endpoint)
      throw error
    }
  }

  private func readLinuxManifest(
    _ manifest: GuestManifest, endpoint: GuestEndpoint, maxBytes: Int?, includeFiles: Bool
  ) async throws -> ClipboardPayload? {
    let filePaths = manifest.files.compactMap { $0.uri.flatMap(URL.init(string:))?.path ?? $0.path }
    if !filePaths.isEmpty {
      guard includeFiles else { return nil }
      if let maxBytes {
        // Measure in the guest first, so nothing is copied when the files are over the limit.
        let sizes = try await checked(
          endpoint, GuestScripts.pathSizes(filePaths, os: endpoint.os), operation: "measure the guest files",
          timeout: .seconds(60))
        let reported = sizes.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fail closed: an unknown size must never slip past the limit.
        guard let total = Int(reported), total >= 0 else {
          throw GuestTransportError.unexpectedOutput("file sizes: \(reported.prefix(80))")
        }
        if total > maxBytes { throw GuestTransportError.tooLarge(bytes: total, limit: maxBytes) }
      }
      pruneHostStaging(keeping: options.stagingFoldersToKeep - 1)
      let local = try await receiveFiles(filePaths, from: endpoint, into: fileStagingDirectory)
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

  // MARK: Staging

  /// A new, unique guest staging folder, after pruning the oldest ones.
  private func newGuestStagingFolder(_ endpoint: GuestEndpoint) async throws -> String {
    _ = try? await endpoint.transport.run(
      GuestScripts.pruneStaging(stagingRoot(endpoint), keep: options.stagingFoldersToKeep - 1, os: endpoint.os),
      standardInput: nil, timeout: .seconds(15))
    return stagingPath(endpoint, UUID().uuidString)
  }

  /// Keeps the `keep` newest per-transfer folders in `fileStagingDirectory` (UUID-named only).
  private func pruneHostStaging(keeping keep: Int) {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey]
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: fileStagingDirectory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    else { return }
    let folders = entries.compactMap { url -> (url: URL, created: Date)? in
      guard UUID(uuidString: url.lastPathComponent) != nil,
        let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true
      else { return nil }
      return (url, values.creationDate ?? .distantPast)
    }
    for folder in folders.sorted(by: { $0.created > $1.created }).dropFirst(max(0, keep)) {
      try? FileManager.default.removeItem(at: folder.url)
    }
  }

  /// Best-effort removal of guest temporaries.
  private func removeGuest(_ paths: [String], _ endpoint: GuestEndpoint) async {
    guard !paths.isEmpty else { return }
    _ = try? await endpoint.transport.run(GuestScripts.remove(paths, os: endpoint.os), standardInput: nil, timeout: .seconds(15))
  }

  // MARK: Helpers

  private func fileInfo(_ path: String, endpoint: GuestEndpoint) async throws -> (size: Int, sha256: String) {
    let output = try await checked(
      endpoint, GuestScripts.fileInfo(path, os: endpoint.os), operation: "check a guest file", timeout: .seconds(120))
    let fields = output.stdoutString.split(whereSeparator: \.isWhitespace)
    guard fields.count == 2, let size = Int(fields[0]) else {
      throw GuestTransportError.unexpectedOutput(output.stdoutString)
    }
    return (size, String(fields[1]))
  }

  /// Runs a guest command and throws unless it exits successfully.
  ///
  /// - Parameter operation: What the command does, for error messages ("Couldn't <operation>: …").
  private func checked(
    _ endpoint: GuestEndpoint, _ command: [String], input: Data? = nil, operation: String, timeout: Duration
  ) async throws -> CommandOutput {
    let output = try await endpoint.transport.run(command, standardInput: input, timeout: timeout)
    guard output.succeeded else {
      if endpoint.os == .linux, output.status == GuestScripts.linuxUnsupportedStatus {
        throw GuestTransportError.unsupported(output.diagnostic)
      }
      // Failures printed by `tart exec` / `ssh` themselves: the command never reached the guest.
      if let reason = GuestProbe.transportReason(for: output.diagnostic) {
        throw GuestTransportError.unreachable(reason)
      }
      if endpoint.transport is SSHTransport, output.status == 255,
        let reason = GuestProbe.sshReason(for: output.diagnostic)
      {
        throw GuestTransportError.unreachable(reason)
      }
      throw GuestTransportError.commandFailed(
        status: output.status,
        message: GuestProbe.commandReason(
          for: output.diagnostic, status: output.status, operation: operation,
          isSSH: endpoint.transport is SSHTransport))
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
    let order = Dictionary(guestPaths.enumerated().map { (GuestScripts.splitGuestPath($1).name, $0) }) { first, _ in first }
    return local.sorted { (order[$0.lastPathComponent] ?? .max) < (order[$1.lastPathComponent] ?? .max) }
  }
}

// MARK: Wire formats

struct ChangeCountReply: Decodable {
  var changeCount: Int
}

/// Reply of `GuestScripts.macOSWrite`: the new change count and how many items the pasteboard
/// server actually holds after the write.
struct MacOSWriteReply: Decodable {
  var changeCount: Int
  var itemCount: Int?
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
  /// Some file item didn't resolve in the guest (macOS only).
  var incomplete: Bool

  enum CodingKeys: String, CodingKey { case changeCount, items, files, staged, incomplete }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    changeCount = try container.decode(Int.self, forKey: .changeCount)
    items = try container.decodeIfPresent([Entry].self, forKey: .items) ?? []
    files = try container.decodeIfPresent([FileEntry].self, forKey: .files) ?? []
    staged = try container.decodeIfPresent(Staged.self, forKey: .staged)
    incomplete = try container.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false
  }
}

struct StagedItems: Decodable {
  var items: [GuestManifest.Entry]
}
