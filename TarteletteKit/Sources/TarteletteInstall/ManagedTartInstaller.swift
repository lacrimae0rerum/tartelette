import CryptoKit
import Darwin
import Foundation
import TarteletteCLI
import TarteletteCore

/// Where an installation is, for a progress bar.
public struct TartInstallProgress: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    /// Downloading the release archive.
    case downloading
    /// Checking the archive's checksum, unpacking it and checking `tart.app`'s signature.
    case verifying
    /// Moving the verified version into place and selecting it.
    case installing
  }

  public var phase: Phase
  /// Bytes of the archive received so far.
  public var bytesReceived: Int64
  /// The archive's size as the release announces it.
  public var bytesExpected: Int64

  public init(phase: Phase, bytesReceived: Int64, bytesExpected: Int64) {
    self.phase = phase
    self.bytesReceived = bytesReceived
    self.bytesExpected = bytesExpected
  }
}

/// The versions of Tart that Tartelette manages.
public struct ManagedTartState: Sendable, Equatable {
  /// The active version, which `current` selects.
  public var current: String?
  /// The version that was active before `current`, when it is still installed.
  public var previous: String?
  /// Every installed version, oldest first.
  public var installed: [String]

  public init(current: String? = nil, previous: String? = nil, installed: [String] = []) {
    self.current = current
    self.previous = previous
    self.installed = installed
  }
}

/// Installs, switches and removes the copy of Tart that Tartelette manages, in a `ManagedTartLayout`.
///
/// Every operation either completes or leaves `versions/`, `current` and the manifest exactly as they
/// were, and empties its scratch space in `staging/`. Only one process changes the layout at a time;
/// another one gets `TartInstallError.busy`.
public struct ManagedTartInstaller: Sendable {
  public let layout: ManagedTartLayout
  private let downloader: any TartDownloading
  private let verifier: any TartSignatureVerifying
  private let runningExecutables: any RunningExecutablesProviding
  private let processRunner: any ProcessRunning

  public init(
    layout: ManagedTartLayout = .standard,
    downloader: any TartDownloading = URLSessionTartDownloader(),
    verifier: any TartSignatureVerifying = CodeSignatureVerifier(),
    runningExecutables: any RunningExecutablesProviding = ProcessListRunningExecutables(),
    processRunner: any ProcessRunning = ProcessRunner()
  ) {
    self.layout = layout
    self.downloader = downloader
    self.verifier = verifier
    self.runningExecutables = runningExecutables
    self.processRunner = processRunner
  }

  /// The installed versions, the active one and the one `rollback()` would select. Reads the disk only.
  public func state() -> ManagedTartState {
    let installed = installedVersions()
    let current = layout.currentVersion.flatMap { installed.contains($0) ? $0 : nil }
    let previous = readManifest().previousVersion.flatMap { installed.contains($0) && $0 != current ? $0 : nil }
    return ManagedTartState(current: current, previous: previous, installed: installed)
  }

  // MARK: - Install

