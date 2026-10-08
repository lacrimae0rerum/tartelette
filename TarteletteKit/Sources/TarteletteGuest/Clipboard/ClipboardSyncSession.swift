import AppKit
import Foundation

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
/// payload never bounces back. Host changes are coalesced: a change is sent once the host
/// pasteboard has been stable for one poll interval.
///
/// Transfers are serialised: manual sends and fetches queue behind an in-flight transfer, and
/// polls skip while any transfer is active. A host change is only marked as handled once it was
/// sent or deliberately skipped, so changes made while the guest is unreachable are sent when it
/// comes back.
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

    public init(
      direction: Direction = .bidirectional,
      hostPollInterval: Duration = .milliseconds(500),
      guestPollInterval: Duration = .milliseconds(1500),
      maxAutomaticTransferBytes: Int = 50 * 1024 * 1024,
      includeFiles: Bool = true,
      maximumBackoff: Duration = .seconds(15)
    ) {
      self.direction = direction
      self.hostPollInterval = hostPollInterval
      self.guestPollInterval = guestPollInterval
      self.maxAutomaticTransferBytes = maxAutomaticTransferBytes
      self.includeFiles = includeFiles
      self.maximumBackoff = maximumBackoff
    }
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
  private var knownHostChangeCount = 0
  private var pendingHostChangeCount: Int?
  private var knownGuestChangeCount: Int?
  /// Transfers running or queued; polls skip while it is non-zero.
  private(set) var activeTransfers = 0
  private var transferQueue: Task<Void, Never>?
  /// Consecutive failed guest checks or clipboard reads; drives the poll back-off.
  private(set) var consecutiveGuestFailures = 0
  /// The guest has no usable clipboard (e.g. no clipboard tool); re-checked at the maximum back-off.
  private(set) var guestClipboardUnsupported = false
  private var lastSkippedFingerprint: String?

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
    knownHostChangeCount = hostPasteboard.changeCount
    pendingHostChangeCount = nil

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
    return await serialized { await self.send(payload) == .sent }
  }

  /// Fetches the guest clipboard now, ignoring the size limit and the "already synced" check.
  /// Waits for any in-flight transfer first.
  @discardableResult
  public func fetchNow() async -> Bool {
    await serialized { await self.receive(maxBytes: nil, force: true) }
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

  private func pollHost() async {
    let current = hostPasteboard.changeCount
    if current == knownHostChangeCount {
      pendingHostChangeCount = nil
      return
    }
    // Coalesce bursts: act once the pasteboard has been stable for a full interval.
    guard pendingHostChangeCount == current else {
      pendingHostChangeCount = current
      return
    }
    // Leave the change pending (not handled) while busy or while the guest is unreachable; it is
    // picked up by a later poll.
    guard activeTransfers == 0, guestStatus.isAvailable else { return }

    let previousKnown = knownHostChangeCount
    knownHostChangeCount = current
    pendingHostChangeCount = nil
    guard let payload = snapshotHost(), payload.fingerprint != lastSyncedFingerprint else { return }
    if payload.totalByteCount > configuration.maxAutomaticTransferBytes {
      if lastSkippedFingerprint != payload.fingerprint {
        lastSkippedFingerprint = payload.fingerprint
        emit(.skipped(reason: "\(payload.summary) is larger than the automatic sync limit. Use Send to VM to copy it anyway."))
      }
      return
    }
    let outcome = await serialized { await self.send(payload) }
    if outcome == .unreachable, knownHostChangeCount == current {
      // Not delivered because the guest couldn't be reached: retry once it is back.
      knownHostChangeCount = previousKnown
    }
  }

  private func snapshotHost() -> ClipboardPayload? {
    guard let payload = PasteboardCodec.snapshot(hostPasteboard) else { return nil }
    if !configuration.includeFiles, !payload.files.isEmpty { return nil }
    return payload
  }

  enum SendOutcome: Sendable, Equatable {
    case sent
    /// The guest rejected this payload (unsupported, duplicate names, integrity); retrying won't help.
    case rejected
    /// The guest couldn't be reached; the change should be retried later.
    case unreachable
  }

  private func send(_ payload: ClipboardPayload) async -> SendOutcome {
    do {
      let state = try await bridge.pushToGuest(payload, endpoint: endpoint)
      knownGuestChangeCount = state.changeCount
      lastSyncedFingerprint = payload.fingerprint
      lastPushedGuestFingerprint = state.fingerprint
      emit(.sentToGuest(summary: payload.summary, date: Date()))
      return .sent
    } catch {
      emit(.failed(message: "Couldn't send to \(endpoint.vmName): \(error.localizedDescription)"))
      switch error {
      case is GuestTransferError, GuestTransportError.unsupported, GuestTransportError.integrityCheckFailed,
        GuestTransportError.tooLarge:
        return .rejected
      default:
        recordClipboardFailure(error)
        return .unreachable
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
    let changeCount: Int
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
    guard changeCount != known, activeTransfers == 0 else { return }
    knownGuestChangeCount = changeCount
    let maxBytes = configuration.maxAutomaticTransferBytes
    await serialized { await self.receive(maxBytes: maxBytes, force: false) }
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
  func isEcho(_ payload: ClipboardPayload) -> Bool {
    payload.fingerprint == lastSyncedFingerprint || payload.fingerprint == lastPushedGuestFingerprint
  }

  @discardableResult
  private func receive(maxBytes: Int?, force: Bool) async -> Bool {
    do {
      let includeFiles = configuration.includeFiles || force
      guard let payload = try await bridge.pullFromGuest(endpoint, maxBytes: maxBytes, includeFiles: includeFiles),
        !payload.isEmpty
      else {
        if force { emit(.skipped(reason: "The clipboard in \(endpoint.vmName) is empty.")) }
        return false
      }
      // A Linux guest holding the plain-text projection of a richer host clipboard must not
      // downgrade the host.
      guard force || !isEcho(payload) else { return false }
      knownHostChangeCount = PasteboardCodec.write(payload, to: hostPasteboard)
      pendingHostChangeCount = nil
      lastSyncedFingerprint = payload.fingerprint
      lastPushedGuestFingerprint = nil
      emit(.receivedFromGuest(summary: payload.summary, date: Date()))
      return true
    } catch GuestTransportError.tooLarge(let bytes, let limit) {
      let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
      let maximum = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
      emit(.skipped(reason: "The clipboard in \(endpoint.vmName) holds \(size), above the \(maximum) automatic limit. Use Paste from VM to copy it anyway."))
      return false
    } catch {
      emit(.failed(message: "Couldn't read the clipboard of \(endpoint.vmName): \(error.localizedDescription)"))
      return false
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
