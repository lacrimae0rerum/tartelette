import Foundation
import TarteletteCore
import Testing

@testable import TarteletteMetrics

@Suite("Host, storage and history")
struct HostAndStorageTests {
  @Test func hostSampleIsSane() async throws {
    let sampler = HostMetricsSampler()
    _ = await sampler.sample()
    try await Task.sleep(for: .milliseconds(200))
    let sample = await sampler.sample()

    #expect((0...100).contains(sample.cpuPercent))
    #expect(sample.logicalCores > 0)
    #expect(sample.memoryTotalBytes > 0)
    #expect(sample.memoryUsedBytes > 0)
    #expect(sample.memoryUsedBytes <= sample.memoryTotalBytes)
    #expect(sample.memoryCompressedBytes <= sample.memoryUsedBytes)
    #expect(sample.loadAverage.count == 3)
  }

  @Test func cpuPercentHandlesWrapAndIdle() {
    let old = HostMetricsSampler.CPUTicks(user: .max - 9, system: 0, idle: 0, nice: 0)
    let new = HostMetricsSampler.CPUTicks(user: 10, system: 0, idle: 20, nice: 0)
    #expect(abs(HostMetricsSampler.cpuPercent(from: old, to: new) - 50) < 0.001)
    #expect(HostMetricsSampler.cpuPercent(from: .zero, to: .zero) == 0)
  }

  @Test func mapsPressureLevels() {
    #expect(HostMetricsSampler.memoryPressure(level: 1) == .normal)
    #expect(HostMetricsSampler.memoryPressure(level: 2) == .warning)
    #expect(HostMetricsSampler.memoryPressure(level: 4) == .critical)
    #expect(HostMetricsSampler.thermalState(.serious) == .serious)
  }

  @Test func measuresAllocatedBytesWithoutFollowingSymlinks() async throws {
    let home = try TemporaryTartHome(vms: ["demo"])
    defer { home.remove() }
    let megabyte = 1_048_576

    // Sparse 1 GB disk with 1 MB of real data.
    let disk = try FileHandle(forWritingTo: home.paths.diskImage("demo"))
    try disk.write(contentsOf: Data(repeating: 7, count: megabyte))
    try disk.truncate(atOffset: 1 << 30)
    try disk.close()

    let image = home.paths.ociCache.appendingPathComponent("ghcr.io/cirruslabs/ubuntu/sha256:abc", isDirectory: true)
    try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 2 * megabyte).write(to: image.appendingPathComponent("disk.img"))
    try FileManager.default.createSymbolicLink(
      at: home.paths.ociCache.appendingPathComponent("ghcr.io/cirruslabs/ubuntu/latest"), withDestinationURL: image)

    try FileManager.default.createDirectory(at: home.paths.ipswCache, withIntermediateDirectories: true)
    try Data(repeating: 2, count: megabyte).write(to: home.paths.ipswCache.appendingPathComponent("sha256:x.ipsw"))
    try FileManager.default.createDirectory(at: home.paths.temporary, withIntermediateDirectories: true)
    try Data(repeating: 3, count: megabyte).write(to: home.paths.temporary.appendingPathComponent("junk"))

    let usage = await StorageInspector().usage(paths: home.paths)
    #expect(usage.vmsBytes >= UInt64(megabyte))
    #expect(usage.vmsBytes < UInt64(64 * megabyte))
    #expect(usage.ociCacheBytes >= UInt64(2 * megabyte))
    #expect(usage.ociCacheBytes < UInt64(3 * megabyte))
    #expect(usage.ipswCacheBytes >= UInt64(megabyte))
    #expect(usage.otherBytes >= UInt64(megabyte))
    #expect(usage.otherBytes < UInt64(2 * megabyte))
    #expect(usage.volumeTotalBytes > 0)
    #expect(usage.volumeAvailableBytes <= usage.volumeTotalBytes)

    let vmSize = await StorageInspector().allocatedSize(of: home.paths.vmDirectory("demo"))
    #expect(vmSize == usage.vmsBytes)
    #expect(await StorageInspector().allocatedSize(of: home.paths.diskImage("demo")) < UInt64(64 * megabyte))
  }

  @Test func toleratesMissingTartHome() async {
    let paths = TartPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID())"))
    let usage = await StorageInspector().usage(paths: paths)
    #expect(usage.totalBytes == 0)
    #expect(usage.volumeTotalBytes > 0)
  }

  @Test func historyKeepsNewestSamplesInOrder() {
    var history = MetricsHistory<Int>(capacity: 3)
    #expect(history.isEmpty)
    #expect(history.latest == nil)
    for value in 1...2 { history.append(value) }
    #expect(history.samples == [1, 2])
    #expect(history.latest == 2)
    for value in 3...7 { history.append(value) }
    #expect(history.samples == [5, 6, 7])
    #expect(history.latest == 7)
    #expect(history.count == 3)
    history.removeAll()
    #expect(history.samples.isEmpty)
    history.append(9)
    #expect(history.samples == [9])
    #expect(history.capacity == 3)
  }
}
