import Foundation

public enum TartOutputError: Error, Sendable, Equatable, LocalizedError {
  case malformed(String)

  public var errorDescription: String? {
    switch self {
    case .malformed(let detail): "Tart returned output the app couldn't understand: \(detail)"
    }
  }
}

/// Pure parsers for Tart's machine-readable output. Keys are matched by name because Tart's JSON
/// key order is not stable, and numeric fields are accepted as numbers, strings or null.
public enum TartOutputParsing {
  public static func parseList(_ data: Data) throws -> [VMListing] {
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty || text == "[]" { return [] }
    guard let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
      throw TartOutputError.malformed("expected a JSON array from `tart list`")
    }
    let dateParser = ISO8601DateFormatter()
    return rows.compactMap { row in
      guard let name = row["Name"] as? String else { return nil }
      let sourceValue = (row["Source"] as? String)?.lowercased() ?? "local"
      let state: VMState =
        if let raw = row["State"] as? String {
          VMState(rawValue: raw)
        } else {
          (row["Running"] as? Bool) == true ? .running : .stopped
        }
      return VMListing(
        name: name,
        source: sourceValue == "oci" ? .oci : .local,
        diskGB: finiteNumber(row["Disk"]),
        sizeGB: finiteNumber(row["Size"]),
        lastAccessed: (row["Accessed"] as? String).flatMap { dateParser.date(from: $0) },
        state: state
      )
    }
  }

  public static func parseDetails(_ data: Data) throws -> VMDetails {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TartOutputError.malformed("expected a JSON object from `tart get`")
    }
    let state: VMState =
      if let raw = object["State"] as? String {
        VMState(rawValue: raw)
      } else {
        (object["Running"] as? Bool) == true ? .running : .stopped
      }
    return VMDetails(
      os: VMOperatingSystem(tartValue: object["OS"] as? String ?? ""),
      cpuCount: try integer(object["CPU"], field: "CPU"),
      memoryMB: try integer(object["Memory"], field: "Memory"),
      diskGB: finiteNumber(object["Disk"]),
      diskFormat: object["DiskFormat"] as? String ?? DiskFormat.raw.rawValue,
      sizeGB: finiteNumber(object["Size"]),
      display: object["Display"] as? String ?? "",
      state: state
    )
  }

  /// A whole number field (missing → 0). Non-finite, negative-for-unsigned or out-of-range values
  /// throw instead of trapping in the integer conversion.
  private static func integer<Value: FixedWidthInteger>(_ raw: Any?, field: String) throws -> Value {
    guard let value = number(raw) else { return 0 }
    guard value.isFinite, let converted = Value(exactly: value.rounded(.towardZero)) else {
      throw TartOutputError.malformed("`\(field)` isn't a valid count: \(raw.map { "\($0)" } ?? "nil")")
    }
    return converted
  }

  /// An optional measurement; non-finite values are treated as unknown.
  private static func finiteNumber(_ raw: Any?) -> Double? {
    number(raw).flatMap { $0.isFinite ? $0 : nil }
  }

  public static func parseConfig(_ data: Data) throws -> VMConfigFile {
    try JSONDecoder().decode(VMConfigFile.self, from: data)
  }

  /// Extracts the first IPv4 address from `tart ip` output.
  public static func parseIP(_ output: String) -> String? {
    output
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { line in
        let parts = line.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
      }
  }

  /// Parses the VNC URL printed by `tart run --vnc*`.
  public static func parseVNCURL(_ line: String) -> URL? {
    guard let range = line.range(of: "vnc://") else { return nil }
    let candidate = line[range.lowerBound...]
      .split(whereSeparator: { $0.isWhitespace })
      .first
      .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".…")) }
    return candidate.flatMap(URL.init(string:))
  }

  /// Parses `Successfully open pty /dev/ttysNNN` from `tart run --serial`.
  public static func parseSerialDevice(_ line: String) -> String? {
    guard let range = line.range(of: "/dev/tty") else { return nil }
    return line[range.lowerBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
  }

  /// Parses bridged interface names from the error printed by `tart run <vm> --net-bridged=list`.
  /// Example: `available interfaces: ["en0 (or \"Ethernet\")", "en1 (or \"Wi-Fi\")"]`
  public static func parseBridgedInterfaces(_ output: String) -> [BridgedInterface] {
    guard let marker = output.range(of: "available interfaces:") else { return [] }
    let tail = output[marker.upperBound...]
    var results: [BridgedInterface] = []
    // Entries look like: "en0 (or \"Ethernet\")"
    let pattern = #"\"([A-Za-z0-9]+)(?: \(or \\\"([^\\]*)\\\"\))?\""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let string = String(tail)
    let range = NSRange(string.startIndex..., in: string)
    for match in regex.matches(in: string, range: range) {
      guard let nameRange = Range(match.range(at: 1), in: string) else { continue }
      let display = Range(match.range(at: 2), in: string).map { String(string[$0]) }
      results.append(BridgedInterface(bsdName: String(string[nameRange]), displayName: display))
    }
    return results
  }

  private static func number(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: number.doubleValue
    case let string as String: Double(string.trimmingCharacters(in: .whitespaces))
    default: nil
    }
  }
}

public struct BridgedInterface: Sendable, Hashable, Identifiable {
  public var id: String { bsdName }
  public var bsdName: String
  public var displayName: String?

  public init(bsdName: String, displayName: String?) {
    self.bsdName = bsdName
    self.displayName = displayName
  }

  public var label: String {
    if let displayName, !displayName.isEmpty { "\(displayName) (\(bsdName))" } else { bsdName }
  }
}

/// Incremental line classifier for Tart's human-readable output.
///
/// Run Tart with `CI=1` so progress updates are emitted as plain `N%` lines; ANSI cursor sequences
/// are stripped anyway for robustness.
public struct TartProgressParser: Sendable {
  public enum Event: Sendable, Equatable {
    /// A phase/status line such as `pulling disk (12.3 GB compressed)...`.
    case status(String)
    /// Progress of the current phase in 0...1.
    case progress(Double)
  }

  public private(set) var currentPhase: String?
  public private(set) var fraction: Double?

  public init() {}

  public mutating func consume(line rawLine: String) -> Event? {
    let line = Self.stripANSI(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return nil }
    if line.hasSuffix("%"), let value = Int(line.dropLast()), (0...100).contains(value) {
      fraction = Double(value) / 100
      return .progress(Double(value) / 100)
    }
    currentPhase = line
    fraction = nil
    return .status(line)
  }

  public static func stripANSI(_ text: String) -> String {
    guard text.contains("\u{1B}") else { return text.replacingOccurrences(of: "\r", with: "") }
    let pattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
    return text
      .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
      .replacingOccurrences(of: "\r", with: "")
  }
}