  /// Downloads `release`, verifies it and makes it the active version, keeping the one it replaces
  /// for `rollback()`. Versions other than those two are then pruned when no process runs them.
  ///
  /// The archive's SHA-256 must match the release's checksums file, it must hold a `tart.app` folder,
  /// and `tart.app` must pass the signature check and report the release's version. Only `tart.app`
  /// and the archive's LICENSE (when it is a regular file) are installed; anything else is ignored.
  /// A version that is already installed and still passes those checks is selected without
  /// downloading anything. One that doesn't (its folder lacks `tart.app`, or the signature or version
  /// check fails) is downloaded again and replaced, unless a running process uses it.
  ///
  /// - Throws: `TartInstallError`, `TartReleaseError` for a damaged checksums file, or
  ///   `CancellationError`. Nothing changes on failure.
  @discardableResult
  public func install(
    _ release: TartRelease, progress: @escaping @Sendable (TartInstallProgress) -> Void = { _ in }
  ) async throws -> ManagedTartState {
    sweepRemovedCopies()
    return try await exclusively {
      try cleanStaging()
      let version = release.version.description
      let expected = release.archive.size

      if Self.itemExists(layout.versionDirectory(version)) {
        if isIntact(version, as: release.version) {
          if layout.currentVersion != version {
            progress(TartInstallProgress(phase: .installing, bytesReceived: 0, bytesExpected: expected))
            try select(version)
            _ = try? pruneUnusedVersions()
          }
          return state()
        }
        // A broken copy is downloaded again and replaced, but never under a running process.
        try refuseIfRunning(version)
      }

      let work = try makeWorkDirectory()
      defer { try? FileManager.default.removeItem(at: work) }

      let checksumsFile = work.appendingPathComponent("checksums.txt")
      try await downloader.download(
        from: release.checksums.downloadURL, to: checksumsFile, limit: Self.downloadLimit(release.checksums.size),
        progress: { _ in })
      let checksums = try TartChecksums(parsing: String(decoding: try Data(contentsOf: checksumsFile), as: UTF8.self))
      let expectedSHA256 = try checksums.expectedSHA256(for: release.archive.name)

      let archive = work.appendingPathComponent("tart.tar.gz")
      progress(TartInstallProgress(phase: .downloading, bytesReceived: 0, bytesExpected: expected))
      try await downloader.download(
        from: release.archive.downloadURL, to: archive, limit: Self.downloadLimit(expected),
        progress: { progress(TartInstallProgress(phase: .downloading, bytesReceived: $0, bytesExpected: expected)) })

      progress(TartInstallProgress(phase: .verifying, bytesReceived: expected, bytesExpected: expected))
      guard try Self.sha256(of: archive) == expectedSHA256 else {
        throw TartInstallError.checksumMismatch(fileName: release.archive.name)
      }
      let payload = try await extract(archive, in: work)
      try Task.checkCancellation()
      try verifyBundle(at: payload.appendingPathComponent("tart.app"), is: release.version)

      progress(TartInstallProgress(phase: .installing, bytesReceived: expected, bytesExpected: expected))
      try Task.checkCancellation()
      try place(payload, as: version, setAsideIn: work)
      _ = try? pruneUnusedVersions()
      return state()
    }
  }

  /// A quarter and 1 MiB more than the announced size, so a download that grows far beyond it stops.
  /// Saturates at `Int64.max` instead of overflowing; a negative size counts as zero.
  static func downloadLimit(_ announcedSize: Int64) -> Int64 {
    let size = max(0, announcedSize)
    let (withMargin, overflowed) = size.addingReportingOverflow(size / 4)
    let (limit, overflowedAgain) = withMargin.addingReportingOverflow(1_048_576)
    return overflowed || overflowedAgain ? .max : limit
  }

