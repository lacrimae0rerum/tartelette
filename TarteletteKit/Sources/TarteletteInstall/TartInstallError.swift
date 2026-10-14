import Foundation

/// Why Tartelette couldn't install, switch or remove the Tart it manages.
///
/// Every failure leaves the managed copy as it was. `errorDescription` is a complete sentence for the
/// UI that says what to do next; `failureReason` carries the technical detail when there is one.
public enum TartInstallError: LocalizedError, Sendable, Equatable {
  /// A download address, or the address a download was redirected to, isn't `https`.
  case insecureURL(String)
  /// The download couldn't finish: offline, DNS, TLS, a timeout or a dropped connection.
  case network(reason: String)
  /// The server answered a download with an unsuccessful HTTP status.
  case httpStatus(Int)
  /// The file grew far beyond the size the release announced, so the download was stopped.
  case downloadTooLarge(fileName: String)
  /// The archive's SHA-256 differs from the one in the release's checksums file.
  case checksumMismatch(fileName: String)
  /// `/usr/bin/tar` couldn't unpack the archive.
  case extractionFailed(reason: String)
  /// The archive doesn't hold a real `tart.app` folder.
  case unexpectedArchive(reason: String)
  /// `tart.app` isn't signed by Tart's developer, or was modified. `signer` says who signed it, in words.
  case signatureRejected(signer: String, reason: String)
  /// `tart.app` says it is a different version than the release it came from.
  case versionMismatch(expected: String, found: String)
  /// The disk is full.
  case diskFull
  /// Any other file system failure, such as missing permissions.
  case fileSystem(reason: String)
  /// Another Tartelette process is installing, switching or removing Tart right now.
  case busy
  /// There is no earlier version to go back to.
  case noPreviousVersion
  /// Running processes execute these installed versions, so they can't be removed or replaced.
  case inUse(versions: [String])

  public var errorDescription: String? {
    switch self {
    case .insecureURL:
      return "Tartelette stopped the Tart download because it wasn't going to an encrypted (https) address. "
        + "Nothing was installed. Try again later."
    case .network:
      return "Tartelette couldn't download Tart from GitHub. Nothing was installed. Check your internet "
        + "connection and try again."
    case .httpStatus(let status):
      return "GitHub answered with HTTP status \(status) while Tartelette downloaded Tart. Nothing was "
        + "installed. Try again later."
    case .downloadTooLarge(let fileName):
      return "The download of “\(fileName)” grew far beyond the size GitHub announced, so Tartelette stopped it. "
        + "Nothing was installed. Try again later."
    case .checksumMismatch(let fileName):
      return "The downloaded “\(fileName)” doesn't match the checksum published with the Tart release, so "
        + "Tartelette didn't install it. The download may be damaged; try again."
    case .extractionFailed:
      return "Tartelette couldn't unpack the downloaded Tart archive. Nothing was installed. Try again; if it "
        + "keeps happening, look for a newer version of Tartelette."
    case .unexpectedArchive:
      return "The downloaded Tart archive doesn't contain what Tartelette expects (a tart.app folder), so "
        + "nothing was installed. Look for a newer version of Tartelette."
    case .signatureRejected(let signer, _):
      return "The downloaded Tart failed the signature check (it must be signed by its developer, Cirrus Labs, "
        + "team 9M2P8L4D89, and be unmodified), so Tartelette didn't install it. Its signature: \(signer). "
        + "Don't use this download; try again later."
    case .versionMismatch(let expected, let found):
      return "The downloaded Tart says it is version \(found) instead of \(expected), so Tartelette didn't "
        + "install it. Try again later."
    case .diskFull:
      return "There isn't enough free disk space to install Tart (it needs about 100 MB). Nothing was "
        + "installed. Free some space and try again."
    case .fileSystem:
      return "Tartelette couldn't write its copy of Tart in Application Support, so nothing was changed. Check "
        + "that you can write to ~/Library/Application Support/Tartelette and try again."
    case .busy:
      return "Tartelette is already installing or changing Tart in another window. Wait for it to finish, "
        + "then try again."
    case .noPreviousVersion:
      return "There's no earlier version of Tart to go back to."
    case .inUse(let versions):
      let names = versions.joined(separator: ", ")
      return "Tart \(names) is still running (a virtual machine or a tart command uses it), so Tartelette "
        + "left it in place. Stop those virtual machines and commands, then try again."
    }
  }

  public var failureReason: String? {
    switch self {
    case .insecureURL(let url): url
    case .network(let reason), .extractionFailed(let reason), .unexpectedArchive(let reason),
      .signatureRejected(_, let reason), .fileSystem(let reason):
      reason
    default: nil
    }
  }

  /// The error a failed file operation stands for: `diskFull` when the disk is out of space,
  /// `fileSystem` otherwise. Errors that already are a `TartInstallError` pass through.
  static func fileSystem(_ error: any Error) -> TartInstallError {
    if let error = error as? TartInstallError { return error }
    let nsError = error as NSError
    let outOfSpace =
      (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
      || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
      || (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map {
        $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC)
      } == true
    return outOfSpace ? .diskFull : .fileSystem(reason: nsError.localizedDescription)
  }
}
