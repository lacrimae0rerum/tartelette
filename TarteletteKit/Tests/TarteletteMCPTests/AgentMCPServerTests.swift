import Foundation
import MCP
import Testing

@testable import TarteletteAgents
@testable import TarteletteMCP

@Suite("Agent MCP server, end to end over an in-memory transport")
struct AgentMCPServerTests {
  /// Remembers the client names the server built toolboxes for.
  final class ClientNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String?] = []
    var all: [String?] { lock.withLock { names } }
    func append(_ name: String?) { lock.withLock { names.append(name) } }
  }

  actor Notifications {
    private(set) var progress: [(value: Double, total: Double?, token: ProgressToken)] = []
    func append(_ parameters: ProgressNotification.Parameters) {
      progress.append((parameters.progress, parameters.total, parameters.progressToken))
    }
  }

  struct Session {
    let client: Client
    let server: Server
    let initialized: Initialize.Result
  }

  func connect(_ makeToolbox: @escaping @Sendable (String?) throws -> any AgentToolProviding) async throws -> Session {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let server = try await AgentMCPServer(version: "1.2.3", makeToolbox: makeToolbox).start(on: serverTransport)
    let client = Client(name: "test-agent", version: "0.1")
    let initialized = try await client.connect(transport: clientTransport)
    return Session(client: client, server: server, initialized: initialized)
  }

  @Test func introducesItselfWithInstructions() async throws {
    let session = try await connect { _ in FakeToolbox() }
    defer { Task { await session.client.disconnect() } }

    #expect(session.initialized.serverInfo.name == "tartelette")
    #expect(session.initialized.serverInfo.version == "1.2.3")
    #expect(session.initialized.capabilities.tools != nil)
    let instructions = try #require(session.initialized.instructions)
    for phrase in ["shared", "list_vms", "create_sandbox", "template", "delete"] {
      #expect(instructions.contains(phrase), "\(phrase)")
    }
  }

  @Test func listsTheToolsAndRunsThemWithTheClientName() async throws {
    let names = ClientNames()
    let toolbox = FakeToolbox()
    let session = try await connect { name in
      names.append(name)
      return toolbox
    }
    defer { Task { await session.client.disconnect() } }

    let (tools, _) = try await session.client.listTools()
    #expect(tools.map(\.name) == AgentTool.allCases.map(\.rawValue))

    let (content, isError) = try await session.client.callTool(name: "vm_info", arguments: ["name": "dev"])
    #expect(isError != true)
    guard case .text(let text, _, _)? = content.first else { Issue.record("no text content"); return }
    #expect(text.hasPrefix(#"{"cpuCount":4,"display":"1024x768","memoryMB":8192,"summary":{"#))
    #expect(toolbox.calls == [.vmInfo(name: "dev")])
    #expect(names.all == ["test-agent"])
  }

  @Test func rejectsUnknownToolsWithInvalidParams() async throws {
    let session = try await connect { _ in FakeToolbox() }
    defer { Task { await session.client.disconnect() } }

    let error = await #expect(throws: MCPError.self) {
      _ = try await session.client.callTool(name: "format_disk", arguments: [:])
    }
    #expect(error?.code == -32602)
  }

  @Test func forwardsCloneProgressWhenTheCallAsksForIt() async throws {
    let notifications = Notifications()
    let session = try await connect { _ in FakeToolbox(cloneProgress: [0.25, 0.25, 0.5, 0.4, 1]) }
    defer { Task { await session.client.disconnect() } }
    await session.client.onNotification(ProgressNotification.self) { await notifications.append($0.params) }

    let (_, isError) = try await session.client.callTool(
      name: "create_sandbox", arguments: ["template": "base"], meta: Metadata(progressToken: .string("clone-1")))

    #expect(isError != true)
    let progress = await notifications.progress
    // Only increasing values: progress notifications must grow.
    #expect(progress.map(\.value) == [0.25, 0.5, 1])
    #expect(progress.allSatisfy { $0.total == 1 && $0.token == .string("clone-1") })
  }

  @Test func sendsNoProgressWithoutAToken() async throws {
    let notifications = Notifications()
    let session = try await connect { _ in FakeToolbox(cloneProgress: [0.5, 1]) }
    defer { Task { await session.client.disconnect() } }
    await session.client.onNotification(ProgressNotification.self) { await notifications.append($0.params) }

    _ = try await session.client.callTool(name: "create_sandbox", arguments: ["template": "base"])

    #expect(await notifications.progress.isEmpty)
  }

  @Test func readsTheVersionFromTheEnclosingApp() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let contents = directory.url.appendingPathComponent("Tartelette.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(
      at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleShortVersionString": "1.4.0"], format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))

    let inApp = contents.appendingPathComponent("MacOS/tartelette-mcp")
    #expect(AgentMCPServer.version(forExecutableAt: inApp) == "1.4.0")
    #expect(AgentMCPServer.version(forExecutableAt: directory.url.appendingPathComponent("bin/tartelette-mcp")) == "dev")
    #expect(AgentMCPServer.version(forExecutableAt: directory.url.appendingPathComponent("tartelette-mcp")) == "dev")
  }
}
