import Foundation
import TarteletteCore

@testable import TarteletteCLI

/// A throwaway `tart` stand-in: a bash script that records argv/env/stdin and prints fixtures.
struct FakeTart {
  let directory: URL
  let executable: URL
  let environment: TartEnvironment

  init(customHome: Bool = false) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartelette-fake-tart-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    executable = directory.appendingPathComponent("tart")
    try Self.script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let paths =
      customHome
      ? TartPaths(home: directory.appendingPathComponent("home", isDirectory: true))
      : TartPaths.resolve(environment: [:])
    environment = TartEnvironment(
      executable: executable, paths: paths, extraVariables: ["FAKE_TART_DIR": directory.path])
  }

  var client: TartClient { TartClient(environment: environment) }

  func recorded(_ name: String) -> String {
    (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
  }

  /// Parses an `env` dump recorded by the script into a dictionary.
  func recordedEnvironment(_ subcommand: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in recorded("env-\(subcommand).txt").split(separator: "\n") {
      guard let separator = line.firstIndex(of: "=") else { continue }
      result[String(line[..<separator])] = String(line[line.index(after: separator)...])
    }
    return result
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  static let script = #"""
    #!/bin/bash
    D="$FAKE_TART_DIR"
    printf '%s\n' "$@" > "$D/args-$1.txt"
    env > "$D/env-$1.txt"
    case "$1" in
      --version) echo "2.40.1" ;;
      --experimental-dump-help)
        echo '{"serializationVersion":0,"command":{"commandName":"tart","subcommands":[{"commandName":"exec","arguments":[{"kind":"flag","names":[{"kind":"short","name":"i"}]},{"kind":"positional"}]}]}}'
        ;;
      list)
        cat <<'JSON'
    [
      { "State" : "running", "Name" : "dev", "Source" : "local", "Disk" : 50, "Size" : 12,
        "Accessed" : "2026-10-08T15:23:25Z", "Running" : true },
      { "Name" : "ghcr.io/cirruslabs/ubuntu:latest", "Source" : "OCI", "Disk" : null, "Size" : 2,
        "Accessed" : "2026-10-01T00:00:00Z", "Running" : false, "State" : "stopped" }
    ]
    JSON
        ;;
      get)
        echo '{ "OS" : "darwin", "CPU" : 4, "Memory" : 8192, "Disk" : 50, "DiskFormat" : "raw", "Size" : "12.345", "Display" : "1024x768pt", "Running" : false, "State" : "stopped" }'
        ;;
      ip) echo "192.168.64.7" ;;
      login) cat > "$D/stdin-login.txt" ;;
      rename)
        printf "Error: failed to rename VM a, target VM b already exists, delete it first!\nUsage: tart rename <name> <new-name>\n  See 'tart rename --help' for more information.\n" >&2
        exit 64
        ;;
      stop) echo 'VM "ghost" is not running' >&2; exit 2 ;;
      pull)
        echo "pulling ghcr.io/org/img:latest..."
        echo "pulling disk (1.2 GB compressed)..."
        echo "0%"
        printf '\033[1A\r\033[J50%%\n'
        echo "warning: slow network" >&2
        printf '100%%'
        ;;
      push)
        trap 'echo "interrupted by SIGINT"; exit 130' INT
        echo "pushing disk... this will take a while..."
        for i in $(seq 1 200); do sleep 0.05; done
        echo "not interrupted"
        ;;
      run)
        echo "booting $2"
        echo "warning on stderr" >&2
        sleep 1
        echo "guest has stopped the virtual machine"
        ;;
      *) echo "unexpected $1" >&2; exit 1 ;;
    esac
    """#
}
