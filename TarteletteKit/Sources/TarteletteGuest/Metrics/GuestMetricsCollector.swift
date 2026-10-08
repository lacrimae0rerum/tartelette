import Foundation
import TarteletteCore

/// Samples utilisation from inside a guest with one command per sample.
///
/// The guest prints `key=value` (or `prefix:line`) records that pure parsers turn into a
/// `GuestSample`, so parsing is testable without a VM.
public struct GuestMetricsCollector: Sendable {
  public static func sample(_ endpoint: GuestEndpoint, timeout: Duration = .seconds(10)) async throws -> GuestSample {
    let output = try await endpoint.transport.run(command(for: endpoint.os), standardInput: nil, timeout: timeout)
    guard output.succeeded else {
      throw GuestTransportError.commandFailed(
        status: output.status, message: GuestProbe.friendlyReason(for: output.diagnostic, status: output.status))
    }
    switch endpoint.os {
    case .linux: return parseLinux(output.stdoutString)
    default: return parseMacOS(output.stdoutString)
    }
  }

  public static func command(for os: VMOperatingSystem) -> [String] {
    GuestScripts.userCommand(["/bin/sh", "-c", os == .linux ? linuxScript : macOSScript], os: os)
  }

  // MARK: macOS

  static let macOSScript = #"""
    echo "loadavg=$(sysctl -n vm.loadavg)"
    echo "memsize=$(sysctl -n hw.memsize)"
    echo "boottime=$(sysctl -n kern.boottime)"
    echo "now=$(date +%s)"
    vm_stat | sed 's/^/vm:/'
    top -l 2 -n 0 -s 1 | grep '^CPU usage' | tail -1 | sed 's/^/top:/'
    (df -k /System/Volumes/Data 2>/dev/null || df -k /) | tail -1 | sed 's/^/df:/'
    echo "procs=$(ps -A -o pid= | wc -l | tr -d ' ')"
    """#

  public static func parseMacOS(_ output: String, date: Date = Date()) -> GuestSample {
    let records = Records(output)
    var sample = GuestSample(date: date)
    sample.loadAverage = parseLoadAverage(records.value("loadavg"))
    sample.memoryTotalBytes = records.value("memsize").flatMap { UInt64($0) }
    sample.memoryUsedBytes = parseVMStat(records.lines("vm"))
    if let cpu = records.lines("top").last { sample.cpuPercent = parseTopCPU(cpu) }
    if let df = records.lines("df").last { (sample.diskTotalBytes, sample.diskUsedBytes) = parseDF(df) }
    if let boot = records.value("boottime").flatMap(parseBootTime), let now = records.value("now").flatMap(Double.init) {
      sample.uptimeSeconds = max(0, now - boot)
    }
    sample.processCount = records.value("procs").flatMap { Int($0) }
    return sample
  }

  /// "Memory used" as Activity Monitor computes it: app memory + wired + compressed.
  static func parseVMStat(_ lines: [String]) -> UInt64? {
    guard let header = lines.first(where: { $0.contains("page size of") }),
      let pageSize = header.split(separator: " ").compactMap({ UInt64($0) }).first
    else { return nil }
    var pages: [String: UInt64] = [:]
    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
      let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
      if let number = UInt64(value) { pages[key] = number }
    }
    let wired = pages["Pages wired down"] ?? 0
    let compressed = pages["Pages occupied by compressor"] ?? 0
    let app: UInt64
    if let anonymous = pages["Anonymous pages"] {
      app = anonymous - min(anonymous, pages["Pages purgeable"] ?? 0)
    } else {
      app = pages["Pages active"] ?? 0
    }
    return (app + wired + compressed) * pageSize
  }

  /// `CPU usage: 13.78% user, 9.67% sys, 76.53% idle` → 23.47
  static func parseTopCPU(_ line: String) -> Double? {
    guard let range = line.range(of: "% idle") else { return nil }
    let prefix = line[..<range.lowerBound]
    guard let idle = prefix.split(whereSeparator: { $0 == " " || $0 == "," }).last.flatMap({ Double($0) }) else {
      return nil
    }
    return max(0, min(100, 100 - idle))
  }

  /// `{ sec = 1790538964, usec = 326546 } Sun Sep 27 …` → 1790538964
  static func parseBootTime(_ value: String) -> Double? {
    guard let range = value.range(of: "sec = ") else { return nil }
    return Double(value[range.upperBound...].prefix { $0.isNumber })
  }

  // MARK: Linux

  static let linuxScript = #"""
    echo "loadavg=$(cat /proc/loadavg)"
    grep -E '^(MemTotal|MemAvailable):' /proc/meminfo | sed 's/^/mem:/'
    head -1 /proc/stat | sed 's/^/stat1:/'
    sleep 0.5
    head -1 /proc/stat | sed 's/^/stat2:/'
    df -kP / | tail -1 | sed 's/^/df:/'
    echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
    echo "procs=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
    """#

  public static func parseLinux(_ output: String, date: Date = Date()) -> GuestSample {
    let records = Records(output)
    var sample = GuestSample(date: date)
    sample.loadAverage = parseLoadAverage(records.value("loadavg"))
    var memory: [String: UInt64] = [:]
    for line in records.lines("mem") {
      let parts = line.split(whereSeparator: { $0 == ":" || $0 == " " })
      if parts.count >= 2, let kilobytes = UInt64(parts[1]) { memory[String(parts[0])] = kilobytes * 1024 }
    }
    if let total = memory["MemTotal"] {
      sample.memoryTotalBytes = total
      if let available = memory["MemAvailable"] { sample.memoryUsedBytes = total - min(total, available) }
    }
    if let first = records.lines("stat1").first, let second = records.lines("stat2").first {
      sample.cpuPercent = parseProcStat(first, second)
    }
    if let df = records.lines("df").last { (sample.diskTotalBytes, sample.diskUsedBytes) = parseDF(df) }
    sample.uptimeSeconds = records.value("uptime").flatMap(Double.init)
    sample.processCount = records.value("procs").flatMap { Int($0) }
    return sample
  }

  /// Busy share between two `/proc/stat` `cpu` lines.
  static func parseProcStat(_ first: String, _ second: String) -> Double? {
    func fields(_ line: String) -> [UInt64] { line.split(separator: " ").dropFirst().compactMap { UInt64($0) } }
    let a = fields(first)
    let b = fields(second)
    guard a.count >= 4, b.count == a.count else { return nil }
    let idle = { (values: [UInt64]) in values[3] + (values.count > 4 ? values[4] : 0) }
    let total = Double(b.reduce(0, +) - min(b.reduce(0, +), a.reduce(0, +)))
    guard total > 0 else { return 0 }
    let idleDelta = Double(idle(b) - min(idle(b), idle(a)))
    return max(0, min(100, (1 - idleDelta / total) * 100))
  }

  // MARK: Shared

  /// macOS: `{ 7.48 5.31 4.42 }`; Linux: `0.12 0.30 0.25 1/123 4567`.
  static func parseLoadAverage(_ value: String?) -> [Double] {
    guard let value else { return [] }
    return Array(value.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" }).compactMap { Double($0) }.prefix(3))
  }

  /// `df -k` row: total = 1K-blocks, used = total − available (counts all volumes sharing the container).
  static func parseDF(_ line: String) -> (total: UInt64?, used: UInt64?) {
    let columns = line.split(separator: " ")
    guard columns.count >= 4, let total = UInt64(columns[1]), let available = UInt64(columns[3]) else {
      return (nil, nil)
    }
    return (total * 1024, (total - min(total, available)) * 1024)
  }

  /// Indexes `key=value` and `prefix:line` records.
  struct Records {
    private var values: [String: String] = [:]
    private var prefixed: [String: [String]] = [:]

    init(_ output: String) {
      for rawLine in output.split(whereSeparator: \.isNewline) {
        let line = String(rawLine)
        if let colon = line.firstIndex(of: ":"), let equals = line.firstIndex(of: "="), equals < colon {
          values[String(line[..<equals])] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        } else if let colon = line.firstIndex(of: ":") {
          prefixed[String(line[..<colon]), default: []].append(String(line[line.index(after: colon)...]))
        } else if let equals = line.firstIndex(of: "=") {
          values[String(line[..<equals])] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
      }
    }

    func value(_ key: String) -> String? { values[key] }
    func lines(_ prefix: String) -> [String] { prefixed[prefix] ?? [] }
  }
}
