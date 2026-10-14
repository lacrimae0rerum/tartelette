import Foundation
import Testing

@testable import TarteletteInstall

/// The `tart.app` Homebrew installed on this Mac, if any: an official build to verify against.
private let homebrewTartApp: URL? = {
  let cellar = URL(fileURLWithPath: "/opt/homebrew/Cellar/tart", isDirectory: true)
  let versions = (try? FileManager.default.contentsOfDirectory(atPath: cellar.path)) ?? []
  return versions.sorted().reversed()
    .map { cellar.appendingPathComponent("\($0)/libexec/tart.app", isDirectory: true) }
    .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/tart").path) }
}()

@Suite("Tart code signature")
struct CodeSignatureVerifierTests {
  let verifier = CodeSignatureVerifier()

  @Test func pinsCirrusLabsDeveloperIDAndTartsIdentifier() {
    #expect(
      CodeSignatureVerifier.tartRequirement
        == #"identifier "com.github.cirruslabs.tart" and anchor apple generic "#
        + #"and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] "#
        + #"and certificate leaf[subject.OU] = "9M2P8L4D89""#)
  }

  @Test func rejectsAnAdHocSignedApp() throws {
    let scratch = try ScratchDirectory("signature")
    defer { scratch.remove() }
    let app = try makeApp(in: scratch, signing: .adHoc)

    let error = try #require(throws: TartInstallError.self) { try verifier.verify(appAt: app) }
    guard case .signatureRejected(let signer, _) = error else {
      Issue.record("Expected a rejected signature, got \(error)")
      return
    }
    #expect(signer.contains("ad-hoc"))
  }

  @Test func explainsARejectionReadablyForAnyCopyOfTart() throws {
    let scratch = try ScratchDirectory("signature")
    defer { scratch.remove() }
    let app = try makeApp(in: scratch, signing: .adHoc)

    let error = try #require(throws: TartInstallError.self) { try verifier.verify(appAt: app) }
    let reason = try #require(error.failureReason)
    #expect(!reason.contains("OSStatus"), "\(reason)")
    #expect(!reason.contains("couldn’t be completed"), "\(reason)")
    let message = try #require(error.errorDescription)
    #expect(message.hasPrefix("This copy of Tart"), "\(message)")
    #expect(!message.contains("downloaded"), "\(message)")
    #expect(message.contains("9M2P8L4D89"))
  }

  @Test func rejectsAnUnsignedApp() throws {
    let scratch = try ScratchDirectory("signature")
    defer { scratch.remove() }
    let app = try makeApp(in: scratch, signing: .none)

    let error = try #require(throws: TartInstallError.self) { try verifier.verify(appAt: app) }
    guard case .signatureRejected(let signer, _) = error else {
      Issue.record("Expected a rejected signature, got \(error)")
      return
    }
    #expect(signer.contains("not signed"))
  }

  @Test(.enabled(if: homebrewTartApp != nil, "needs Tart installed with Homebrew"))
  func acceptsTheOfficialTart() throws {
    try verifier.verify(appAt: #require(homebrewTartApp))
  }

  @Test(.enabled(if: homebrewTartApp != nil, "needs Tart installed with Homebrew"))
  func rejectsTheOfficialTartForAnotherTeamAndNamesItsSigner() throws {
    let otherTeam = CodeSignatureVerifier(
      requirement: CodeSignatureVerifier.tartRequirement.replacingOccurrences(of: "9M2P8L4D89", with: "AAAAAAAAAA"))

    let error = try #require(throws: TartInstallError.self) { try otherTeam.verify(appAt: #require(homebrewTartApp)) }
    guard case .signatureRejected(let signer, _) = error else {
      Issue.record("Expected a rejected signature, got \(error)")
      return
    }
    #expect(signer.contains("Developer ID Application: Cirrus Labs, Inc. (9M2P8L4D89)"))
    #expect(signer.contains("com.github.cirruslabs.tart"))
  }

  @Test(.enabled(if: homebrewTartApp != nil, "needs Tart installed with Homebrew"))
  func rejectsTheOfficialTartUnderAnotherIdentifier() throws {
    let otherIdentifier = CodeSignatureVerifier(
      requirement: CodeSignatureVerifier.tartRequirement.replacingOccurrences(
        of: "com.github.cirruslabs.tart", with: "com.example.tart"))

    #expect(throws: TartInstallError.self) { try otherIdentifier.verify(appAt: #require(homebrewTartApp)) }
  }

  @Test(.enabled(if: homebrewTartApp != nil, "needs Tart installed with Homebrew"))
  func rejectsAModifiedCopyOfTheOfficialTart() throws {
    let scratch = try ScratchDirectory("signature")
    defer { scratch.remove() }
    let copy = scratch.appending("tart.app")
    try FileManager.default.copyItem(at: #require(homebrewTartApp), to: copy)
    try Data("extra".utf8).write(to: copy.appendingPathComponent("Contents/Resources/added.txt"))

    #expect(throws: TartInstallError.self) { try verifier.verify(appAt: copy) }
  }

  // MARK: - Fixtures

  enum Signing { case none, adHoc }

  /// A minimal app bundle claiming Tart's identifier, around a copy of `/usr/bin/true`.
  func makeApp(in scratch: ScratchDirectory, signing: Signing) throws -> URL {
    let app = scratch.appending("tart.app")
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("tart").path)
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.github.cirruslabs.tart", "CFBundleExecutable": "tart",
      "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "2.41.0",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    switch signing {
    case .none:
      try run("/usr/bin/codesign", "--remove-signature", macOS.appendingPathComponent("tart").path)
    case .adHoc:
      try run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "com.github.cirruslabs.tart", app.path)
    }
    return app
  }

  func run(_ executable: String, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "\(executable) \(arguments.joined(separator: " ")) failed")
  }
}
