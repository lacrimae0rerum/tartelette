import Foundation
import Testing

@testable import TarteletteCore

@Suite("VM lock inspection")
struct VMLockTests {
  @Test func reportsNoHolderForUnlockedFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-lock-\(UUID()).json")
    try Data("{}".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(VMLock.holderPID(configFile: file) == nil)
  }

  @Test func reportsHolderPIDOfAnotherProcess() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-lock-\(UUID()).json")
    try Data("{}".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    // A child process takes an fcntl write lock (as `tart run` does) and holds it.
    let holder = try FcntlLockHolder(file: file)
    defer { holder.stop() }

    #expect(VMLock.holderPID(configFile: file) == holder.pid)

    holder.stop()
    #expect(VMLock.holderPID(configFile: file) == nil)
  }

  @Test func resolvesTartHome() {
    let custom = TartPaths.resolve(environment: ["TART_HOME": "/tmp/tart-home"])
    #expect(custom.vms.path == "/tmp/tart-home/vms")
    #expect(custom.configFile("dev").path == "/tmp/tart-home/vms/dev/config.json")
    #expect(TartPaths.resolve(environment: [:]).home.lastPathComponent == ".tart")
  }
}
