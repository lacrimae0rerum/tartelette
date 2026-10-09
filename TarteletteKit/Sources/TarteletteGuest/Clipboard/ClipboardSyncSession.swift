import AppKit
import Foundation
import TarteletteCore

public enum ClipboardSyncEvent: Sendable, Equatable {
  case sentToGuest(summary: String, date: Date)
  case receivedFromGuest(summary: String, date: Date)
  case skipped(reason: String)
  case failed(message: String)
  case guestStatus(GuestAgentStatus)
}

/// Keeps the host clipboard and one guest's clipboard in sync.
///
/// Loop prevention: the session remembers the fingerprint of the last payload it moved (in either
/// direction), the fingerprint of what the guest holds after a push (a projection on Linux guests)
/// and the change counts produced by its own writes on both sides. A change is only propagated
/// when it was made by someone else and its contents differ from what was last synced, so a
/// payload never bounces back.
///
/// Settling: writers clear a pasteboard (bumping its change count) and then add items (which
/// doesn't bump it), so a read can land on a half-written pasteboard. A host change is acted on
/// only once two polls agree on both its change count and its contents (an empty pasteboard never
/// counts as settled), and for a short window afterwards contents that change under the same count
/// are treated as a new change. A guest change is pulled only once its change count stops moving.
///
/// Transfers are serialised: manual sends and fetches queue behind an in-flight transfer, and
/// polls skip while any transfer is active. Changes are only marked as handled once they were
/// moved, deliberately skipped or failed permanently, so changes made while the other side is
/// unreachable are moved when it comes back.
@MainActor
public final class ClipboardSyncSession {
  public enum Direction: String, Sendable, CaseIterable {
    case bidirectional
    case hostToGuest
    case guestToHost

    var sendsToGuest: Bool { self != .guestToHost }
    var receivesFromGuest: Bool { self != .hostToGuest }
  }

  public struct Configuration: Sendable {
    public var direction: Direction
    public var hostPollInterval: Duration
    public var guestPollInterval: Duration
    /// Larger payloads are skipped by automatic sync (a `.skipped` event is emitted).
    public var maxAutomaticTransferBytes: Int
    public var includeFiles: Bool
    /// Upper bound of the guest poll back-off while the guest is unreachable.
    public var maximumBackoff: Duration
    /// After the guest change count moves, wait this long and re-read it before pulling, until it
    /// stops moving (a guest app may still be writing). Zero pulls immediately.
    public var guestSettleDelay: Duration
    /// How long after acting on a host change its contents keep being compared, to catch items a
    /// writer adds late (without bumping the change count).
    public var hostLateWriteWindow: Duration
    /// How long after a sync a reduced copy of the synced files (a system component republishing
    /// the clipboard without some of them, e.g. hidden files) counts as an echo rather than a copy.
    public var degradedEchoWindow: Duration

    public init(
      direction: Direction = .bidirectional,
      hostPollInterval: Duration = .milliseconds(500),
      guestPollInterval: Duration = .milliseconds(1500),
      maxAutomaticTransferBytes: Int = 50 * 1024 * 1024,
      includeFiles: Bool = true,
      maximumBackoff: Duration = .seconds(15),
      guestSettleDelay: Duration = .milliseconds(300),
      hostLateWriteWindow: Duration = .seconds(1),
      degradedEchoWindow: Duration = .seconds(10)
    ) {
      self.direction = direction
      self.hostPollInterval = hostPollInterval
      self.guestPollInterval = guestPollInterval
      self.maxAutomaticTransferBytes = maxAutomaticTransferBytes
      self.includeFiles = includeFiles
      self.maximumBackoff = maximumBackoff
      self.guestSettleDelay = guestSettleDelay
      self.hostLateWriteWindow = hostLateWriteWindow
      self.degradedEchoWindow = degradedEchoWindow
    }
  }

  /// Whether a failed transfer is worth retrying.
  enum FailureKind: Sendable, Equatable {
    /// The guest couldn't be reached (agent missing, VM stopped, timeout); retry once it is back.
    case transient
    /// The guest was reached and refused or failed deterministically (permission denied, disk
    /// full, unexpected output, unsupported, too large…); retrying the same payload won't help.
    case permanent
  }

