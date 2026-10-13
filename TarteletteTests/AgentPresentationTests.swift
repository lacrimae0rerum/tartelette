import Foundation
import Testing
import TarteletteKit

@testable import Tartelette

/// What Settings › Agents tells the user when `agents.json` can't be used.
@Suite("Agent settings problems")
struct AgentSettingsProblemTests {
  @Test func aSyntaxErrorSaysTheFileIsntValidJSON() {
    let error = AgentStoreError.malformed(file: "agents.json", detail: "The given data was not valid JSON.")
    let problem = AgentSettingsProblem(error, contents: Data(#"{"enabled": true, "vms": ["#.utf8))

    #expect(problem.summary == "agents.json isn't valid JSON.")
    #expect(problem.details == "The given data was not valid JSON.")
  }

  @Test func validJSONWithAWrongValueSaysAValueIsntUnderstood() {
    let error = AgentStoreError.malformed(file: "agents.json", detail: "Expected Bool but found a string.")
    let problem = AgentSettingsProblem(error, contents: Data(#"{"enabled": "yes"}"#.utf8))

    #expect(problem.summary == "agents.json has a value Tartelette doesn't understand.")
    #expect(problem.details == "Expected Bool but found a string.")
  }

  @Test func anUnreadableFileSaysTarteletteCantReadIt() {
    let error = AgentStoreError.unreadable(file: "agents.json", detail: "Permission denied.")
    let problem = AgentSettingsProblem(error, contents: nil)

    #expect(problem.summary == "Tartelette can't read agents.json.")
    #expect(problem.details == "Permission denied.")
  }

  @Test func anyOtherErrorKeepsItsDescriptionAsTheDetails() {
    struct DiskTrouble: LocalizedError {
      var errorDescription: String? { "The disk went away." }
    }
    let problem = AgentSettingsProblem(DiskTrouble(), contents: nil)

    #expect(problem.summary == "Tartelette can't read its agent settings.")
    #expect(problem.details == "The disk went away.")
  }
}

/// The sidebar mark of a VM agents can reach.
@Suite("Sidebar agent indicator")
struct AgentIndicatorTests {
  private func entry(client: String?) -> AgentVMEntry {
    AgentVMEntry(
      name: "sandbox", source: "base", client: client, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      fingerprint: "1:2:3.4")
  }

  @Test func nothingShowsWhileAgentsAreOff() {
    #expect(AgentIndicator(enabled: false, creator: entry(client: "claude-code"), access: .none) == nil)
    #expect(AgentIndicator(enabled: false, creator: nil, access: .operate) == nil)
  }

  @Test func nothingShowsForAVMThatIsntShared() {
    #expect(AgentIndicator(enabled: true, creator: nil, access: .none) == nil)
  }

  @Test func aSharedVMShowsItsLevel() {
    let indicator = AgentIndicator(enabled: true, creator: nil, access: .operate)

    #expect(indicator == .shared(.operate))
    #expect(indicator?.help == "Shared with AI agents: Operate")
  }

  @Test func aVMAnAgentCreatedIsMarkedAsSuchEvenWhenAlsoShared() {
    let indicator = AgentIndicator(enabled: true, creator: entry(client: "claude-code"), access: .read)

    #expect(indicator == .createdByAgent(client: "claude-code"))
    #expect(indicator?.help == "Created by claude-code, which fully controls it")
    #expect(
      AgentIndicator(enabled: true, creator: entry(client: nil), access: .none)?.help
        == "Created by an agent, which fully controls it")
  }
}
