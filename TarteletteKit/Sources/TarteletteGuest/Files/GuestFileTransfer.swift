import Foundation

/// Drag-and-drop style file copies between the host and a guest, verified end to end.
public struct GuestFileTransfer: Sendable {
  /// Copies host files or folders into a guest folder (default: the guest user's Desktop).
  ///
  /// Existing guest items are never overwritten; clashing names get a numeric suffix.
  /// - Returns: The guest paths of the copied items.
  @discardableResult
  public static func send(
    _ files: [URL],
    to endpoint: GuestEndpoint,
    destination: String = "~/Desktop",
    bridge: ClipboardBridge
  ) async throws -> [String] {
    try await bridge.sendFiles(files, to: endpoint, guestDirectory: destination)
  }

  /// Copies guest files or folders into a new subfolder of `directory` on the host.
  /// - Returns: The local URLs of the copied items.
  @discardableResult
  public static func receive(
    _ guestPaths: [String],
    from endpoint: GuestEndpoint,
    to directory: URL,
    bridge: ClipboardBridge
  ) async throws -> [URL] {
    try await bridge.receiveFiles(guestPaths, from: endpoint, into: directory)
  }
}
