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
/// direction) and the change counts produced by its own writes on both sides. A change is only
/// propagated when it was made by someone else and its contents differ from what was last synced,
/// so a payload never bounces back. Host changes are coalesced: a change is sent once the host
/// pasteboard has been stable for one poll interval.
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

    public init(
      direction: Direction = .bidirectional,
      hostPollInterval: Duration = .milliseconds(500),
      guestPollInterval: Duration = .milliseconds(1500),
      maxAutomaticTransferBytes: Int = 50 * 1024 * 1024,
      includeFiles: Bool = true
    ) {
      self.direction = direction
      self.hostPollInterval = hostPollInterval
      self.guestPollInterval = guestPollInterval
      self.maxAutomaticTransferBytes = maxAutomaticTransferBytes
      self.includeFiles = includeFiles
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
  private var knownHostChangeCount = 0
  private var pendingHostChangeCount: Int?
  private var knownGuestChangeCount: Int?
  private var isTransferring = false
  private var consecutiveGuestFailures = 0
  private var lastSkippedFingerprint: String?

  /// Upper bound for the guest poll back-off.
  static let maximumBackoff: Duration = .seconds(15)

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
  @discardableResult
  public func sendNow() async -> Bool {
    guard let payload = snapshotHost() else {
      emit(.skipped(reason: "The Mac clipboard is empty."))
      return false
    }
    return await send(payload)
  }

  /// Fetches the guest clipboard now, ignoring the size limit and the "already synced" check.
  @discardableResult
  public func fetchNow() async -> Bool {
    await receive(maxBytes: nil, force: true)
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
    guard !isTransferring else { return }
    knownHostChangeCount = current
    pendingHostChangeCount = nil

    guard let payload = snapshotHost(), payload.fingerprint != lastSyncedFingerprint else { return }
    guard guestStatus.isAvailable else { return }
    if payload.totalByteCount > configuration.maxAutomaticTransferBytes {
      if lastSkippedFingerprint != payload.fingerprint {
        lastSkippedFingerprint = payload.fingerprint
        emit(.skipped(reason: "\(payload.summary) is larger than the automatic sync limit. Use Send to VM to copy it anyway."))
      }
      return
    }
    await send(payload)
  }

  private func snapshotHost() -> ClipboardPayload? {
    guard let payload = PasteboardCodec.snapshot(hostPasteboard) else { return nil }
    if !configuration.includeFiles, !payload.files.isEmpty { return nil }
    return payload
  }

  @discardableResult
  private func send(_ payload: ClipboardPayload) async -> Bool {
    isTransferring = true
    defer { isTransferring = false }
    do {
      let state = try await bridge.pushToGuest(payload, endpoint: endpoint)
      knownGuestChangeCount = state.changeCount
      lastSyncedFingerprint = payload.fingerprint
      emit(.sentToGuest(summary: payload.summary, date: Date()))
      return true
    } catch {
      emit(.failed(message: "Couldn't send to \(endpoint.vmName): \(error.localizedDescription)"))
      return false
    }
  }

  // MARK: Guest → host

  private var guestDelay: Duration {
    guard consecutiveGuestFailures > 0 else { return configuration.guestPollInterval }
    let factor = 1 << min(consecutiveGuestFailures, 5)
    return min(configuration.guestPollInterval * factor, Self.maximumBackoff)
  }

  private func checkGuest() async {
    updateGuestStatus(.checking)
    let status = await GuestProbe.probe(endpoint.transport)
    updateGuestStatus(status)
    guard status.isAvailable else {
      consecutiveGuestFailures += 1
      return
    }
    consecutiveGuestFailures = 0
    if knownGuestChangeCount == nil {
      knownGuestChangeCount = try? await bridge.guestChangeCount(endpoint)
    }
  }

  private func pollGuest() async {
    guard !isTransferring else { return }
    guard guestStatus.isAvailable else {
      await checkGuest()
      return
    }
    guard configuration.direction.receivesFromGuest else { return }
    let changeCount: Int
    do {
      changeCount = try await bridge.guestChangeCount(endpoint)
    } catch {
      consecutiveGuestFailures += 1
      if consecutiveGuestFailures >= 2 {
        updateGuestStatus(.unavailable(reason: error.localizedDescription))
      }
      return
    }
    consecutiveGuestFailures = 0
    guard let known = knownGuestChangeCount else {
      knownGuestChangeCount = changeCount
      return
    }
    guard changeCount != known else { return }
    knownGuestChangeCount = changeCount
    await receive(maxBytes: configuration.maxAutomaticTransferBytes, force: false)
  }

  @discardableResult
  private func receive(maxBytes: Int?, force: Bool) async -> Bool {
    guard !isTransferring else { return false }
    isTransferring = true
    defer { isTransferring = false }
    do {
      guard let payload = try await bridge.pullFromGuest(endpoint, maxBytes: maxBytes), !payload.isEmpty else {
        if force { emit(.skipped(reason: "The clipboard in \(endpoint.vmName) is empty.")) }
        return false
      }
      if !configuration.includeFiles, !payload.files.isEmpty, !force { return false }
      guard force || payload.fingerprint != lastSyncedFingerprint else { return false }
      knownHostChangeCount = PasteboardCodec.write(payload, to: hostPasteboard)
      pendingHostChangeCount = nil
      lastSyncedFingerprint = payload.fingerprint
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
