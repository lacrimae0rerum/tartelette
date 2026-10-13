import Foundation
import Testing

@testable import TarteletteAgents

@Suite("Agent paths")
struct AgentPathsTests {
  @Test func derivesFilesFromInjectedDirectories() {
    let paths = AgentPaths(
      applicationSupport: URL(fileURLWithPath: "/tmp/support", isDirectory: true),
      logs: URL(fileURLWithPath: "/tmp/logs", isDirectory: true))
    #expect(paths.policyFile.path == "/tmp/support/agents.json")
    #expect(paths.registryFile.path == "/tmp/support/agent-vms.json")
    #expect(paths.registryLockFile.path == "/tmp/support/agent-vms.lock")
    #expect(paths.auditLogFile.path == "/tmp/logs/agents.log")
  }

  @Test func standardPathsLiveInTheUserLibrary() {
    let paths = AgentPaths.standard
    #expect(paths.applicationSupport.path.hasSuffix("/Library/Application Support/Tartelette"))
    #expect(paths.logs.path.hasSuffix("/Library/Logs/Tartelette"))
  }
}

@Suite("Agent access levels")
struct AgentAccessTests {
  @Test func decodesKnownLevels() throws {
    let data = Data(#"["none","read","operate","template"]"#.utf8)
    let levels = try JSONDecoder().decode([AgentAccess].self, from: data)
    #expect(levels == [AgentAccess.none, .read, .operate, .template])
  }

  @Test func unknownLevelDecodesAsNone() throws {
    let data = Data(#"["owner","Operate",""]"#.utf8)
    let levels = try JSONDecoder().decode([AgentAccess].self, from: data)
    #expect(levels == [AgentAccess.none, AgentAccess.none, AgentAccess.none])
  }

  @Test func encodesLowercaseStrings() throws {
    let data = try JSONEncoder().encode([AgentAccess.operate, .template])
    #expect(String(decoding: data, as: UTF8.self) == #"["operate","template"]"#)
  }
}

@Suite("Agent limits")
struct AgentLimitsTests {
  @Test func defaults() {
    let limits = AgentLimits()
    #expect(limits.execTimeoutDefaultSeconds == 120)
    #expect(limits.execTimeoutMaxSeconds == 1800)
    #expect(limits.maxOutputBytes == 262_144)
    #expect(limits.maxFileBytes == 52_428_800)
    #expect(limits.maxAgentVMs == 4)
  }

  @Test func missingKeysTakeDefaults() throws {
    let limits = try JSONDecoder().decode(AgentLimits.self, from: Data(#"{"maxAgentVMs":2}"#.utf8))
    #expect(limits == AgentLimits(maxAgentVMs: 2))
    #expect(limits.execTimeoutMaxSeconds == 1800)
  }

  @Test func nonPositiveValuesFallBackToDefaults() throws {
    let json = #"""
      {"execTimeoutDefaultSeconds":0,"execTimeoutMaxSeconds":-5,"maxOutputBytes":0,
       "maxFileBytes":-1,"maxAgentVMs":0}
      """#
    let limits = try JSONDecoder().decode(AgentLimits.self, from: Data(json.utf8))
    #expect(limits == AgentLimits())
  }

  @Test func defaultTimeoutIsClampedToTheMaximum() throws {
    let json = #"{"execTimeoutDefaultSeconds":600,"execTimeoutMaxSeconds":300}"#
    let limits = try JSONDecoder().decode(AgentLimits.self, from: Data(json.utf8))
    #expect(limits.execTimeoutDefaultSeconds == 300)
    #expect(limits.execTimeoutMaxSeconds == 300)
    #expect(AgentLimits(execTimeoutDefaultSeconds: 5000).execTimeoutDefaultSeconds == 1800)
  }
}

@Suite("Agent policy")
struct AgentPolicyTests {
  @Test func defaultPolicyIsDisabledAndEmpty() {
    #expect(AgentPolicy.default.version == 1)
    #expect(AgentPolicy.default.enabled == false)
    #expect(AgentPolicy.default.vms.isEmpty)
    #expect(AgentPolicy.default.limits == AgentLimits())
  }

  @Test func absentVMHasNoAccess() {
    let policy = AgentPolicy(enabled: true, vms: ["dev": .operate])
    #expect(policy.access(for: "dev") == .operate)
    #expect(policy.access(for: "other") == AgentAccess.none)
  }

  @Test func missingKeysTakeDefaults() throws {
    let policy = try JSONDecoder().decode(AgentPolicy.self, from: Data(#"{"vms":{"dev":"read"}}"#.utf8))
    #expect(policy == AgentPolicy(enabled: false, vms: ["dev": .read]))
  }
}

@Suite("Agent policy store")
struct AgentPolicyStoreTests {
  @Test func missingFileLoadsTheDefaultPolicy() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let store = AgentPolicyStore(file: directory.file("agents.json"))
    #expect(try store.load() == .default)
  }

  @Test func malformedFileThrows() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let file = directory.file("agents.json")
    try Data("{ not json".utf8).write(to: file)
    #expect(throws: AgentStoreError.self) { try AgentPolicyStore(file: file).load() }
  }

  @Test func unreadableFileThrows() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    // A directory in place of the file can't be read as data.
    let file = directory.file("agents.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    #expect(throws: AgentStoreError.self) { try AgentPolicyStore(file: file).load() }
  }

  @Test func saveCreatesTheDirectoryAndRoundTrips() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let file = directory.file("nested/Tartelette/agents.json")
    let store = AgentPolicyStore(file: file)
    let policy = AgentPolicy(
      enabled: true, vms: ["dev": .operate, "base": .template],
      limits: AgentLimits(execTimeoutDefaultSeconds: 60, maxAgentVMs: 2))

    try store.save(policy)

    #expect(try store.load() == policy)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("\n"))
    #expect(text.range(of: "\"enabled\"")!.lowerBound < text.range(of: "\"limits\"")!.lowerBound)
  }
}
