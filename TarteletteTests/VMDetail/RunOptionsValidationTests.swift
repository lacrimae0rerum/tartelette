import Foundation
import TarteletteKit
import Testing

@testable import Tartelette

@Suite("Network validators")
struct NetworkValidatorsTests {
  @Test(arguments: ["10.0.0.0/8", "192.168.0.0/24", "0.0.0.0/0", "255.255.255.255/32", "1.2.3.4/0"])
  func acceptsWellFormedCIDRs(_ value: String) {
    #expect(NetworkValidators.cidr(value) == nil)
  }

  @Test(arguments: [
    "10.0.0.0", "10.0.0/8", "10.0.0.0.0/8", "10..0.0/8", "10.0.0.0//8", "10.0.0.0/33", "10.0.0.256/8",
    "+10.0.0.0/8", "10.0.0.0/+8", "10.0.0.-1/8", "010.0.0.0/8", " 10.0.0.0/8", "10.0.0.0/", "/8", "a.b.c.d/8",
  ])
  func rejectsMalformedCIDRs(_ value: String) {
    #expect(NetworkValidators.cidr(value) != nil)
  }

  @Test(arguments: ["2222:22", "8080:80", "65535:1"])
  func acceptsPortMappings(_ value: String) {
    #expect(NetworkValidators.portMapping(value) == nil)
  }

  @Test(arguments: ["22", "2222::22", ":22", "2222:", "0:22", "22:0", "65536:22", "+22:22", "22:+22", "2222:22:1", "a:b"])
  func rejectsMalformedPortMappings(_ value: String) {
    #expect(NetworkValidators.portMapping(value) != nil)
  }
}

@Suite("Run options validation")
struct RunOptionsValidationTests {
  private func issues(
    _ configure: (inout RunOptions) -> Void, os: VMOperatingSystem = .macOS, softnet: SoftnetState = .ready
  ) -> [RunOptionsIssue] {
    var options = RunOptions(name: "vm")
    configure(&options)
    return RunOptionsValidation.issues(for: RunProfile(options: options), os: os, softnet: softnet)
  }

  @Test func provisioningValuesWithCommasBlockSaving() {
    let found = issues { $0.provisioning = .init(username: "admin", password: "pa,ss") }
    #expect(found.contains { $0.severity == .error && $0.message.contains("comma") })
  }

  @Test func provisioningProblemIsReportedEvenWhenEveryValueIsInvalid() {
    // Invalid values are left out of the argument, so the profile looks empty; it must still fail.
    let found = issues { $0.provisioning = RunOptions.Provisioning(fullName: "Doe, Jane") }
    #expect(found.contains { $0.severity == .error && $0.message.contains("comma") })
  }

  @Test func validProvisioningValuesHaveNoCommaError() {
    let found = issues { $0.provisioning = .init(username: "admin", password: "p=ss") }
    #expect(!found.contains { $0.message.contains("comma") })
  }

  private func errors(_ issues: [RunOptionsIssue]) -> [RunOptionsIssue] { issues.filter { $0.severity == .error } }

  @Test func defaultOptionsHaveNoErrors() {
    #expect(errors(issues { _ in }).isEmpty)
    #expect(errors(issues({ _ in }, os: .linux)).isEmpty)
  }

  @Test func systemKeysNeedTartsWindow() {
    #expect(!errors(issues { $0.captureSystemKeys = true; $0.display = .headless }).isEmpty)
    #expect(errors(issues { $0.captureSystemKeys = true }).isEmpty)
  }

  @Test func suspendableIsMacOnlyAndNeedsInputDevices() {
    #expect(!errors(issues({ $0.suspendable = true }, os: .linux)).isEmpty)
    #expect(!errors(issues { $0.suspendable = true; $0.noKeyboard = true }).isEmpty)
    #expect(errors(issues { $0.suspendable = true }).isEmpty)
  }

  @Test func osSpecificFlags() {
    #expect(!errors(issues({ $0.noTrackpad = true }, os: .linux)).isEmpty)
    #expect(!errors(issues { $0.nested = true }).isEmpty)
    #expect(!errors(issues { $0.rosettaTag = "rosetta" }).isEmpty)
  }

  @Test func sharedFoldersOnOneTagMustBeNamed() {
    let unnamed = issues {
      $0.directories = [RunOptions.DirectoryShare(path: "/tmp"), RunOptions.DirectoryShare(path: "/var")]
    }
    #expect(!errors(unnamed).isEmpty)
    let named = issues {
      $0.directories = [
        RunOptions.DirectoryShare(name: "a", path: "/tmp"), RunOptions.DirectoryShare(name: "b", path: "/var"),
      ]
    }
    #expect(errors(named).isEmpty)
  }

  @Test func disksNeedALocationAndArm64Images() {
    #expect(!errors(issues { $0.disks = [RunOptions.DiskAttachment(location: "")] }).isEmpty)
    #expect(!errors(issues { $0.disks = [RunOptions.DiskAttachment(location: "/isos/ubuntu-amd64.iso")] }).isEmpty)
  }

  @Test func networkModes() {
    #expect(!errors(issues { $0.network = .bridged(interfaces: []) }).isEmpty)
    #expect(errors(issues { $0.network = .bridged(interfaces: ["en0"]) }).isEmpty)

    let softnet = RunOptions.Network.softnet(RunOptions.SoftnetOptions())
    #expect(!errors(issues({ $0.network = softnet }, softnet: .missing)).isEmpty)
    let unprivileged = issues({ $0.network = softnet }, softnet: .unprivileged)
    #expect(errors(unprivileged).isEmpty)
    #expect(unprivileged.contains { $0.severity == .warning })
  }

  @Test func screenSharingExplainsRemoteLogin() {
    #expect(issues { $0.display = .vnc }.contains { $0.severity == .info })
  }
}

@Suite("Effective run options")
struct EffectiveRunOptionsTests {
  @Test func clipboardEngineDecidesNoClipboard() {
    let options = RunOptions(name: "vm")
    #expect(RunProfile(options: options, clipboardEngine: .automatic).effectiveOptions(for: .macOS).noClipboard)
    #expect(!RunProfile(options: options, clipboardEngine: .automatic).effectiveOptions(for: .linux).noClipboard)
    #expect(RunProfile(options: options, clipboardEngine: .bridge).effectiveOptions(for: .linux).noClipboard)
    #expect(RunProfile(options: options, clipboardEngine: .off).effectiveOptions(for: .macOS).noClipboard)
    #expect(!RunProfile(options: options, clipboardEngine: .spice).effectiveOptions(for: .macOS).noClipboard)
  }

  @Test func otherOptionsAreUntouched() {
    var options = RunOptions(name: "vm")
    options.display = .headless
    options.nested = true
    let effective = RunProfile(options: options, clipboardEngine: .bridge).effectiveOptions(for: .linux)
    #expect(effective.display == .headless)
    #expect(effective.nested)
    #expect(effective.arguments.contains("--no-clipboard"))
  }
}
