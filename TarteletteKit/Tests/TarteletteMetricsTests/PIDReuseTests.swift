import Foundation
import TarteletteCore
import Testing

@testable import TarteletteMetrics

@Suite("PID reuse")
struct PIDReuseTests {
  @Test func resolverRescansWhenACachedPIDIsReusedByAnotherProcess() async throws {
    let home = try TemporaryTartHome(vms: ["demo"])
    defer { home.remove() }
    let table = FakeProcessTable([
      9001: .init(path: virtualizationServicePath, openFiles: [home.paths.diskImage("demo").path], startTime: 1_000)
    ])
    let resolver = VMProcessResolver(paths: home.paths, table: table, lockHolder: { _ in 4242 })
    #expect(resolver.processes(forVM: "demo")?.virtualMachinePIDs == [9001])

    // The XPC service exits and the kernel hands pid 9001 to an unrelated, still-running process.
    table.replace(9001, with: .init(path: "/usr/bin/unrelated", openFiles: [], startTime: 2_000))
    #expect(resolver.processes(forVM: "demo")?.virtualMachinePIDs == [])

    // Same executable path but a different process instance (new start time) isn't trusted either.
    table.replace(9001, with: .init(path: virtualizationServicePath, openFiles: [], startTime: 3_000))
    #expect(resolver.processes(forVM: "demo")?.virtualMachinePIDs == [])
  }

  @Test func samplerIgnoresDeltasAcrossAReusedPIDWithHigherCounters() async throws {
    let home = try TemporaryTartHome(vms: ["vm"])
    defer { home.remove() }
    let table = FakeProcessTable([
      100: .init(
        path: "/opt/homebrew/bin/tart",
        usages: [usage(100, atSeconds: 10, cpuSeconds: 1), usage(100, atSeconds: 11, cpuSeconds: 1.5)],
        startTime: 10),
      200: .init(
        path: virtualizationServicePath, openFiles: [home.paths.diskImage("vm").path],
        usages: [usage(200, atSeconds: 10, cpuSeconds: 5, read: 1_000)], startTime: 20),
    ])
    let sampler = VMMetricsSampler(
      resolver: VMProcessResolver(paths: home.paths, table: table, lockHolder: { _ in 100 }), table: table)
    _ = await sampler.sample(vms: ["vm"])

    // Pid 200 now belongs to a new process whose cumulative counters are much higher.
    table.replace(
      200,
      with: .init(
        path: virtualizationServicePath, openFiles: [home.paths.diskImage("vm").path],
        usages: [usage(200, atSeconds: 11, cpuSeconds: 500, read: 9_000_000_000)], startTime: 99))
    let sample = try #require(await sampler.sample(vms: ["vm"])["vm"])
    // Only the tart process contributes a rate this round: 0.5 s of CPU over 1 s.
    #expect(abs(sample.guestCPUPercent) < 0.0001)
    #expect(abs(sample.tartCPUPercent - 50) < 0.0001)
    #expect(sample.diskReadBytesPerSecond == 0)
  }
}