  static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Unpacks `archive` with `/usr/bin/tar` into `work` and returns a new folder in `work` holding
  /// what gets installed: the archive's `tart.app`, which must be a real folder, and its LICENSE when
  /// that is a regular file. Other top-level entries stay behind and are deleted with `work`. tar
  /// refuses absolute paths, `..` and writing through links by default.
  private func extract(_ archive: URL, in work: URL) async throws -> URL {
    let directory = work.appendingPathComponent("unpacked", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let output: CommandOutput
    do {
      output = try await processRunner.run(
        ProcessRequest(
          executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", directory.path],
          timeout: .seconds(300)))
    } catch ProcessRunError.cancelled {
      throw CancellationError()
    } catch {
      throw TartInstallError.extractionFailed(reason: error.localizedDescription)
    }
    guard output.succeeded else {
      if output.diagnostic.contains("No space left on device") { throw TartInstallError.diskFull }
      throw TartInstallError.extractionFailed(reason: output.diagnostic)
    }

    let app = directory.appendingPathComponent("tart.app")
    guard (try? Self.fileType(app)) == .typeDirectory else {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      throw TartInstallError.unexpectedArchive(
        reason: "It has no tart.app folder; it contains: \(entries.sorted().joined(separator: ", ")).")
    }
    let payload = work.appendingPathComponent("payload", isDirectory: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
    try Self.rename(app, to: payload.appendingPathComponent("tart.app"), replacing: false)
    let license = directory.appendingPathComponent("LICENSE")
    if (try? Self.fileType(license)) == .typeRegular {
      try Self.rename(license, to: payload.appendingPathComponent("LICENSE"), replacing: false)
    }
    return payload
  }

  /// The type of the item at `url` itself, without following a symbolic link.
  private static func fileType(_ url: URL) throws -> FileAttributeType? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
  }

  /// The signature check, then the version `tart.app` reports (read after the check, from the
  /// sealed Info.plist).
  private func verifyBundle(at app: URL, is version: TartVersion) throws {
    guard try Self.fileType(app) == .typeDirectory else {
      throw TartInstallError.unexpectedArchive(reason: "tart.app isn't a folder.")
    }
    try verifier.verify(appAt: app)
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    let found = info?["CFBundleShortVersionString"] as? String
    guard let found, TartVersion(found) == version else {
      throw TartInstallError.versionMismatch(expected: version.description, found: found ?? "unknown")
    }
  }

  /// Moves the verified version into `versions/` and selects it, undoing everything if a step fails.
  ///
  /// A broken folder already at `versions/<version>` is first moved into `work`, which is deleted
  /// afterwards, and put back on failure.
  private func place(_ payload: URL, as version: String, setAsideIn work: URL) throws {
    let fileManager = FileManager.default
    let versions = layout.versionsDirectory
    let createdVersions = !Self.itemExists(versions)
    if createdVersions {
      try fileManager.createDirectory(at: versions, withIntermediateDirectories: false)
    } else if try Self.fileType(versions) != .typeDirectory {
      throw TartInstallError.fileSystem(reason: "\(versions.path) isn't a folder.")
    }
    let destination = layout.versionDirectory(version)
    var replaced: URL?
    func undo() {
      if let replaced { try? Self.rename(replaced, to: destination, replacing: false) }
      if createdVersions { try? fileManager.removeItem(at: versions) }
    }

    do {
      if Self.itemExists(destination) {
        try refuseIfRunning(version)
        let aside = work.appendingPathComponent("replaced", isDirectory: true)
        try Self.rename(destination, to: aside, replacing: false)
        replaced = aside
      }
      try Self.rename(payload, to: destination, replacing: false)
    } catch {
      undo()
      throw error
    }
    do {
      try select(version)
    } catch {
      try? Self.rename(destination, to: payload, replacing: false)
      undo()
      throw error
    }
  }

  /// Whether `versions/<version>` holds a `tart.app` that passes the signature and version checks.
  private func isIntact(_ version: String, as expected: TartVersion) -> Bool {
    guard isInstalled(version) else { return false }
    let app = layout.versionDirectory(version).appendingPathComponent("tart.app")
    return (try? verifyBundle(at: app, is: expected)) != nil
  }

  /// Throws `TartInstallError.inUse` when a running process executes `version`.
  private func refuseIfRunning(_ version: String) throws {
    if isRunning(version, among: try runningExecutables.runningExecutablePaths()) {
      throw TartInstallError.inUse(versions: [version])
    }
  }

  /// Whether anything, even a broken link, is at `url`.
  private static func itemExists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  // MARK: - Switch

  /// Points `current` at `versions/<version>` and records the version it pointed at before.
  ///
  /// The manifest is written first, so a crash between the two steps leaves a manifest naming the
  /// still-current version, which is harmless. If switching fails the manifest is restored.
  private func select(_ version: String) throws {
    let fileManager = FileManager.default
    let manifestBefore = try? Data(contentsOf: layout.manifestFile)
    if let leaving = layout.currentVersion, leaving != version {
      try writeManifest(Manifest(previousVersion: leaving))
    }
    do {
      // A new relative link renamed over `current`: atomic, and running processes keep their binary.
      // It is made in `staging/`, so a crash before the rename leaves nothing outside scratch space.
      let link = try prepareStaging().appendingPathComponent("current-\(UUID().uuidString)")
      try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "versions/\(version)")
      do {
        try Self.rename(link, to: layout.currentLink, replacing: true)
      } catch {
        try? fileManager.removeItem(at: link)
        throw error
      }
    } catch {
      if let manifestBefore {
        try? manifestBefore.write(to: layout.manifestFile, options: .atomic)
      } else {
        try? fileManager.removeItem(at: layout.manifestFile)
      }
      throw error
    }
  }

  /// Selects the version that was active before the current one, and remembers the current one so
  /// a second rollback returns to it.
  ///
  /// - Throws: `TartInstallError.noPreviousVersion` when there is none. Nothing changes on failure.
  @discardableResult
  public func rollback() async throws -> ManagedTartState {
    sweepRemovedCopies()
    guard FileManager.default.fileExists(atPath: layout.root.path) else { throw TartInstallError.noPreviousVersion }
    return try await exclusively {
      guard let previous = state().previous, let version = TartVersion(previous) else {
        throw TartInstallError.noPreviousVersion
      }
      try verifyBundle(at: layout.versionDirectory(previous).appendingPathComponent("tart.app"), is: version)
      try select(previous)
      return state()
    }
  }

