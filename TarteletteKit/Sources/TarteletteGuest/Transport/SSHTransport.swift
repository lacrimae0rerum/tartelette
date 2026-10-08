import Foundation
import TarteletteCore

/// Delivers guest commands over SSH: the fallback for guests without the Tart Guest Agent.
///
/// Host key checking is disabled on purpose: local VMs are ephemeral and Tart's DHCP hands the same
/// IP address to different VMs over time, so a known_hosts entry would routinely be "wrong" and
/// block the connection. The traffic never leaves the host's virtual network.
public struct SSHTransport: GuestTransport {
  public static let executable = URL(fileURLWithPath: "/usr/bin/ssh")
  /// Environment variable the askpass helper reads the password from.
  static let passwordVariable = "TARTELETTE_SSH_PASSWORD"

  public let host: String
  public let user: String
  private let password: String?
  public let identityFile: URL?
  private let runner: any ProcessRunning
  private let askpassDirectory: URL

  public init(
    host: String,
    user: String,
    password: String?,
    identityFile: URL?,
    runner: any ProcessRunning,
    askpassDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    self.host = host
    self.user = user
    self.password = password
    self.identityFile = identityFile
    self.runner = runner
    self.askpassDirectory = askpassDirectory
  }

  public var label: String { "ssh \(user)@\(host)" }

  /// The `ssh` argv (without the executable) for a guest command.
  public func arguments(for command: [String], hasStandardInput: Bool) -> [String] {
    var args = [
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "LogLevel=ERROR",
      "-o", "ConnectTimeout=5",
      "-o", "NumberOfPasswordPrompts=1",
    ]
    if password == nil || password?.isEmpty == true { args += ["-o", "BatchMode=yes"] }
    if let identityFile { args += ["-i", identityFile.path, "-o", "IdentitiesOnly=yes"] }
    if !hasStandardInput { args.append("-n") }
    args.append("\(user)@\(host)")
    args.append(ShellQuoting.join(command))
    return args
  }

  /// Environment for the ssh process; supplies the password through `SSH_ASKPASS` when set.
  public func environment(askpassHelper: URL?) -> [String: String] {
    guard let password, !password.isEmpty, let askpassHelper else { return [:] }
    return [
      "SSH_ASKPASS": askpassHelper.path,
      "SSH_ASKPASS_REQUIRE": "force",
      "DISPLAY": ":0",
      Self.passwordVariable: password,
    ]
  }

  public func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
    let helper = (password?.isEmpty == false) ? try Self.installAskpassHelper(in: askpassDirectory) : nil
    let request = ProcessRequest(
      executable: Self.executable,
      arguments: arguments(for: command, hasStandardInput: standardInput != nil),
      environment: environment(askpassHelper: helper),
      standardInput: standardInput,
      timeout: timeout
    )
    return try await runner.runCapturingFailures(request)
  }

  /// Writes (idempotently) a 0700 helper that prints the password from the environment, so the
  /// secret never appears in argv or on disk.
  static func installAskpassHelper(in directory: URL) throws -> URL {
    let helper = directory.appendingPathComponent("tartelette-askpass-\(getuid()).sh")
    let script = "#!/bin/sh\nprintf '%s\\n' \"$\(passwordVariable)\"\n"
    let fileManager = FileManager.default
    if let existing = try? String(contentsOf: helper, encoding: .utf8), existing == script {
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
      return helper
    }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(script.utf8).write(to: helper, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    return helper
  }
}
