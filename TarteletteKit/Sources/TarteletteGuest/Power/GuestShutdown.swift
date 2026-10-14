import Foundation
import TarteletteCore
import os

/// Asks a guest OS to shut down cleanly.
///
/// SIGUSR2 to `tart run` makes Tart send Virtualization's stop request, a power-button press. Linux
/// guests shut down when they get it; macOS guests don't reliably (a headless one ignores it), so
/// a macOS guest is asked from the inside instead: loginwindow, through the Tart Guest Agent,
/// which runs as the logged-in user on Cirrus Labs images and needs no permission prompt for it.
public enum GuestShutdown {
  /// Asks loginwindow to shut down (`kAEShutDown`). `tart exec`'s PATH is minimal, hence the full path.
  public static let macOSCommand = [
    "/usr/bin/osascript", "-e", "tell application \"loginwindow\" to «event aevtshut»",
  ]

  /// How long the in-guest request may take to be delivered; the guest then shuts down on its own.
  public static let deliveryTimeout: Duration = .seconds(15)

  /// Whether the in-guest request reached a guest that accepted it.
  public enum Delivery: Sendable, Equatable {
    /// The request exited 0: the guest is shutting down.
    case delivered
    /// The agent was unreachable, the request failed or it timed out.
    case notDelivered(reason: String)
  }

  /// Which request asked the guest to shut down.
  public enum Request: String, Sendable, Equatable {
    /// loginwindow, asked from inside a macOS guest.
    case inGuest
    /// The caller's stop request (SIGUSR2 to `tart run`).
    case stopRequest
  }

  /// Whether guests running `os` are asked from the inside first.
  public static func requestsInGuest(for os: VMOperatingSystem) -> Bool {
    os == .macOS
  }

  /// Asks a macOS guest's loginwindow to shut down through `transport`.
  public static func requestInGuest(
    through transport: any GuestTransport,
    timeout: Duration = deliveryTimeout
  ) async -> Delivery {
    do {
      let output = try await transport.run(macOSCommand, timeout: timeout)
      guard output.succeeded else {
        let diagnostic = output.diagnostic
        return .notDelivered(
          reason: diagnostic.isEmpty ? "The shutdown request failed with exit code \(output.status)." : diagnostic)
      }
      return .delivered
    } catch {
      return .notDelivered(reason: error.localizedDescription)
    }
  }

  /// Asks the guest to shut down the way its OS honours: a macOS guest from the inside, with
  /// `stopRequest` only when that request isn't delivered; any other guest with `stopRequest`.
  ///
  /// - Returns: The request that was made.
  /// - Throws: Whatever `stopRequest` throws.
  public static func request(
    for os: VMOperatingSystem,
    through transport: any GuestTransport,
    stopRequest: @Sendable () throws -> Void
  ) async rethrows -> Request {
    if requestsInGuest(for: os), await requestInGuest(through: transport) == .delivered {
      return .inGuest
    }
    try stopRequest()
    return .stopRequest
  }
}

// MARK: - Every guest at once, within a bound

extension GuestShutdown {
  /// A running VM to ask to shut down.
  public struct Target: Sendable {
    public var name: String
    public var os: VMOperatingSystem
    /// Reaches the guest agent; only used for guests asked from the inside.
    public var transport: any GuestTransport
    /// The caller's stop request (SIGUSR2 to `tart run`).
    public var stopRequest: @Sendable () throws -> Void

    public init(
      name: String, os: VMOperatingSystem, transport: any GuestTransport,
      stopRequest: @escaping @Sendable () throws -> Void
    ) {
      self.name = name
      self.os = os
      self.transport = transport
      self.stopRequest = stopRequest
    }
  }

  /// How long `requestAll` waits by default: the in-guest delivery timeout, plus some slack.
  public static let requestAllLimit: Duration = .seconds(20)

  private struct RequestAllState {
    var requests: [String: Request] = [:]
    /// VMs whose stop request was sent or tried, so none gets it twice.
    var stopRequested: Set<String> = []
  }

  /// Asks every target to shut down at the same time, as `request(for:through:stopRequest:)` does,
  /// and returns once every request was made or `limit` has passed, whichever comes first.
  ///
  /// At the limit, a guest whose in-guest request is still running gets its stop request at once;
  /// the request left running is cancelled and never sends a second one. So this never waits much
  /// longer than `limit`, even when a request hangs.
  ///
  /// - Returns: The request each VM got. A VM whose stop request failed is missing.
  public static func requestAll(
    _ targets: [Target], waitingAtMost limit: Duration = requestAllLimit
  ) async -> [String: Request] {
    let state = OSAllocatedUnfairLock(initialState: RequestAllState())
    /// Sends `target`'s stop request unless it was already sent or tried.
    @Sendable func sendStopRequestOnce(_ target: Target) throws -> Bool {
      guard state.withLock({ $0.stopRequested.insert(target.name).inserted }) else { return false }
      try target.stopRequest()
      return true
    }

    let work = Task {
      await withTaskGroup(of: Void.self) { group in
        for target in targets {
          group.addTask {
            let request = try? await request(for: target.os, through: target.transport) {
              _ = try sendStopRequestOnce(target)
            }
            if let request { state.withLock { $0.requests[target.name] = request } }
          }
        }
      }
    }

    let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let pending = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: continuation)
      @Sendable func resume(finished: Bool) {
        pending.withLock { continuation in
          defer { continuation = nil }
          return continuation
        }?.resume(returning: finished)
      }
      let timer = Task {
        do { try await Task.sleep(for: limit) } catch { return }
        resume(finished: false)
      }
      Task {
        await work.value
        timer.cancel()
        resume(finished: true)
      }
    }

    if !finished {
      work.cancel()
      for target in targets where state.withLock({ $0.requests[target.name] == nil }) {
        if (try? sendStopRequestOnce(target)) == true {
          state.withLock { $0.requests[target.name] = .stopRequest }
        }
      }
    }
    return state.withLock { $0.requests }
  }
}
