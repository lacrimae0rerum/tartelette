import Foundation
import Security

/// Checks that an app bundle is the official, unmodified Tart.
///
/// The installer's security guard: nothing reaches `versions/` without passing it.
public protocol TartSignatureVerifying: Sendable {
  /// Throws `TartInstallError.signatureRejected` unless the app at `url` is validly signed by Tart's
  /// developer and unmodified.
  func verify(appAt url: URL) throws
}

/// Verifies Tart's code signature with the Security framework, without ever modifying the bundle.
public struct CodeSignatureVerifier: TartSignatureVerifying {
  /// The code requirement every official Tart satisfies: an Apple-anchored Developer ID certificate
  /// chain whose leaf belongs to Cirrus Labs (team `9M2P8L4D89`), and Tart's bundle identifier.
  public static let tartRequirement = """
    identifier "com.github.cirruslabs.tart" and anchor apple generic \
    and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] \
    and certificate leaf[subject.OU] = "9M2P8L4D89"
    """

  private let requirement: String

  public init() {
    self.init(requirement: Self.tartRequirement)
  }

  /// A verifier for another requirement, so tests can prove each clause is enforced.
  init(requirement: String) {
    self.requirement = requirement
  }

  public func verify(appAt url: URL) throws {
    var code: SecStaticCode?
    let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
    guard created == errSecSuccess, let code else {
      throw TartInstallError.signatureRejected(signer: "none (not signed)", reason: Self.message(for: created))
    }

    var requirement: SecRequirement?
    let compiled = SecRequirementCreateWithString(self.requirement as CFString, [], &requirement)
    guard compiled == errSecSuccess, let requirement else {
      throw TartInstallError.signatureRejected(
        signer: Self.signer(of: code), reason: "Invalid code requirement: \(Self.message(for: compiled))")
    }

    // Strict validation of every architecture and all nested code, the way Gatekeeper checks it.
    let flags = SecCSFlags(
      rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSRestrictSymlinks)
    var failure: Unmanaged<CFError>?
    let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &failure)
    failure?.release()
    guard status == errSecSuccess else {
      // The Security framework's sentence for the status, such as "code failed to satisfy specified
      // code requirement(s)", reads better than the CFError's "The operation couldn't be completed".
      throw TartInstallError.signatureRejected(signer: Self.signer(of: code), reason: Self.message(for: status))
    }
  }

  /// Who signed `code`, in words: the leaf certificate's name and the signed identifier.
  private static func signer(of code: SecStaticCode) -> String {
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
      let information = information as? [String: Any]
    else { return "unreadable" }

    let identifier = information[kSecCodeInfoIdentifier as String] as? String
    let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
    guard let identifier else { return "none (not signed)" }
    guard let leaf = certificates.first else { return "ad-hoc, identifier \(identifier), no developer certificate" }
    let name = SecCertificateCopySubjectSummary(leaf).map { $0 as String } ?? "an unnamed certificate"
    return "“\(name)”, identifier \(identifier)"
  }

  private static func message(for status: OSStatus) -> String {
    SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
  }
}
