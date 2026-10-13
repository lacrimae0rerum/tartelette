import Foundation
import Testing

@testable import TarteletteAgents

@Suite("Agent VM registry")
struct AgentVMRegistryTests {
  private static func entry(_ name: String, fingerprint: String = "1:2:3.4") -> AgentVMEntry {
    AgentVMEntry(
      name: name, source: "base", client: "test-client",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000), fingerprint: fingerprint)
  }

  private static func registry(in directory: TemporaryDirectory) -> AgentVMRegistry {
    let paths = AgentPaths(applicationSupport: directory.file("support"), logs: directory.file("logs"))
    return AgentVMRegistry(paths: paths)
  }

  @Test func missingFileIsAnEmptyList() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    #expect(try Self.registry(in: directory).entries().isEmpty)
  }

  @Test func malformedFileThrows() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let registry = Self.registry(in: directory)
    try FileManager.default.createDirectory(at: directory.file("support"), withIntermediateDirectories: true)
    try Data(#"{"version":1,"vms":"oops"}"#.utf8).write(to: registry.file)

    #expect(throws: AgentStoreError.self) { try registry.entries() }
    #expect(throws: AgentStoreError.self) { try registry.register(Self.entry("dev")) }
  }

  @Test func registersAndPersistsEntries() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let registry = Self.registry(in: directory)

    try registry.register(Self.entry("sandbox-1"))
    try registry.register(Self.entry("sandbox-2"))

    #expect(try registry.entries() == [Self.entry("sandbox-1"), Self.entry("sandbox-2")])
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: registry.file)) as? [String: Any]
    #expect(object?["version"] as? Int == 1)
    let first = (object?["vms"] as? [[String: Any]])?.first
    #expect(first?["createdAt"] as? String == "2027-01-15T08:00:00Z")
  }

  @Test func registeringAnExistingNameReplacesTheEntry() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let registry = Self.registry(in: directory)

    try registry.register(Self.entry("sandbox", fingerprint: "old"))
    try registry.register(Self.entry("sandbox", fingerprint: "new"))

    #expect(try registry.entries() == [Self.entry("sandbox", fingerprint: "new")])
  }

  @Test func unregistersByName() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let registry = Self.registry(in: directory)
    try registry.register(Self.entry("a"))
    try registry.register(Self.entry("b"))

    try registry.unregister(name: "a")
    try registry.unregister(name: "missing")

    #expect(try registry.entries().map(\.name) == ["b"])
  }

  @Test func pruneKeepsOnlyExistingVMs() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let registry = Self.registry(in: directory)
    for name in ["a", "b", "c"] { try registry.register(Self.entry(name)) }

    try registry.prune(keeping: ["a", "c", "unrelated"])

    #expect(try registry.entries().map(\.name) == ["a", "c"])
  }

  @Test func concurrentWritersLoseNothing() async throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let registry = Self.registry(in: directory)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for writer in ["left", "right"] {
        group.addTask {
          for index in 0..<20 { try registry.register(Self.entry("\(writer)-\(index)")) }
        }
      }
      try await group.waitForAll()
    }

    let names = Set(try registry.entries().map(\.name))
    #expect(names.count == 40)
    #expect(names.contains("left-19") && names.contains("right-0"))
  }
}
