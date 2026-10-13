import Foundation
import TarteletteCore
import TarteletteGuest
import os

/// A guest transport with canned replies that records every command it is asked to run.
final class ScriptedTransport: GuestTransport, Sendable {
  struct Call: Sendable {
    var command: [String]
    var standardInput: Data?
    var timeout: Duration?
  }

  let label = "scripted"
  private let reply: @Sendable (Call) throws -> CommandOutput
  private let recorded = OSAllocatedUnfairLock(initialState: [Call]())

  init(reply: @escaping @Sendable (Call) throws -> CommandOutput = { _ in CommandOutput(status: 0) }) {
    self.reply = reply
  }

  /// Replies to every command with the same output.
  convenience init(status: Int32, stdout: String = "", stderr: String = "") {
    self.init { _ in CommandOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)) }
  }

  /// Every command received, oldest first.
  var calls: [Call] { recorded.withLock { $0 } }

  func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
    let call = Call(command: command, standardInput: standardInput, timeout: timeout)
    recorded.withLock { $0.append(call) }
    return try reply(call)
  }
}
