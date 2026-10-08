import Foundation

public enum ShellQuoting {
  private static let safeCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_"
  )

  /// Quotes a single argument for POSIX shells, leaving obviously safe words untouched.
  public static func quote(_ argument: String) -> String {
    if argument.isEmpty { return "''" }
    if argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) { return argument }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Joins arguments into a copy-pasteable command line.
  public static func join(_ arguments: [String]) -> String {
    arguments.map(quote).joined(separator: " ")
  }
}
