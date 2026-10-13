import Foundation
import MCP

/// The Tartelette MCP server: the agent tools over the Model Context Protocol.
///
/// Every tool call builds its toolbox afresh with the agent client's name (from the `initialize`
/// request), so the audit log records the client and settings changed in the app apply at once.
public struct AgentMCPServer: Sendable {
  /// Builds the toolbox for one tool call, given the agent client's name.
  public typealias ToolboxFactory = @Sendable (_ clientName: String?) throws -> any AgentToolProviding

  public static let name = "tartelette"

  /// Sent to the agent when it connects; clients may add it to the model's instructions.
  public static let instructions = """
    Tartelette gives you the Tart virtual machines on this Mac that the user shared with agents in the \
    Tartelette app; other VMs aren't visible. Call list_vms first to see them and what each one allows. \
    create_sandbox clones a VM shared as a template into a disposable VM that you own, and you can only \
    delete VMs created by an agent. Start a VM with start_vm (wait: true) before exec, read_file or \
    write_file. When a tool is refused, its message says which setting the user can change in Tartelette.
    """

  public let version: String
  let makeToolbox: ToolboxFactory

  public init(version: String, makeToolbox: @escaping ToolboxFactory) {
    self.version = version
    self.makeToolbox = makeToolbox
  }

  /// Starts serving `transport`. The returned server runs until the transport's incoming messages
  /// end; await its `waitUntilCompleted()`.
  public func start(on transport: any Transport) async throws -> Server {
    let client = ClientIdentity()
    let server = Server(
      name: Self.name, version: version, title: "Tartelette", instructions: Self.instructions,
      capabilities: Server.Capabilities(tools: .init(listChanged: false)))
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: AgentToolCatalog.tools) }
    await server.withMethodHandler(CallTool.self) { [makeToolbox, weak server] parameters in
      let clientName = await client.name
      let handler = AgentToolHandler { try makeToolbox(clientName) }
      guard let token = parameters._meta?.progressToken else {
        return try await handler.call(parameters.name, arguments: parameters.arguments)
      }
      return try await Self.reportingProgress(to: token, via: server) { progress in
        try await handler.call(parameters.name, arguments: parameters.arguments, progress: progress)
      }
    }
    try await server.start(transport: transport) { info, _ in await client.setName(info.name) }
    return server
  }

  /// Runs `body`, sending the fractions it reports to the client as progress notifications for
  /// `token`, in order and only while they grow (as MCP requires), all before `body`'s result.
  static func reportingProgress<Value: Sendable>(
    to token: ProgressToken,
    via server: Server?,
    _ body: (@escaping @Sendable (Double) -> Void) async throws -> Value
  ) async throws -> Value {
    let (fractions, continuation) = AsyncStream.makeStream(of: Double.self)
    let sender = Task {
      var reported = -Double.infinity
      for await fraction in fractions where fraction > reported {
        reported = fraction
        try? await server?.notify(
          ProgressNotification.message(.init(progressToken: token, progress: fraction, total: 1)))
      }
    }
    let result: Result<Value, any Error>
    do {
      result = .success(try await body { continuation.yield($0) })
    } catch {
      result = .failure(error)
    }
    continuation.finish()
    await sender.value
    return try result.get()
  }

  /// The version of the app bundle `executable` is in (`<App>.app/Contents/MacOS`), "dev" elsewhere.
  public static func version(forExecutableAt executable: URL) -> String {
    let macOS = executable.resolvingSymlinksInPath().deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
      contents.deletingLastPathComponent().pathExtension == "app",
      let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty
    else { return "dev" }
    return version
  }
}

/// The connected agent client, as its `initialize` request named it.
private actor ClientIdentity {
  private(set) var name: String?

  func setName(_ name: String) {
    self.name = name
  }
}