  nonisolated static func failureKind(of error: any Error) -> FailureKind {
    switch error {
    case GuestTransportError.unreachable, ProcessRunError.timedOut, ProcessRunError.launchFailed,
      ProcessRunError.cancelled, is CancellationError:
      .transient
    default:
      .permanent
    }
  }

  /// One observation of the host pasteboard.
  struct HostObservation: Equatable {
    var changeCount: Int
    var shape: String
  }

  public let endpoint: GuestEndpoint
  public let configuration: Configuration
  public let events: AsyncStream<ClipboardSyncEvent>
  public private(set) var isRunning = false
  public private(set) var guestStatus: GuestAgentStatus = .unknown

  private let bridge: ClipboardBridge
  private let hostPasteboard: NSPasteboard
  private let continuation: AsyncStream<ClipboardSyncEvent>.Continuation
  private var hostTask: Task<Void, Never>?
  private var guestTask: Task<Void, Never>?

  private var lastSyncedFingerprint: String?
  /// What the guest holds after our last push (differs from the payload on Linux guests).
  private var lastPushedGuestFingerprint: String?
  /// The host state last acted on (or adopted at start, or produced by our own write).
  private var handledHost: HostObservation?
  /// A host state seen once; acted on when the next poll sees exactly the same state.
  private var pendingHost: HostObservation?
  /// Until when contents under the handled change count are still compared (late writes).
  private var hostLateWriteDeadline: ContinuousClock.Instant?
  private var knownGuestChangeCount: Int?
  /// Name and size of the files moved by the last sync (either direction), and when.
  private var lastSyncedFiles: Set<FileIdentity> = []
  private var lastSyncedFilesAt: ContinuousClock.Instant?
  /// Transfers running or queued; polls skip while it is non-zero.
  private(set) var activeTransfers = 0
  private var transferQueue: Task<Void, Never>?
  /// Consecutive failed guest checks or clipboard reads; drives the poll back-off.
  private(set) var consecutiveGuestFailures = 0
  /// The guest has no usable clipboard (e.g. no clipboard tool); re-checked at the maximum back-off.
  private(set) var guestClipboardUnsupported = false
  private var lastSkippedFingerprint: String?
  /// The last payload the guest refused permanently; it is reported once and not retried.
  private var lastRejectedFingerprint: String?

  /// How many times the guest change count is re-read while it keeps moving.
  private static let maximumSettleRounds = 10

  public init(
    endpoint: GuestEndpoint,
    bridge: ClipboardBridge,
    configuration: Configuration = Configuration(),
    hostPasteboard: NSPasteboard = .general
  ) {
    self.endpoint = endpoint
    self.bridge = bridge
    self.configuration = configuration
    self.hostPasteboard = hostPasteboard
    (events, continuation) = AsyncStream.makeStream(of: ClipboardSyncEvent.self, bufferingPolicy: .bufferingNewest(100))
  }

  deinit {
    hostTask?.cancel()
    guestTask?.cancel()
    continuation.finish()
  }

