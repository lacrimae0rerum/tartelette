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

    // A child process takes an fcntl write lock (as `tart run` does) and holds it briefly.
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    holder.arguments = [
      "-c",
      "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(5)",
      file.path,
    ]
    let output = Pipe()
    holder.standardOutput = output
    try holder.run()
    defer { holder.terminate() }
    _ = output.fileHandleForReading.availableData  // wait for "locked"

    #expect(VMLock.holderPID(configFile: file) == holder.processIdentifier)
  }

  @Test func resolvesTartHome() {
    let custom = TartPaths.resolve(environment: ["TART_HOME": "/tmp/tart-home"])
    #expect(custom.vms.path == "/tmp/tart-home/vms")
    #expect(custom.configFile("dev").path == "/tmp/tart-home/vms/dev/config.json")
    #expect(TartPaths.resolve(environment: [:]).home.lastPathComponent == ".tart")
  }
}
