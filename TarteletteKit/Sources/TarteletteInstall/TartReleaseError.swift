import Foundation

/// Why the latest Tart release couldn't be found or verified.
///
/// `errorDescription` is a complete sentence for the UI that says what to do next;
/// `failureReason` carries the technical detail when there is one.
public enum TartReleaseError: LocalizedError, Sendable, Equatable {
  /// GitHub couldn't be reached: offline, DNS, TLS or a timeout.
  case network(reason: String)
  /// GitHub's limit for requests without an account was reached. It lifts at `resetsAt`, when known.
  case rateLimited(resetsAt: Date?)
  /// `openai/tart` has no published release (HTTP 404).
  case noRelease
  /// Any other unsuccessful HTTP status.
  case httpStatus(Int)
  /// The answer isn't a release description, or its tag isn't a version number.
  case unexpectedResponse(reason: String)
  /// The latest release is a draft or a pre-release, which Tartelette never installs.
  case notUsable(tag: String, reason: NotUsableReason)
  /// The release lacks a file the installer needs.
  case missingAsset(name: String, tag: String)
  /// A line of the release's checksums file isn't `<sha256>  <file name>`, or lists a file twice.
  case malformedChecksums(line: Int)
  /// The release's checksums file doesn't list this file.
  case missingChecksum(fileName: String)

  public enum NotUsableReason: Sendable, Equatable {
    case draft
    case prerelease
  }

  public var errorDescription: String? {
    switch self {
    case .network:
      return "Tartelette couldn't reach GitHub to look for Tart releases. Check your internet connection and try again."
    case .rateLimited(let resetsAt):
      let when = resetsAt.map { "after \($0.formatted(date: .omitted, time: .shortened))" } ?? "later"
      return "GitHub limits how often Tartelette can look for Tart releases, and that limit has been reached. "
        + "Try again \(when)."
    case .noRelease:
      return "GitHub doesn't list a published Tart release yet. Try again later."
    case .httpStatus(let status):
      return "GitHub answered with HTTP status \(status) while Tartelette looked for Tart releases. Try again later."
    case .unexpectedResponse:
      return "Tartelette couldn't read GitHub's answer about the latest Tart release. Try again later; "
        + "if it keeps happening, look for a newer version of Tartelette."
    case .notUsable(let tag, .draft):
      return "The latest Tart release (\(tag)) is still a draft, so Tartelette won't install it. Try again later."
    case .notUsable(let tag, .prerelease):
      return "The latest Tart release (\(tag)) is a pre-release, so Tartelette won't install it. Try again later."
    case .missingAsset(let name, let tag):
      return "Tart \(tag) on GitHub doesn't include “\(name)”, which Tartelette needs to install and verify it. "
        + "Try again later."
    case .malformedChecksums(let line):
      return "The checksums file of this Tart release is damaged (line \(line)), so Tartelette can't verify the "
        + "download. Try again later."
    case .missingChecksum(let fileName):
      return "The checksums file of this Tart release doesn't list “\(fileName)”, so Tartelette can't verify the "
        + "download. Try again later."
    }
  }

  public var failureReason: String? {
    switch self {
    case .network(let reason), .unexpectedResponse(let reason): reason
    default: nil
    }
  }
}
