import Foundation

/// Every operation the `tart` executable offers, as a value that renders its own argv.
public enum TartCommand: Sendable, Hashable {
  case create(CreateOptions)
  case clone(CloneOptions)
  case run(RunOptions)
  case set(SetOptions)
  case get(name: String, format: OutputFormat = .json)
  case list(ListOptions = ListOptions())
  case login(LoginOptions)
  case logout(host: String)
  case ip(IPOptions)
  case exec(ExecOptions)
  case pull(PullOptions)
  case push(PushOptions)
  case importVM(path: String, name: String)
  /// Always pass a destination: without one Tart asks a yes/no question on stdin.
  case export(name: String, path: String)
  case prune(PruneOptions)
  case rename(name: String, newName: String)
  /// Hard stop after `timeoutSeconds` (default 30). On a suspended VM this discards the snapshot.
  case stop(name: String, timeoutSeconds: Int? = nil)
  case delete(names: [String])
  /// Requires the VM to have been started with `--suspendable`, otherwise the VM is killed.
  case suspend(name: String)
  /// Hidden: resolve a remote name to its fully-qualified digest form (from the local cache).
  case fqn(name: String)
  case version

  public static let defaultStopTimeoutSeconds = 30

  /// Arguments to pass after the executable path.
  public var arguments: [String] {
    switch self {
    case .create(let options): options.arguments
    case .clone(let options): options.arguments
    case .run(let options): options.arguments
    case .set(let options): options.arguments
    case .get(let name, let format):
      format == .text ? ["get", name] : ["get", name, "--format", format.rawValue]
    case .list(let options): options.arguments
    case .login(let options): options.arguments
    case .logout(let host): ["logout", host]
    case .ip(let options): options.arguments
    case .exec(let options): options.arguments
    case .pull(let options): options.arguments
    case .push(let options): options.arguments
    case .importVM(let path, let name): ["import", path, name]
    case .export(let name, let path): ["export", name, path]
    case .prune(let options): options.arguments
    case .rename(let name, let newName): ["rename", name, newName]
    case .stop(let name, let timeout):
      if let timeout, timeout != Self.defaultStopTimeoutSeconds {
        ["stop", name, "--timeout", String(timeout)]
      } else {
        ["stop", name]
      }
    case .delete(let names): ["delete"] + names
    case .suspend(let name): ["suspend", name]
    case .fqn(let name): ["fqn", name]
    case .version: ["--version"]
    }
  }

  /// The subcommand name, e.g. `clone`.
  public var subcommand: String {
    switch self {
    case .version: "version"
    default: arguments.first ?? ""
    }
  }

  /// A copy-pasteable shell command line with secrets masked.
  public var commandLine: String {
    let args: [String]
    switch self {
    case .run(let options): args = options.redacted.arguments
    default: args = arguments
    }
    return "tart " + ShellQuoting.join(args)
  }

  /// Whether the command typically runs for a long time and benefits from progress UI.
  public var isLongRunning: Bool {
    switch self {
    case .create, .clone, .pull, .push, .importVM, .export, .prune, .run: true
    default: false
    }
  }

  /// Whether the command emits `N%` progress lines.
  public var reportsProgress: Bool {
    switch self {
    case .create(let options):
      if case .macOS = options.source { true } else { false }
    case .clone, .pull, .push: true
    default: false
    }
  }

  /// A short human-readable title, e.g. “Pull ghcr.io/cirruslabs/macos-tahoe-base:latest”.
  public var title: String {
    switch self {
    case .create(let options):
      switch options.source {
      case .macOS: "Create macOS VM “\(options.name)”"
      case .linux: "Create Linux VM “\(options.name)”"
      }
    case .clone(let options): "Clone \(options.source) → \(options.newName)"
    case .run(let options): "Run \(options.name)"
    case .set(let options): "Configure \(options.name)"
    case .get(let name, _): "Get \(name)"
    case .list: "List VMs"
    case .login(let options): "Log in to \(options.host)"
    case .logout(let host): "Log out of \(host)"
    case .ip(let options): "Resolve IP of \(options.name)"
    case .exec(let options): "Exec in \(options.name)"
    case .pull(let options): "Pull \(options.remoteName)"
    case .push(let options): "Push \(options.localName)"
    case .importVM(_, let name): "Import \(name)"
    case .export(let name, _): "Export \(name)"
    case .prune(let options): options.entries == .vms ? "Prune VMs" : "Prune caches"
    case .rename(let name, let newName): "Rename \(name) → \(newName)"
    case .stop(let name, _): "Stop \(name)"
    case .delete(let names): "Delete \(names.joined(separator: ", "))"
    case .suspend(let name): "Suspend \(name)"
    case .fqn(let name): "Resolve \(name)"
    case .version: "Tart version"
    }
  }
}

/// Signals understood by a running `tart run` process (its PID is the holder of the VM lock).
public enum RunningVMSignal: Sendable, Hashable, CaseIterable {
  /// SIGUSR2: ask the guest OS to shut down gracefully. Not exposed by any CLI subcommand.
  case requestGuestShutdown
  /// SIGINT: hard power-off (what `tart stop` sends).
  case powerOff
  /// SIGUSR1: snapshot and stop (needs `--suspendable`; otherwise the VM is killed).
  case suspend

  public var signalNumber: Int32 {
    switch self {
    case .requestGuestShutdown: SIGUSR2
    case .powerOff: SIGINT
    case .suspend: SIGUSR1
    }
  }
}

/// Classification of Tart's exit codes.
public enum TartExitCode {
  public static let success: Int32 = 0
  public static let failure: Int32 = 1
  /// VM does not exist, is not running, or is already running.
  public static let vmStateError: Int32 = 2
  /// Argument parsing or validation failure.
  public static let usageError: Int32 = 64
}
