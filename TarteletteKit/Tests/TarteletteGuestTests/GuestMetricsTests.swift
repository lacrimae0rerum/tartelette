import Foundation
import TarteletteCore
import Testing

@testable import TarteletteGuest

@Suite("Guest metrics parsing")
struct GuestMetricsTests {
  /// Recorded on a macOS 26 host with the collector's macOS script.
  static let macOSOutput = """
    loadavg={ 7.48 5.31 4.42 }
    memsize=51539607552
    boottime={ sec = 1790538964, usec = 326546 } Sun Sep 27 21:56:04 2026
    now=1791474092
    vm:Mach Virtual Memory Statistics: (page size of 16384 bytes)
    vm:Pages free:                                   215634.
    vm:Pages active:                                1155569.
    vm:Pages inactive:                              1161569.
    vm:Pages speculative:                              2265.
    vm:Pages wired down:                             396629.
    vm:Pages purgeable:                               14122.
    vm:"Translation faults":                     7793690850.
    vm:File-backed pages:                            626043.
    vm:Anonymous pages:                             1693360.
    vm:Pages stored in compressor:                  1344348.
    vm:Pages occupied by compressor:                 150105.
    top:CPU usage: 17.88% user, 7.11% sys, 75.0% idle
    df:/dev/disk3s5  1948404040 1130305736 776948804    60% 5820105 7769488040    0%   /System/Volumes/Data
    procs=1053
    """

  static let linuxOutput = """
    loadavg=0.52 0.31 0.25 2/187 4521
    mem:MemTotal:        4005284 kB
    mem:MemAvailable:    3126732 kB
    stat1:cpu  1000 0 500 8000 100 0 20 0 0 0
    stat2:cpu  1060 0 530 8100 110 0 20 0 0 0
    df:/dev/vda1       20134592 4128796 15989412  21% /
    uptime=3605.42
    procs=142
    """

  @Test func parsesMacOSSample() {
    let sample = GuestMetricsCollector.parseMacOS(Self.macOSOutput)
    #expect(sample.loadAverage == [7.48, 5.31, 4.42])
    #expect(sample.memoryTotalBytes == 51_539_607_552)
    #expect(sample.memoryUsedBytes == UInt64(1_693_360 - 14_122 + 396_629 + 150_105) * 16_384)
    #expect(sample.cpuPercent == 25)
    #expect(sample.diskTotalBytes == 1_948_404_040 * 1024)
    #expect(sample.diskUsedBytes == (1_948_404_040 - 776_948_804) * 1024)
    #expect(sample.uptimeSeconds == Double(1_791_474_092 - 1_790_538_964))
    #expect(sample.processCount == 1053)
  }

  @Test func parsesLinuxSample() throws {
    let sample = GuestMetricsCollector.parseLinux(Self.linuxOutput)
    #expect(sample.loadAverage == [0.52, 0.31, 0.25])
    #expect(sample.memoryTotalBytes == 4_005_284 * 1024)
    #expect(sample.memoryUsedBytes == (4_005_284 - 3_126_732) * 1024)
    // Δtotal = 90 + 30 + 100 + 10 = 200 ticks, Δidle (idle + iowait) = 110 → 45 % busy.
    let cpu = try #require(sample.cpuPercent)
    #expect(abs(cpu - 45) < 0.001)
    #expect(sample.diskTotalBytes == 20_134_592 * 1024)
    #expect(sample.diskUsedBytes == (20_134_592 - 15_989_412) * 1024)
    #expect(sample.uptimeSeconds == 3605.42)
    #expect(sample.processCount == 142)
  }

  @Test func extremeGuestNumbersYieldNilInsteadOfTrapping() {
    let huge = String(UInt64.max)
    let macOS = """
      memsize=\(huge)
      vm:Mach Virtual Memory Statistics: (page size of 16384 bytes)
      vm:Pages wired down:                \(huge).
      vm:Anonymous pages:                 \(huge).
      vm:Pages occupied by compressor:    10.
      df:/dev/disk3s5  \(huge) 1 \(huge)    1% 1 1    0%   /
      """
    let mac = GuestMetricsCollector.parseMacOS(macOS)
    #expect(mac.memoryUsedBytes == nil)
    #expect(mac.diskTotalBytes == nil)
    #expect(mac.diskUsedBytes == nil)

    let linuxOutput = """
      mem:MemTotal:        \(huge) kB
      mem:MemAvailable:    1 kB
      stat1:cpu  \(huge) \(huge) 0 0 0
      stat2:cpu  \(huge) \(huge) 0 0 0
      df:/dev/vda1       \(huge) 1 \(huge)  1% /
      """
    let linux = GuestMetricsCollector.parseLinux(linuxOutput)
    #expect(linux.memoryTotalBytes == nil)
    #expect(linux.memoryUsedBytes == nil)
    #expect(linux.cpuPercent == nil)
    #expect(linux.diskTotalBytes == nil)
  }

  @Test func toleratesMissingRecords() {
    let sample = GuestMetricsCollector.parseMacOS("loadavg={ 1.0 2.0 3.0 }\n")
    #expect(sample.loadAverage == [1, 2, 3])
    #expect(sample.memoryUsedBytes == nil)
    #expect(sample.cpuPercent == nil)
  }

  @Test func collectsFromThisMac() async throws {
    let endpoint = GuestEndpoint(vmName: "local", os: .macOS, transport: LocalTransport())
    let sample = try await GuestMetricsCollector.sample(endpoint, timeout: .seconds(20))
    #expect((sample.memoryTotalBytes ?? 0) > 0)
    #expect((sample.memoryUsedBytes ?? 0) > 0)
    #expect(sample.cpuPercent != nil)
    #expect((sample.diskTotalBytes ?? 0) > (sample.diskUsedBytes ?? 0))
    #expect((sample.uptimeSeconds ?? 0) > 0)
    #expect((sample.processCount ?? 0) > 10)
    #expect(sample.loadAverage.count == 3)
  }
}