  /// Starts syncing. Existing clipboard contents on either side are left alone; only later changes move.
  public func start() {
    guard !isRunning else { return }
    isRunning = true
    handledHost = currentHostObservation()
    pendingHost = nil
    hostLateWriteDeadline = nil

    // The loops hold `self` only for one iteration at a time, so a forgotten session still deallocates.
    guestTask = Task { [weak self] in
      await self?.checkGuest()
      while !Task.isCancelled {
        guard let delay = self?.guestDelay else { break }
        try? await Task.sleep(for: delay)
        guard let self, self.isRunning, !Task.isCancelled else { break }
        await self.pollGuest()
      }
    }
    if configuration.direction.sendsToGuest {
      let interval = configuration.hostPollInterval
      hostTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: interval)
          guard let self, self.isRunning, !Task.isCancelled else { break }
          await self.pollHost()
        }
      }
    }
  }

  public func stop() {
    isRunning = false
    hostTask?.cancel()
    guestTask?.cancel()
    hostTask = nil
    guestTask = nil
  }

  /// Sends the current host clipboard now, ignoring the size limit and the "already synced" check.
  /// Waits for any in-flight transfer first.
  @discardableResult
  public func sendNow() async -> Bool {
    guard let payload = snapshotHost() else {
      emit(.skipped(reason: "The Mac clipboard is empty."))
      return false
    }
    return await serialized { await self.send(payload, manual: true) == .sent }
  }

  /// Fetches the guest clipboard now, ignoring the size limit and the "already synced" check.
  /// Waits for any in-flight transfer first.
  @discardableResult
  public func fetchNow() async -> Bool {
    await serialized { await self.receive(maxBytes: nil, force: true) } == .received
  }

  // MARK: Transfers

  /// Runs `operation` after every previously queued transfer has finished.
  @discardableResult
  private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
    activeTransfers += 1
    defer { activeTransfers -= 1 }
    let previous = transferQueue
    let task = Task { @MainActor in
      await previous?.value
      return await operation()
    }
    transferQueue = Task { @MainActor in _ = await task.value }
    return await task.value
  }

  // MARK: Host → guest

  private func currentHostObservation() -> HostObservation {
    HostObservation(changeCount: hostPasteboard.changeCount, shape: PasteboardCodec.shape(hostPasteboard))
  }

  private func pollHost() async {
    let count = hostPasteboard.changeCount
    if let handled = handledHost, count == handled.changeCount {
      // Same change count as the state last acted on: only items added late can still differ.
      let isPendingLateWrite = pendingHost?.changeCount == count
      let inWindow = hostLateWriteDeadline.map { ContinuousClock.now < $0 } ?? false
      guard isPendingLateWrite || inWindow else { return }
      let shape = PasteboardCodec.shape(hostPasteboard)
      guard shape != handled.shape else {
        pendingHost = nil
        return
      }
      await observeHost(HostObservation(changeCount: count, shape: shape))
      return
    }
    // Leave the change unhandled while busy or while the guest is unreachable; a later poll
    // observes it again once the guest is back.
    guard activeTransfers == 0, guestStatus.isAvailable else { return }
    await observeHost(currentHostObservation())
  }

  /// Acts on a host state once two consecutive polls saw exactly the same change count and
  /// contents. An empty pasteboard is a writer between `clearContents` and `writeObjects`.
  private func observeHost(_ observation: HostObservation) async {
    guard !observation.shape.isEmpty, pendingHost == observation else {
      pendingHost = observation
      return
    }
    guard activeTransfers == 0, guestStatus.isAvailable else { return }
    pendingHost = nil
    let previous = handledHost
    handledHost = observation
    hostLateWriteDeadline = ContinuousClock.now + configuration.hostLateWriteWindow

    guard let payload = snapshotHost(), payload.fingerprint != lastSyncedFingerprint else { return }
    guard !isDegradedEcho(payload) else { return }
    if payload.totalByteCount > configuration.maxAutomaticTransferBytes {
      if lastSkippedFingerprint != payload.fingerprint {
        lastSkippedFingerprint = payload.fingerprint
        emit(.skipped(reason: "\(payload.summary) is larger than the automatic sync limit. Use Send to VM to copy it anyway."))
      }
      return
    }
    guard payload.fingerprint != lastRejectedFingerprint else { return }
    let outcome = await serialized { await self.send(payload, manual: false) }
    if outcome == .unreachable, handledHost == observation {
      // Not delivered because the guest couldn't be reached: retry once it is back.
      handledHost = previous
      hostLateWriteDeadline = nil
    }
  }

  private func snapshotHost() -> ClipboardPayload? {
    guard let payload = PasteboardCodec.snapshot(hostPasteboard) else { return nil }
    if !configuration.includeFiles, !payload.files.isEmpty { return nil }
    return payload
  }

  enum SendOutcome: Sendable, Equatable {
    case sent
    /// The guest refused this payload deterministically; retrying won't help.
    case rejected
    /// The guest couldn't be reached; the change should be retried later.
    case unreachable
  }

  private func send(_ payload: ClipboardPayload, manual: Bool) async -> SendOutcome {
    do {
      let state = try await bridge.pushToGuest(payload, endpoint: endpoint)
      knownGuestChangeCount = state.changeCount
      lastSyncedFingerprint = payload.fingerprint
      lastPushedGuestFingerprint = state.fingerprint
      rememberSyncedFiles(payload)
      lastRejectedFingerprint = nil
      emit(.sentToGuest(summary: payload.summary, date: Date()))
      return .sent
    } catch {
      let message = "Couldn't send to \(endpoint.vmName): \(error.localizedDescription)"
      switch Self.failureKind(of: error) {
      case .transient:
        emit(.failed(message: message))
        recordClipboardFailure(error)
        return .unreachable
      case .permanent:
        if case GuestTransportError.unsupported = error { recordClipboardFailure(error) }
        if manual || lastRejectedFingerprint != payload.fingerprint { emit(.failed(message: message)) }
        lastRejectedFingerprint = payload.fingerprint
        return .rejected
      }
    }
  }

  // MARK: Guest → host

  /// The delay before the next guest poll: the configured interval, doubling per consecutive
  /// failure up to `maximumBackoff`; always the maximum while the guest has no usable clipboard.
  var guestDelay: Duration {
    if guestClipboardUnsupported { return configuration.maximumBackoff }
    guard consecutiveGuestFailures > 0 else { return configuration.guestPollInterval }
    let factor = 1 << min(consecutiveGuestFailures, 5)
    return min(configuration.guestPollInterval * factor, configuration.maximumBackoff)
  }

  /// Probes the guest and confirms its clipboard is readable. Only a successful clipboard read
  /// resets the back-off, so an agent that answers without a usable clipboard can't flap.
  private func checkGuest() async {
    if guestStatus == .unknown { updateGuestStatus(.checking) }
    let status = await GuestProbe.probe(endpoint.transport)
    guard status.isAvailable else {
      consecutiveGuestFailures += 1
      updateGuestStatus(status)
      return
    }
    do {
      let changeCount = try await bridge.guestChangeCount(endpoint)
      if knownGuestChangeCount == nil { knownGuestChangeCount = changeCount }
      consecutiveGuestFailures = 0
      guestClipboardUnsupported = false
      updateGuestStatus(status)
    } catch {
      recordClipboardFailure(error, immediately: true)
    }
  }

  private func pollGuest() async {
    guard activeTransfers == 0 else { return }
    guard guestStatus.isAvailable else {
      await checkGuest()
      return
    }
    guard configuration.direction.receivesFromGuest else { return }
    var changeCount: Int
    do {
      changeCount = try await bridge.guestChangeCount(endpoint)
    } catch {
      recordClipboardFailure(error)
      return
    }
    consecutiveGuestFailures = 0
    guard let known = knownGuestChangeCount else {
      knownGuestChangeCount = changeCount
      return
    }
    guard changeCount != known else { return }
    do {
      changeCount = try await settledGuestChangeCount(from: changeCount)
    } catch {
      recordClipboardFailure(error)
      return
    }
    // Our own push may have happened while settling.
    guard activeTransfers == 0, changeCount != knownGuestChangeCount else { return }
    let maxBytes = configuration.maxAutomaticTransferBytes
    let outcome = await serialized { await self.receive(maxBytes: maxBytes, force: false) }
    if outcome == .transientFailure {
      // Keep the change pending: the next poll (after the back-off) pulls it again.
      return
    }
    if knownGuestChangeCount == known { knownGuestChangeCount = changeCount }
  }

  /// Re-reads the guest change count after `guestSettleDelay` until it stops moving.
  private func settledGuestChangeCount(from observed: Int) async throws -> Int {
    guard configuration.guestSettleDelay > .zero else { return observed }
    var latest = observed
    for _ in 0..<Self.maximumSettleRounds {
      try await Task.sleep(for: configuration.guestSettleDelay)
      let again = try await bridge.guestChangeCount(endpoint)
      if again == latest { return again }
      latest = again
    }
    return latest
  }

  /// Counts a failed clipboard operation. "No clipboard tool" makes the guest stably unavailable
  /// at the maximum back-off; other errors mark it unavailable after two consecutive failures.
  private func recordClipboardFailure(_ error: any Error, immediately: Bool = false) {
    consecutiveGuestFailures += 1
    if case GuestTransportError.unsupported(let reason) = error {
      guestClipboardUnsupported = true
      updateGuestStatus(.unavailable(reason: reason))
    } else if immediately || consecutiveGuestFailures >= 2 {
      updateGuestStatus(.unavailable(reason: error.localizedDescription))
    }
  }

  /// Whether a payload read from the guest is our own write coming back.
  /// A file identity that survives being copied between staging folders.
  struct FileIdentity: Hashable, Sendable {
    var name: String
    var size: Int
  }

  private func rememberSyncedFiles(_ payload: ClipboardPayload) {
    lastSyncedFiles = Set(payload.files.map { FileIdentity(name: $0.lastPathComponent, size: ClipboardPayload.byteCount(of: $0)) })
    lastSyncedFilesAt = payload.files.isEmpty ? nil : ContinuousClock.now
  }

  /// A strict subset of the files just synced, shortly after the sync: some system component
  /// republished the clipboard without part of it (hidden files are typical). Sending it back
  /// would overwrite the complete copy on the other side.
  func isDegradedEcho(_ payload: ClipboardPayload) -> Bool {
    guard let syncedAt = lastSyncedFilesAt, ContinuousClock.now - syncedAt < configuration.degradedEchoWindow,
      payload.items.isEmpty, !payload.files.isEmpty
    else { return false }
    let identities = Set(payload.files.map { FileIdentity(name: $0.lastPathComponent, size: ClipboardPayload.byteCount(of: $0)) })
    return identities.isSubset(of: lastSyncedFiles)
  }

  func isEcho(_ payload: ClipboardPayload) -> Bool {
    payload.fingerprint == lastSyncedFingerprint || payload.fingerprint == lastPushedGuestFingerprint
  }

  enum ReceiveOutcome: Sendable, Equatable {
    case received
    /// Nothing to apply (empty, our own echo, over the limit or filtered out).
    case skipped
    /// The guest couldn't be reached; the change stays pending.
    case transientFailure
    /// The guest was reached but the read failed deterministically; the change is dropped.
    case permanentFailure
  }

  private func receive(maxBytes: Int?, force: Bool) async -> ReceiveOutcome {
    do {
      let includeFiles = configuration.includeFiles || force
      guard let payload = try await bridge.pullFromGuest(endpoint, maxBytes: maxBytes, includeFiles: includeFiles),
        !payload.isEmpty
      else {
        if force { emit(.skipped(reason: "The clipboard in \(endpoint.vmName) is empty.")) }
        return .skipped
      }
      // A Linux guest holding the plain-text projection of a richer host clipboard must not
      // downgrade the host.
      guard force || !(isEcho(payload) || isDegradedEcho(payload)) else { return .skipped }
      let changeCount = PasteboardCodec.write(payload, to: hostPasteboard)
      handledHost = HostObservation(changeCount: changeCount, shape: PasteboardCodec.shape(hostPasteboard))
      pendingHost = nil
      hostLateWriteDeadline = nil
      lastSyncedFingerprint = payload.fingerprint
      lastPushedGuestFingerprint = nil
      rememberSyncedFiles(payload)
      emit(.receivedFromGuest(summary: payload.summary, date: Date()))
      return .received
    } catch GuestTransportError.tooLarge(let bytes, let limit) {
      let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
      let maximum = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
      emit(.skipped(reason: "The clipboard in \(endpoint.vmName) holds \(size), above the \(maximum) automatic limit. Use Paste from VM to copy it anyway."))
      return .skipped
    } catch {
      emit(.failed(message: "Couldn't read the clipboard of \(endpoint.vmName): \(error.localizedDescription)"))
      if Self.failureKind(of: error) == .transient {
        recordClipboardFailure(error)
        return .transientFailure
      }
      return .permanentFailure
    }
  }

  // MARK: Events

  private func updateGuestStatus(_ status: GuestAgentStatus) {
    guard status != guestStatus else { return }
    guestStatus = status
    emit(.guestStatus(status))
  }

  private func emit(_ event: ClipboardSyncEvent) {
    continuation.yield(event)
  }
}
