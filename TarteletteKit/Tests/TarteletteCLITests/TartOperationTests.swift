import Foundation
import TarteletteCore
import Testing

@testable import TarteletteCLI

@Suite("Streaming operations and VM processes")
struct TartOperationTests {
  @Test func streamsStatusProgressAndCompletion() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    let operation = fake.client.stream(.pull(PullOptions(remoteName: "ghcr.io/org/img:latest")))

    var events: [TartOperation.Event] = []
    for await event in operation.events { events.append(event) }

    guard case .started(let pid) = events.first else {
      Issue.record("first event should be .started, got \(String(describing: events.first))")
      return
    }
    #expect(pid > 0)
    #expect(events.contains(.status("pulling disk (1.2 GB compressed)...")))
    let progress = events.compactMap { event -> Double? in
      if case .progress(let value) = event { value } else { nil }
    }
    #expect(progress == [0, 0.5, 1.0])
    #expect(events.contains(.line("warning: slow network", isError: true)))
    #expect(events.last == .finished(exitCode: 0, message: nil))
    #expect(!events.contains { if case .line(let text, _) = $0 { text.hasSuffix("%") } else { false } })
  }

  @Test func cancelSendsSIGINTSoTartCanCleanUp() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    let operation = fake.client.stream(.push(PushOptions(localName: "dev", remoteNames: ["ghcr.io/me/dev:1"])))

    var lines: [String] = []
    var finished: TartOperation.Event?
    for await event in operation.events {
      switch event {
      case .status(let line):
        lines.append(line)
        if line.hasPrefix("pushing disk") { operation.cancel() }
      case .finished:
        finished = event
      default:
        break
      }
    }
    #expect(lines.contains("interrupted by SIGINT"))
    #expect(!lines.contains("not interrupted"))
    #expect(finished == .finished(exitCode: 130, message: "Cancelled."))
  }

  @Test func failedOperationsCarryCleanedMessage() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    let result = await fake.client.stream(.rename(name: "a", newName: "b")).result()
    #expect(result.exitCode == 64)
    #expect(result.message == "failed to rename VM a, target VM b already exists, delete it first!")
  }

  @Test func launchFailureFinishesTheStream() async throws {
    let environment = TartEnvironment(executable: URL(fileURLWithPath: "/nonexistent/tart"))
    let result = await TartClient(environment: environment).stream(.version).result()
    #expect(result.exitCode == -1)
    #expect(result.message?.contains("/nonexistent/tart") == true)
  }

  @Test func launchDetachesTheVMAndLogsItsOutput() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    let logFile = fake.directory.appendingPathComponent("logs/dev.log")

    let process = try fake.client.launch(RunOptions(name: "dev", display: .headless), logFile: logFile)
    #expect(process.pid > 0)
    #expect(process.vmName == "dev")
    #expect(process.isRunning)
    #expect(getsid(process.pid) == process.pid, "tart run should lead its own session")

    let exitCode = await process.waitForExit()
    #expect(exitCode == 0)
    #expect(process.exitCode == 0)
    #expect(await process.waitForExit() == 0)

    let log = try String(contentsOf: logFile, encoding: .utf8)
    #expect(log.contains("tart run dev --no-graphics"))
    #expect(log.contains("booting dev"))
    #expect(log.contains("warning on stderr"))
    #expect(log.contains("guest has stopped the virtual machine"))
    #expect(fake.recordedEnvironment("run")["CI"] == nil)
    #expect(fake.recorded("args-run.txt") == "run\ndev\n--no-graphics\n")
  }

  @Test func decodesWaitStatuses() {
    #expect(RunningVMProcess.decodeWaitStatus(0) == 0)
    #expect(RunningVMProcess.decodeWaitStatus(3 << 8) == 3)
    #expect(RunningVMProcess.decodeWaitStatus(SIGKILL) == 128 + SIGKILL)
  }
}
