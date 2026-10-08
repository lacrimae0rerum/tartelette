import Foundation

/// Which subcommands and options the installed `tart` understands, from
/// `tart --experimental-dump-help`. Lets the UI hide options an older Tart doesn't support.
public struct TartCapabilities: Sendable, Hashable {
  /// False when the dump was unavailable; every query then answers `true` (permissive).
  public var isKnown: Bool
  /// Subcommand name → option spellings (e.g. `--net-host`, `-i`), hidden options included.
  public var subcommands: [String: Set<String>]

  public init(subcommands: [String: Set<String>]) {
    self.isKnown = true
    self.subcommands = subcommands
  }

  private init(unknown: Void) {
    self.isKnown = false
    self.subcommands = [:]
  }

  /// Capabilities of an unknown Tart: everything is assumed to be supported.
  public static let unknown = TartCapabilities(unknown: ())

  /// Whether `subcommand` exists and, when given, accepts `option` (`--net-host`, `net-host` or `-i`).
  public func supports(_ subcommand: String, option: String? = nil) -> Bool {
    guard isKnown else { return true }
    guard let options = subcommands[subcommand] else { return false }
    guard let option, !option.isEmpty else { return true }
    let spelled = option.hasPrefix("-") ? option : "--\(option)"
    return options.contains(spelled)
  }

  /// Parses the JSON printed by `tart --experimental-dump-help`.
  public static func parse(dumpHelp data: Data) throws -> TartCapabilities {
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let command = root["command"] as? [String: Any],
      let children = command["subcommands"] as? [[String: Any]]
    else {
      throw CocoaError(.coderReadCorrupt)
    }

    var subcommands: [String: Set<String>] = [:]
    for child in children {
      guard let name = child["commandName"] as? String else { continue }
      var options = Set<String>()
      for argument in child["arguments"] as? [[String: Any]] ?? [] {
        for spelling in argument["names"] as? [[String: Any]] ?? [] {
          guard let kind = spelling["kind"] as? String, let value = spelling["name"] as? String else { continue }
          switch kind {
          case "long": options.insert("--\(value)")
          case "short", "longWithSingleDash": options.insert("-\(value)")
          default: continue
          }
        }
      }
      subcommands[name] = options
    }
    return TartCapabilities(subcommands: subcommands)
  }
}
