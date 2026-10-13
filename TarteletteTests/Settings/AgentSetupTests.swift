import Foundation
import Testing
import TarteletteKit

@testable import Tartelette

/// The setup snippets Settings › Agents offers to copy.
@Suite("Agent setup snippets")
struct AgentSetupTests {
  @Test func claudeCodeCommandRegistersTheHelper() {
    let installed = AgentSetup(helperPath: "/Applications/Tartelette.app/Contents/MacOS/tartelette-mcp")
    #expect(installed.claudeCommand == "claude mcp add tartelette -- /Applications/Tartelette.app/Contents/MacOS/tartelette-mcp")

    let spaced = AgentSetup(helperPath: "/Volumes/Work Disk/Tartelette.app/Contents/MacOS/tartelette-mcp")
    #expect(spaced.claudeCommand == "claude mcp add tartelette -- '/Volumes/Work Disk/Tartelette.app/Contents/MacOS/tartelette-mcp'")
  }

  @Test func mcpConfigurationIsJSONThatNamesTheHelper() throws {
    let path = #"/Volumes/Odd "Name"\Tartelette.app/Contents/MacOS/tartelette-mcp"#
    let json = AgentSetup(helperPath: path).mcpConfiguration

    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let servers = try #require(object["mcpServers"] as? [String: Any])
    let server = try #require(servers["tartelette"] as? [String: Any])
    #expect(server["command"] as? String == path)
    #expect(server.count == 1)
  }
}
