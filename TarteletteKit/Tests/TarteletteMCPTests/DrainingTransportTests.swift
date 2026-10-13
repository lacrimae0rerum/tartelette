import Foundation
import Logging
import MCP
import Testing

@testable import TarteletteMCP

@Suite("Draining transport", .timeLimit(.minutes(1)))
struct DrainingTransportTests {
  /// Delivers fixed messages, then ends its input; records what is sent.
  actor ScriptedTransport: Transport {
    nonisolated let logger = Logger(label: "test.scripted")
    let incoming: [String]
    private(set) var sent: [String] = []

    init(incoming: [String]) {
      self.incoming = incoming
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_ data: Data) async throws { sent.append(String(decoding: data, as: UTF8.self)) }

    func receive() -> AsyncThrowingStream<Data, any Error> {
      AsyncThrowingStream { continuation in
        for message in incoming { continuation.yield(Data(message.utf8)) }
        continuation.finish()
      }
    }
  }

  actor Events {
    private(set) var all: [String] = []
    func append(_ event: String) { all.append(event) }
  }

  @Test func endsItsInputOnlyAfterAnsweringEveryRequest() async throws {
    let transport = DrainingTransport(
      ScriptedTransport(incoming: [
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_vms"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":"two","method":"tools/list"}"#,
      ]))
    let events = Events()
    let stream = await transport.receive()
    let reader = Task {
      for try await _ in stream { await events.append("received") }
      await events.append("ended")
    }

    // Give an input that isn't drained time to end before the answers go out.
    try await Task.sleep(for: .milliseconds(100))
    await events.append("answering")
    try await transport.send(Data(#"{"jsonrpc":"2.0","id":"two","result":{}}"#.utf8))
    try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
    try await reader.value

    #expect(await events.all == ["received", "received", "received", "answering", "ended"])
  }

  @Test func doesNotWaitForCancelledRequests() async throws {
    let transport = DrainingTransport(
      ScriptedTransport(incoming: [
        #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"exec"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#,
      ]))
    var received = 0
    for try await _ in await transport.receive() { received += 1 }

    #expect(received == 2)
  }

  @Test func forwardsWhatTheServerSends() async throws {
    let base = ScriptedTransport(incoming: [])
    let transport = DrainingTransport(base)

    try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/progress"}"#.utf8))

    #expect(await base.sent == [#"{"jsonrpc":"2.0","method":"notifications/progress"}"#])
  }
}
