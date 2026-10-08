import Foundation
import TarteletteCore
import Testing

@testable import TarteletteMetrics

@Suite("VM process attribution and rates")
struct VMAttributionTests {
  @Test func attributesOnlyTheXPCServiceHoldingTheVMFiles() async throws {
    let home = try TemporaryTartHome(vms: ["demo", "demo2"])
    defer { home.remove() }

    // A real child process holds the fcntl lock on config.json, like `tart run`.
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    holder.arguments = [
      "-c",
      "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(10)",
      home.paths.configFile("demo").path,
    ]
    let output = Pipe()
    holder.standardOutput = output
    try holder.run()
    defer { holder.terminate() }
    _ = output.fileHandleForReading.availableData

    let table = FakeProcessTable([
      // Uses the unresolved /var/... temp path; the kernel would report /private/var/....
      9001: .init(path: virtualizationServicePath, openFiles: ["/dev/null", home.paths.diskImage("demo").path]),
      9002: .init(
        path: virtualizationServicePath,
        openFiles: ["/Users/someone/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"]),
      9003: .init(path: virtualizationServicePath, openFiles: [home.paths.diskImage("demo2").path]),
      9004: .init(path: "/usr/bin/some-tool", openFiles: [home.paths.diskImage("demo").path]),
    ])
    let resolver = VMProcessResolver(paths: home.paths, table: table)

    let set = try #require(resolver.processes(forVM: "demo"))
    #expect(set.tartPID == holder.processIdentifier)
    #expect(set.virtualMachinePIDs == [9001])
    #expect(set.allPIDs == [holder.processIdentifier, 9001])

    // Stopped VM: nobody holds the lock.
    #expect(resolver.processes(forVM: "demo2") == nil)

    // A dead cached XPC pid triggers a rescan.
    table.remove(9001)
    #expect(resolver.processes(forVM: "demo")?.virtualMachinePIDs == [])
  }

  @Test func computesRatesAcrossGuestTartAndSoftnet() async throws {
    let home = try TemporaryTartHome(vms: ["vm"])
    defer { home.remove() }

    let table = FakeProcessTable([
      100: .init(
        path: "/opt/homebrew/Cellar/tart/2.40.1/libexec/tart.app/Contents/MacOS/tart", children: [300, 400],
        usages: [
          usage(100, atSeconds: 10, cpuSeconds: 1, footprint: 50, energyJoules: 1),
          usage(100, atSeconds: 11, cpuSeconds: 1.1, footprint: 50, energyJoules: 1.5),
          usage(100, atSeconds: 12, cpuSeconds: 1.1, footprint: 50, energyJoules: 1.5),
        ]),
      200: .init(
        path: virtualizationServicePath, openFiles: [home.paths.diskImage("vm").path],
        usages: [
          usage(200, atSeconds: 10, cpuSeconds: 5, footprint: 4_000, read: 1_000, written: 0, energyJoules: 10),
          usage(200, atSeconds: 11, cpuSeconds: 5.4, footprint: 4_100, read: 1_001_000, written: 500_000, energyJoules: 12),
          // Counter reset (restarted process with a reused pid).
          usage(200, atSeconds: 12, cpuSeconds: 0.1, footprint: 4_100, read: 0, written: 0, energyJoules: 0),
        ]),
      300: .init(
        path: "/opt/homebrew/bin/softnet",
        usages: [
          usage(300, atSeconds: 10, cpuSeconds: 0.2, footprint: 5),
          usage(300, atSeconds: 11, cpuSeconds: 0.2, footprint: 5),
          usage(300, atSeconds: 12, cpuSeconds: 0.3, footprint: 5),
        ]),
      400: .init(path: "/usr/bin/tar", usages: [usage(400, atSeconds: 10, cpuSeconds: 9, footprint: 999)]),
    ])
    let resolver = VMProcessResolver(paths: home.paths, table: table, lockHolder: { $0 == "vm" ? 100 : nil })
    let sampler = VMMetricsSampler(resolver: resolver, table: table)

    // First call primes state.
    #expect(await sampler.sample(vms: ["vm", "stopped"]).isEmpty)

    let second = try #require(await sampler.sample(vms: ["vm"])["vm"])
    #expect(abs(second.guestCPUPercent - 40) < 0.001)
    #expect(abs(second.tartCPUPercent - 10) < 0.001)
    #expect(abs(second.cpuPercent - 50) < 0.001)
    #expect(second.memoryBytes == 4_155)
    #expect(abs(second.diskReadBytesPerSecond - 1_000_000) < 0.001)
    #expect(abs(second.diskWriteBytesPerSecond - 500_000) < 0.001)
    #expect(abs((second.powerWatts ?? 0) - 2.5) < 0.001)

    let third = try #require(await sampler.sample(vms: ["vm"])["vm"])
    #expect(third.guestCPUPercent == 0)
    #expect(abs(third.tartCPUPercent - 10) < 0.001)
    #expect(third.diskReadBytesPerSecond == 0)
    #expect(third.powerWatts == 0)
  }

  @Test func omitsPowerWhenEnergyIsUnavailable() async throws {
    let home = try TemporaryTartHome(vms: ["vm"])
    defer { home.remove() }
    let table = FakeProcessTable([
      100: .init(
        path: "/usr/local/bin/tart",
        usages: [usage(100, atSeconds: 1, cpuSeconds: 0), usage(100, atSeconds: 2, cpuSeconds: 0.5)])
    ])
    let sampler = VMMetricsSampler(
      resolver: VMProcessResolver(paths: home.paths, table: table, lockHolder: { _ in 100 }), table: table)
    _ = await sampler.sample(vms: ["vm"])
    let sample = try #require(await sampler.sample(vms: ["vm"])["vm"])
    #expect(sample.powerWatts == nil)
    #expect(abs(sample.cpuPercent - 50) < 0.001)
  }
}