  // MARK: - Prune and remove

  /// Removes installed versions other than the current and the previous one, except those a running
  /// process executes. Returns the versions removed.
  ///
  /// - Throws: `TartInstallError.runningProcessesUnknown`, removing nothing, when the running
  ///   processes can't be listed.
  @discardableResult
  public func prune() async throws -> [String] {
    sweepRemovedCopies()
    guard FileManager.default.fileExists(atPath: layout.root.path) else { return [] }
    return try await exclusively { try pruneUnusedVersions() }
  }

  private func pruneUnusedVersions() throws -> [String] {
    let state = state()
    let keep = Set([state.current, state.previous].compactMap { $0 })
    let running = try runningExecutables.runningExecutablePaths()
    let unused = state.installed.filter { !keep.contains($0) && !isRunning($0, among: running) }
    guard !unused.isEmpty else { return [] }

    // Move every version out of `versions/` first, putting them all back if one can't be moved.
    let trash = try makeWorkDirectory()
    defer { try? FileManager.default.removeItem(at: trash) }
    var moved: [String] = []
    do {
      for version in unused {
        try Self.rename(layout.versionDirectory(version), to: trash.appendingPathComponent(version), replacing: false)
        moved.append(version)
      }
    } catch {
      for version in moved {
        try? Self.rename(trash.appendingPathComponent(version), to: layout.versionDirectory(version), replacing: false)
      }
      throw error
    }
    return moved
  }

  /// Deletes the managed copy: every version, `current`, the manifest and the scratch space.
  ///
  /// One rename takes the whole copy out of use, as a hidden `.<root>-removing-<id>` folder next to
  /// the root, and then that folder is deleted. If it can't be deleted completely, `remove()` still
  /// succeeds and the next operation deletes what is left, unless a process started running from it
  /// in the meantime: then it throws `TartInstallError.inUse`.
  ///
  /// - Throws: `TartInstallError.inUse` while a running process executes any installed version, and
  ///   `TartInstallError.runningProcessesUnknown` when the processes can't be listed. Before the
  ///   rename, nothing changes on failure.
  public func remove() async throws {
    sweepRemovedCopies()
    guard FileManager.default.fileExists(atPath: layout.root.path) else { return }
    try await exclusively {
      let running = try runningExecutables.runningExecutablePaths()
      let installed = installedVersions()
      let inUse = installed.filter { isRunning($0, among: running) }
      guard inUse.isEmpty else { throw TartInstallError.inUse(versions: inUse) }

      let trash = layout.root.deletingLastPathComponent()
        .appendingPathComponent("\(removedCopyPrefix)\(UUID().uuidString)", isDirectory: true)
      try Self.rename(layout.root, to: trash, replacing: false)
      do {
        try FileManager.default.removeItem(at: trash)
      } catch {
        let running = try runningExecutables.runningExecutablePaths()
        let stillInUse = installed.filter {
          isRunning(inside: trash.appendingPathComponent("versions/\($0)"), among: running)
        }
        guard stillInUse.isEmpty else { throw TartInstallError.inUse(versions: stillInUse) }
      }
    }
  }

  /// The start of the name `remove()` gives the managed copy while deleting it.
  private var removedCopyPrefix: String { ".\(layout.root.lastPathComponent)-removing-" }

  /// Deletes copies an earlier `remove()` set aside but couldn't delete completely, except those a
  /// running process executes from. Best effort: it never fails the operation that runs it.
  private func sweepRemovedCopies() {
    let parent = layout.root.deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    let leftovers = names.filter { $0.hasPrefix(removedCopyPrefix) }
    guard !leftovers.isEmpty, let running = try? runningExecutables.runningExecutablePaths() else { return }
    for name in leftovers {
      let leftover = parent.appendingPathComponent(name, isDirectory: true)
      guard !isRunning(inside: leftover, among: running) else { continue }
      // `removeItem` deletes a link itself, and a folder's contents without following links.
      try? FileManager.default.removeItem(at: leftover)
    }
  }

  // MARK: - Layout

