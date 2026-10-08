import Foundation
import TarteletteCore
import Testing

@testable import TarteletteCLI

@Suite("Process runner")
struct ProcessRunnerTests {
  let runner = ProcessRunner()

  private func shell(_ script: String, stdin: Data? = nil, timeout: Duration? = nil) -> ProcessRequest {
    ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], standardInput: stdin, timeout: timeout)
  }

  @Test func drainsLargeStdoutAndStderrConcurrently() async throws {
    let output = try await runner.run(
      shell("head -c 2000000 /dev/zero | tr '\\0' a; head -c 1000000 /dev/zero | tr '\\0' e >&2"))
    #expect(output.status == 0)
    #expect(output.stdout.count == 2_000_000)
    #expect(output.stderr.count == 1_000_000)
  }

  @Test func roundTripsStandardInput() async throws {
    let payload = Data((0..<300_000).map { UInt8($0 % 251) })
    let output = try await runner.run(
      ProcessRequest(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: payload))
    #expect(output.stdout == payload)
  }

  @Test func childIgnoringStdinDoesNotCrashTheHost() async throws {
    let output = try await runner.run(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
        standardInput: Data(count: 2_000_000)))
    #expect(output.status == 0)
  }

  @Test func reportsNonZeroStatusWithoutThrowing() async throws {
    let output = try await runner.run(shell("echo oops >&2; exit 3"))
    #expect(output.status == 3)
    #expect(output.stderrString == "oops\n")
    #expect(output.diagnostic == "oops")
  }

  @Test func passesEnvironmentOverrides() async throws {
    let output = try await runner.run(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf %s \"$TARTELETTE_TEST\""],
        environment: ["TARTELETTE_TEST": "hello"]))
    #expect(output.stdoutString == "hello")
  }

  @Test func timesOut() async throws {
    let start = Date()
    await #expect(throws: ProcessRunError.timedOut(after: .milliseconds(300))) {
      try await runner.run(
        ProcessRequest(
          executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: .milliseconds(300)))
    }
    #expect(Date().timeIntervalSince(start) < 5)
  }

  @Test func honoursTaskCancellation() async throws {
    let runner = self.runner
    let task = Task {
      try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]))
    }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await #expect(throws: ProcessRunError.cancelled) { try await task.value }
  }

  @Test func reportsLaunchFailure() async throws {
    await #expect {
      try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/nonexistent/tart"), arguments: []))
    } throws: { error in
      guard case ProcessRunError.launchFailed(let reason) = error else { return false }
      return reason.contains("does not exist")
    }
  }

  @Test func lineSplitterHandlesPartialLinesAndRedraws() {
    var splitter = LineSplitter()
    #expect(splitter.append(Data("pull".utf8)).isEmpty)
    #expect(splitter.append(Data("ing...\n0%\n\u{1B}[1A\r\u{1B}[J37%\nhalf".utf8)) == ["pulling...", "0%", "37%"])
    #expect(splitter.append(Data("way\r\n".utf8)) == ["halfway"])
    #expect(splitter.append(Data("tail".utf8)).isEmpty)
    #expect(splitter.flush() == ["tail"])
    #expect(splitter.flush().isEmpty)
  }
}
