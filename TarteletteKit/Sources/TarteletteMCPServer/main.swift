import Foundation
import MCP
import TarteletteMCP

// `tartelette-mcp`: the MCP server agents launch to use the VMs shared with them in Tartelette.
// In server mode, stdout carries the protocol only; diagnostics go to stderr.

let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
let version = AgentMCPServer.version(forExecutableAt: executable)
let options = CommandLine.arguments.dropFirst()

func printToStandardError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

if options.contains("--version") {
  print("tartelette-mcp \(version)")
  exit(0)
}
if options.contains("--help") || options.contains("-h") {
  print(
    """
    tartelette-mcp \(version): Tartelette's MCP server for AI agents.

    Lets agents use the Tart VMs you share with them in Tartelette › Settings › Agents.
    Agents start it themselves and talk to it over stdin and stdout.

    Register it with your agent, for example:
      claude mcp add tartelette -- \(executable.path)

    Options:
      -h, --help  Show this help.
      --version   Show the version.
    """)
  exit(0)
}
if let option = options.first {
  printToStandardError("tartelette-mcp: unknown option “\(option)”. Run tartelette-mcp --help for usage.")
  exit(64)
}

// Settings are read for every tool call, so changes made in the app apply at once. When Tart
// can't be found, the server still runs and each tool explains how to install or choose it.
let server = AgentMCPServer(version: version) { clientName in
  try TarteletteSettings(defaults: TarteletteSettings.appDefaults()).makeToolbox(clientName: clientName)
}
do {
  let running = try await server.start(on: DrainingTransport(StdioTransport()))
  await running.waitUntilCompleted()
  await running.stop()
} catch {
  printToStandardError("tartelette-mcp: \(error.localizedDescription)")
  exit(1)
}