  /// Installed versions, oldest first: real folders in `versions/` that hold a `tart.app`. Nothing is
  /// installed when `versions` itself is a link, so no operation acts through it.
  private func installedVersions() -> [String] {
    guard (try? Self.fileType(layout.versionsDirectory)) == .typeDirectory else { return [] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.versionsDirectory.path)) ?? []
    return names.filter(isInstalled).sorted { lhs, rhs in
      switch (TartVersion(lhs), TartVersion(rhs)) {
      case let (left?, right?) where left != right: left < right
      default: lhs < rhs
      }
    }
  }

  private func isInstalled(_ version: String) -> Bool {
    guard !version.hasPrefix("."), (try? Self.fileType(layout.versionsDirectory)) == .typeDirectory else {
      return false
    }
    let directory = layout.versionDirectory(version)
    return (try? Self.fileType(directory)) == .typeDirectory
      && (try? Self.fileType(directory.appendingPathComponent("tart.app"))) == .typeDirectory
  }

  /// Whether one of `running` is inside `versions/<version>/`.
  private func isRunning(_ version: String, among running: [String]) -> Bool {
    isRunning(inside: layout.versionDirectory(version), among: running)
  }

  /// Whether one of `running` is inside `folder`, as spelled here or with every symbolic link
  /// resolved (the kernel reports `/private/var/…` for `/var/…`).
  private func isRunning(inside folder: URL, among running: [String]) -> Bool {
    let directory = folder.path
    let resolved = realpath(directory, nil).map { pointer in
      defer { free(pointer) }
      return String(cString: pointer)
    }
    let prefixes = Set([directory, resolved].compactMap { $0 }.map { $0 + "/" })
    return running.contains { path in prefixes.contains { path.hasPrefix($0) } }
  }

  /// A new, empty folder in `staging/`, on the same volume as `versions/` so moves are renames.
  private func makeWorkDirectory() throws -> URL {
    let directory = try prepareStaging().appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  /// Makes `staging/` a real folder and returns it. A link or file in its place is removed itself,
  /// never what a link points to.
  private func prepareStaging() throws -> URL {
    let staging = layout.stagingDirectory
    switch try? Self.fileType(staging) {
    case .typeDirectory?:
      return staging
    case nil:
      break
    default:
      guard unlink(staging.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    return staging
  }

  /// Deletes whatever an interrupted operation left in `staging/`, without following links. Safe
  /// under the lock: no other operation is running.
  private func cleanStaging() throws {
    let staging = try prepareStaging()
    for item in try FileManager.default.contentsOfDirectory(atPath: staging.path) {
      // `removeItem` deletes a link itself, and a folder's contents without following links.
      try FileManager.default.removeItem(at: staging.appendingPathComponent(item))
    }
  }

  /// `rename(2)`: atomic on one volume. Without `replacing`, fails rather than replace what's there.
  private static func rename(_ source: URL, to destination: URL, replacing: Bool) throws {
    let result =
      replacing
      ? Darwin.rename(source.path, destination.path)
      : renamex_np(source.path, destination.path, UInt32(RENAME_EXCL))
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  // MARK: - Manifest

  /// What the installer remembers between operations.
  struct Manifest: Codable, Equatable {
    /// The version that was active before the current one.
    var previousVersion: String?
  }

  private func readManifest() -> Manifest {
    guard let data = try? Data(contentsOf: layout.manifestFile),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
    else { return Manifest() }
    return manifest
  }

  private func writeManifest(_ manifest: Manifest) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    // Written to a temporary file and renamed into place.
    try encoder.encode(manifest).write(to: layout.manifestFile, options: .atomic)
  }

  // MARK: - Exclusion and errors

  /// Runs `body` while holding the layout's lock, mapping every failure to an actionable error.
  /// Another process holding the lock makes it throw `TartInstallError.busy` at once.
  private func exclusively<T>(_ body: () async throws -> T) async throws -> T {
    let descriptor: Int32
    do {
      try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
      // Never through a link: a `.lock` link fails with ELOOP instead of creating its target.
      descriptor = open(layout.lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
      guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } catch {
      throw TartInstallError.fileSystem(error)
    }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { throw TartInstallError.busy }
      throw TartInstallError.fileSystem(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
    }
    defer { flock(descriptor, LOCK_UN) }

    do {
      return try await body()
    } catch let error as TartInstallError {
      throw error
    } catch let error as TartReleaseError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TartInstallError.fileSystem(error)
    }
  }
}
