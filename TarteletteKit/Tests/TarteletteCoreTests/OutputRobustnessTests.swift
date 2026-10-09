import Foundation
import Testing

@testable import TarteletteCore

@Suite("Tart output robustness")
struct OutputRobustnessTests {
  private func details(cpu: String, memory: String, disk: String = "20", size: String = "\"1.000\"") throws
    -> VMDetails
  {
    let json = """
      { "CPU" : \(cpu), "Disk" : \(disk), "OS" : "linux", "Running" : false, "Display" : "1024x768",
        "DiskFormat" : "raw", "State" : "stopped", "Size" : \(size), "Memory" : \(memory) }
      """
    return try TartOutputParsing.parseDetails(Data(json.utf8))
  }

  @Test func nonFiniteOrOutOfRangeCountsThrowInsteadOfTrapping() {
    #expect(throws: TartOutputError.self) { try details(cpu: "\"nan\"", memory: "4096") }
    #expect(throws: TartOutputError.self) { try details(cpu: "\"inf\"", memory: "4096") }
    #expect(throws: TartOutputError.self) { try details(cpu: "1e30", memory: "4096") }
    #expect(throws: TartOutputError.self) { try details(cpu: "4", memory: "-5") }
    #expect(throws: TartOutputError.self) { try details(cpu: "4", memory: "\"-inf\"") }
  }

  @Test func nonFiniteOptionalSizesBecomeUnknown() throws {
    let parsed = try details(cpu: "4", memory: "4096", disk: "\"nan\"", size: "\"inf\"")
    #expect(parsed.cpuCount == 4)
    #expect(parsed.memoryMB == 4096)
    #expect(parsed.diskGB == nil)
    #expect(parsed.sizeGB == nil)
  }

  @Test func listDropsNonFiniteSizes() throws {
    let json = #"[{ "Name": "a", "Source": "local", "State": "stopped", "Disk": "nan", "Size": "inf" }]"#
    let rows = try TartOutputParsing.parseList(Data(json.utf8))
    #expect(rows.first?.diskGB == nil)
    #expect(rows.first?.sizeGB == nil)
  }

  @Test func malformedPayloadsThrow() {
    #expect(throws: TartOutputError.self) { try TartOutputParsing.parseList(Data(#"{"Name": "a"}"#.utf8)) }
    #expect(throws: TartOutputError.self) { try TartOutputParsing.parseDetails(Data("[1, 2]".utf8)) }
    #expect(throws: (any Error).self) { try TartOutputParsing.parseDetails(Data("not json".utf8)) }
  }

  @Test func listRowsWithoutNameAreDropped() throws {
    let json =
      #"[{ "Source": "local", "State": "running" }, { "Name": "kept", "Source": "local", "State": "stopped" }]"#
    let rows = try TartOutputParsing.parseList(Data(json.utf8))
    #expect(rows.map(\.name) == ["kept"])
  }

  @Test func provisioningRejectsCommasButAllowsEqualsSigns() {
    // Tart splits --provisioning-opts on "," and then on the first "=" of each pair.
    let valid = RunOptions.Provisioning(fullName: "Ada Lovelace", username: "ada", password: "p=ss")
    #expect(valid.problem == nil)
    #expect(valid.argument == "fullName=Ada Lovelace,username=ada,password=p=ss")

    let invalid = RunOptions.Provisioning(fullName: "Lovelace, Ada", username: "ada", password: "a,b")
    #expect(invalid.problem != nil)
    // Values Tart can't parse are never emitted, so the argument is never corrupted.
    #expect(invalid.argument == "username=ada")
  }
}
