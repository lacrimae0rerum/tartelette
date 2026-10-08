import Foundation
import Testing

@testable import TarteletteCore

@Suite("Tart output parsing")
struct TartOutputParsingTests {
  @Test func parsesListWithUnstableKeyOrderAndNulls() throws {
    let json = """
      [
        { "Disk" : 20, "Name" : "dev", "Source" : "local", "Running" : false,
          "Accessed" : "2026-10-08T15:23:25Z", "Size" : 3, "State" : "suspended" },
        { "State" : "stopped", "Source" : "OCI", "Running" : false, "Size" : 25,
          "Disk" : null, "Name" : "ghcr.io/cirruslabs/ubuntu:latest", "Accessed" : "2026-10-01T00:00:00Z" }
      ]
      """
    let rows = try TartOutputParsing.parseList(Data(json.utf8))
    #expect(rows.count == 2)
    #expect(rows[0].name == "dev")
    #expect(rows[0].source == .local)
    #expect(rows[0].state == .suspended)
    #expect(rows[0].diskGB == 20)
    #expect(rows[0].lastAccessed != nil)
    #expect(rows[1].source == .oci)
    #expect(rows[1].diskGB == nil)
  }

  @Test func parsesEmptyList() throws {
    #expect(try TartOutputParsing.parseList(Data("[\n\n]\n".utf8)).isEmpty)
  }

  @Test func parsesDetailsWithStringSize() throws {
    let json = """
      { "CPU" : 4, "Disk" : 20, "OS" : "linux", "Running" : true, "Display" : "1024x768",
        "DiskFormat" : "raw", "State" : "running", "Size" : "1.250", "Memory" : 4096 }
      """
    let details = try TartOutputParsing.parseDetails(Data(json.utf8))
    #expect(details.os == .linux)
    #expect(details.cpuCount == 4)
    #expect(details.memoryMB == 4096)
    #expect(details.sizeGB == 1.25)
    #expect(details.state == .running)
  }

  @Test func parsesConfigFile() throws {
    let json = """
      { "arch" : "arm64", "cpuCount" : 4, "cpuCountMin" : 4, "diskFormat" : "raw",
        "display" : { "height" : 768, "width" : 1024 }, "macAddress" : "6e:ea:20:d0:59:75",
        "memorySize" : 4294967296, "memorySizeMin" : 4294967296, "os" : "linux", "version" : 1 }
      """
    let config = try TartOutputParsing.parseConfig(Data(json.utf8))
    #expect(config.operatingSystem == .linux)
    #expect(config.display?.width == 1024)
    #expect(config.displayRefit == nil)
    #expect(config.macAddress == "6e:ea:20:d0:59:75")
  }

  @Test func parsesIPAndURLs() {
    #expect(TartOutputParsing.parseIP("192.168.64.5\n") == "192.168.64.5")
    #expect(TartOutputParsing.parseIP("no IP address found") == nil)
    #expect(
      TartOutputParsing.parseVNCURL("VNC server is running at vnc://:a-b-c-d@127.0.0.1:5901")?.absoluteString
        == "vnc://:a-b-c-d@127.0.0.1:5901")
    #expect(TartOutputParsing.parseVNCURL("Opening vnc://192.168.64.3...")?.absoluteString == "vnc://192.168.64.3")
    #expect(TartOutputParsing.parseSerialDevice("Successfully open pty /dev/ttys004") == "/dev/ttys004")
  }

  @Test func parsesBridgedInterfaces() {
    let output = #"Error: no bridge interfaces matched "["list"]", available interfaces: ["en0 (or \"Ethernet\")", "en1 (or \"Wi-Fi\")", "bridge0"]"#
    let interfaces = TartOutputParsing.parseBridgedInterfaces(output)
    #expect(interfaces.map(\.bsdName) == ["en0", "en1", "bridge0"])
    #expect(interfaces.first?.displayName == "Ethernet")
  }

  @Test func progressParserHandlesPlainAndANSI() {
    var parser = TartProgressParser()
    #expect(parser.consume(line: "pulling disk (12.3 GB compressed)...") == .status("pulling disk (12.3 GB compressed)..."))
    #expect(parser.consume(line: "0%") == .progress(0))
    #expect(parser.consume(line: "\u{1B}[1A\r\u{1B}[J37%") == .progress(0.37))
    #expect(parser.fraction == 0.37)
    #expect(parser.consume(line: "") == nil)
    #expect(parser.consume(line: "pulling NVRAM...") == .status("pulling NVRAM..."))
    #expect(parser.fraction == nil)
  }

  @Test func catalogHasRecommendedImages() {
    #expect(ImageCatalog.images.contains { $0.reference == "ghcr.io/cirruslabs/macos-tahoe-base:latest" })
    #expect(ImageCatalog.images.first { $0.flavor == .vanilla }?.hasGuestAgent == false)
    #expect(!ImageCatalog.recommended.isEmpty)
  }
}
