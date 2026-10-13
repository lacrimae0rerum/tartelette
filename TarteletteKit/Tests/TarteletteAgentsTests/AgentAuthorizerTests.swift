import Foundation
import Testing

@testable import TarteletteAgents

@Suite("Agent authorizer")
struct AgentAuthorizerTests {
  private static let fingerprint = "16777230:4242:1800000000.5"

  private static func authorizer(
    enabled: Bool = true,
    vms: [String: AgentAccess] = [:],
    owned: [String] = []
  ) -> AgentAuthorizer {
    let entries = owned.map {
      AgentVMEntry(name: $0, source: "base", client: nil, createdAt: Date(), fingerprint: fingerprint)
    }
    return AgentAuthorizer(policy: AgentPolicy(enabled: enabled, vms: vms), registry: entries)
  }

  /// The operations the authorizer allows for one VM.
  private static func allowed(_ authorizer: AgentAuthorizer, _ name: String, fingerprint: String? = fingerprint)
    -> Set<AgentOperation>
  {
    Set(AgentOperation.allCases.filter { (try? authorizer.check($0, vm: name, fingerprint: fingerprint)) != nil })
  }

  @Test func disabledPolicyDeniesEverything() {
    let authorizer = Self.authorizer(enabled: false, vms: ["dev": .operate], owned: ["mine"])
    #expect(Self.allowed(authorizer, "dev").isEmpty)
    #expect(Self.allowed(authorizer, "mine").isEmpty)
    #expect(throws: AgentDenial.agentsDisabled) { try authorizer.check(.inspect, vm: "dev", fingerprint: nil) }
    #expect(authorizer.visibleAccess(for: ["dev", "mine"], fingerprints: ["mine": Self.fingerprint]).isEmpty)
  }

  @Test func noneDeniesEverythingAndHidesTheVM() {
    let authorizer = Self.authorizer(vms: ["secret": .none, "dev": .read])
    #expect(Self.allowed(authorizer, "secret").isEmpty)
    #expect(Self.allowed(authorizer, "unlisted").isEmpty)
    #expect(authorizer.visibleAccess(for: ["secret", "unlisted", "dev"], fingerprints: [:]) == ["dev": .read])
  }

  @Test func readAllowsOnlyInspect() {
    #expect(Self.allowed(Self.authorizer(vms: ["dev": .read]), "dev") == [.inspect])
  }

  @Test func operateAllowsRunningCommandsAndFiles() {
    #expect(
      Self.allowed(Self.authorizer(vms: ["dev": .operate]), "dev")
        == [.inspect, .start, .stop, .exec, .readFile, .writeFile])
  }

  @Test func templateAllowsInspectAndClone() {
    #expect(Self.allowed(Self.authorizer(vms: ["base": .template]), "base") == [.inspect, .cloneFrom])
  }

  @Test func ownedVMsAllowEverythingButCloning() {
    let authorizer = Self.authorizer(owned: ["sandbox"])
    #expect(
      Self.allowed(authorizer, "sandbox")
        == [.inspect, .start, .stop, .exec, .readFile, .writeFile, .delete])
    #expect(authorizer.visibleAccess(for: ["sandbox"], fingerprints: ["sandbox": Self.fingerprint]) == ["sandbox": .owned])
  }

  @Test func deleteIsAllowedOnlyForOwnedVMs() {
    let authorizer = Self.authorizer(vms: ["dev": .operate, "base": .template, "logs": .read])
    for name in ["dev", "base", "logs", "unlisted"] {
      #expect(throws: AgentDenial.notOwned(vm: name)) { try authorizer.check(.delete, vm: name, fingerprint: Self.fingerprint) }
    }
  }

  @Test func ownedVMWithStaleFingerprintFallsBackToThePolicyLevel() {
    let authorizer = Self.authorizer(vms: ["sandbox": .read], owned: ["sandbox"])
    #expect(Self.allowed(authorizer, "sandbox", fingerprint: "recreated") == [.inspect])
    #expect(Self.allowed(authorizer, "sandbox", fingerprint: nil) == [.inspect])
    #expect(authorizer.visibleAccess(for: ["sandbox"], fingerprints: ["sandbox": "recreated"]) == ["sandbox": .read])

    let unshared = Self.authorizer(owned: ["sandbox"])
    #expect(Self.allowed(unshared, "sandbox", fingerprint: "recreated").isEmpty)
    #expect(unshared.visibleAccess(for: ["sandbox"], fingerprints: ["sandbox": "recreated"]).isEmpty)
  }

  @Test func denialsTellTheUserWhatToChange() {
    let authorizer = Self.authorizer(vms: ["logs": .read, "dev": .operate], owned: ["sandbox"])

    #expect(
      AgentDenial.agentsDisabled.localizedDescription
        == "Agent access is turned off. Turn it on in Tartelette › Settings › Agents.")
    #expect(
      Self.denial(authorizer, .start, "hidden")
        == "VM “hidden” isn't shared with agents. In Tartelette, set its agent access to Operate.")
    #expect(
      Self.denial(authorizer, .inspect, "hidden")
        == "VM “hidden” isn't shared with agents. In Tartelette, set its agent access to Read.")
    #expect(
      Self.denial(authorizer, .exec, "logs")
        == "VM “logs” is shared with agents as Read, which doesn't allow running commands in it. In Tartelette, set its agent access to Operate.")
    #expect(
      Self.denial(authorizer, .cloneFrom, "dev")
        == "VM “dev” is shared with agents as Operate, which doesn't allow cloning it. In Tartelette, set its agent access to Template.")
    #expect(
      Self.denial(authorizer, .delete, "dev")
        == "Agents can only delete VMs they created; “dev” wasn't created by an agent.")
    #expect(
      Self.denial(authorizer, .cloneFrom, "sandbox")
        == "VM “sandbox” was created by an agent, and agents can't clone VMs they created. Clone from a VM shared as Template instead.")
  }

  private static func denial(_ authorizer: AgentAuthorizer, _ operation: AgentOperation, _ name: String) -> String? {
    do {
      try authorizer.check(operation, vm: name, fingerprint: fingerprint)
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}
