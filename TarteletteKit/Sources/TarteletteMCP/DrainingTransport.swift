import Foundation
import Logging
import MCP

/// Wraps a transport so its incoming messages end only once every request received has been
/// answered or cancelled.
///
/// The MCP SDK handles each request in a task of its own and stops when the client closes its
/// end (stdin, for stdio). A helper that exited then would drop the answers still in flight and
/// abandon tool calls midway, such as a clone not yet recorded as an agent VM.
public actor DrainingTransport: Transport {
  public nonisolated let logger: Logger
  private let base: any Transport
  private var unanswered: Set<ID> = []
  private var inputEnded = false
  private var inputError: (any Error)?
  private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?

  public init(_ base: any Transport, logger: Logger = Logger(label: "tartelette.mcp.draining")) {
    self.base = base
    self.logger = logger
  }

  public func connect() async throws {
    try await base.connect()
  }

  public func disconnect() async {
    await base.disconnect()
  }

  public func send(_ data: Data) async throws {
    try await base.send(data)
    for message in Self.messages(in: data) where message.method == nil {
      if let id = message.id { unanswered.remove(id) }
    }
    finishIfDrained()
  }

  public func receive() -> AsyncThrowingStream<Data, any Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    self.continuation = continuation
    Task { await forwardIncoming() }
    return stream
  }

  private func forwardIncoming() async {
    do {
      for try await data in await base.receive() {
        for message in Self.messages(in: data) {
          if message.method == CancelledNotification.name, let id = message.cancelledRequest {
            unanswered.remove(id)
          } else if message.method != nil, let id = message.id {
            unanswered.insert(id)
          }
        }
        continuation?.yield(data)
      }
    } catch {
      inputError = error
    }
    inputEnded = true
    finishIfDrained()
  }

  private func finishIfDrained() {
    guard inputEnded, unanswered.isEmpty, let continuation else { return }
    continuation.finish(throwing: inputError)
    self.continuation = nil
  }

  /// The JSON-RPC fields that tell requests, notifications and responses apart.
  private struct Envelope: Decodable {
    let id: ID?
    let method: String?
    /// `params.requestId` of a cancellation notification.
    let cancelledRequest: ID?

    private enum CodingKeys: String, CodingKey { case id, method, params }
    private enum ParameterKeys: String, CodingKey { case requestId }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try? container.decodeIfPresent(ID.self, forKey: .id)
      method = try? container.decodeIfPresent(String.self, forKey: .method)
      let parameters = try? container.nestedContainer(keyedBy: ParameterKeys.self, forKey: .params)
      cancelledRequest = try? parameters?.decodeIfPresent(ID.self, forKey: .requestId)
    }
  }

  /// The message, or each message of a batch; nothing for data that isn't JSON-RPC.
  private static func messages(in data: Data) -> [Envelope] {
    let decoder = JSONDecoder()
    if let message = try? decoder.decode(Envelope.self, from: data) { return [message] }
    return (try? decoder.decode([Envelope].self, from: data)) ?? []
  }
}
