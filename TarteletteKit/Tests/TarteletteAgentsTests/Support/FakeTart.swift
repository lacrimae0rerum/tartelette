import Foundation
import TarteletteCLI
import TarteletteCore

/// A throwaway `tart` stand-in for the agent tools: a bash script that records every invocation
/// and acts on a temporary `TART_HOME`.
///
/// `list` reports every directory in `$TART_HOME/vms` (state from `state-<name>`, `stopped` by
/// default) followed by one OCI cache entry. `clone`, `delete` and `stop` change the VM
/// directories and states; `run` marks the VM running and stays alive for ten seconds.
struct FakeTart {
  /// Holds the recorded calls and the files that steer the script.
  let directory: URL
  let environment: TartEnvironment

  init(in root: URL) throws {
    directory = root.appendingPathComponent("fake-tart", isDirectory: true)
    let home = root.appendingPathComponent("tart-home", isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: home.appendingPathComponent("vms"), withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("tart")
    try Self.script.write(to: executable, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    environment = TartEnvironment(
      executable: executable, paths: TartPaths(home: home), extraVariables: ["FAKE_TART_DIR": directory.path])
  }

  var client: TartClient { TartClient(environment: environment) }
  var paths: TartPaths { environment.paths }

  /// Every invocation's arguments, one line each, oldest first.
  var calls: [String] {
    let text = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// Creates `$TART_HOME/vms/<name>/config.json`.
  func addVM(_ name: String, os: String = "darwin", state: String? = nil) throws {
    let vm = paths.vmDirectory(name)
    try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
    let config = """
      {"version":1,"os":"\(os)","arch":"arm64","cpuCount":4,"memorySize":8589934592,\
      "display":{"width":1024,"height":768},"macAddress":"7e:00:00:00:00:01"}
      """
    try config.write(to: paths.configFile(name), atomically: true, encoding: .utf8)
    if let state { try setState(state, of: name) }
  }

  /// The state `list` reports for a VM.
  func setState(_ state: String, of name: String) throws {
    try state.write(to: directory.appendingPathComponent("state-\(name)"), atomically: true, encoding: .utf8)
  }

  /// Creates (or removes) a file the script checks, such as `run-fails` or `clone-fails`.
  func setFlag(_ name: String, contents: String? = "") throws {
    let file = directory.appendingPathComponent(name)
    if let contents {
      try contents.write(to: file, atomically: true, encoding: .utf8)
    } else {
      try? FileManager.default.removeItem(at: file)
    }
  }

  /// Kills the `run` processes the script started.
  func killLaunchedVMs() {
    let text = (try? String(contentsOf: directory.appendingPathComponent("launched.pids"), encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") {
      if let pid = Int32(line) { kill(pid, SIGKILL) }
    }
  }

  static let script = #"""
    #!/bin/bash
    D="$FAKE_TART_DIR"
    printf '%s\n' "$*" >> "$D/calls.log"
    case "$1" in
      list)
        printf '['
        for dir in "$TART_HOME"/vms/*/; do
          [ -d "$dir" ] || continue
          name=$(basename "$dir")
          state=$(cat "$D/state-$name" 2>/dev/null || echo stopped)
          printf '{"Name":"%s","Source":"local","State":"%s","Disk":50,"Size":12},' "$name" "$state"
        done
        printf '{"Name":"ghcr.io/cirruslabs/macos-tahoe-base:latest","Source":"OCI","State":"stopped","Disk":50,"Size":20}]\n'
        ;;
      ip) echo "192.168.64.7" ;;
      exec)
        [ -f "$D/agent-answers" ] && exit 0
        echo "Error: failed to connect to the guest agent" >&2
        exit 1
        ;;
      run)
        echo "booting $2"
        if [ -f "$D/run-fails" ]; then
          echo "Error: the virtual machine failed to start" >&2
          exit 1
        fi
        echo running > "$D/state-$2"
        echo $$ >> "$D/launched.pids"
        exec sleep 10
        ;;
      stop)
        [ -f "$D/stop-kills" ] && kill -9 "$(cat "$D/stop-kills")"
        echo stopped > "$D/state-$2"
        ;;
      clone)
        if [ -f "$D/clone-fails" ]; then
          echo "Error: no space left on device" >&2
          exit 1
        fi
        echo "cloning $2..."
        echo "0%"
        echo "40%"
        echo "100%"
        mkdir -p "$TART_HOME/vms/$3"
        cp "$TART_HOME/vms/$2/config.json" "$TART_HOME/vms/$3/config.json"
        ;;
      delete) rm -rf "$TART_HOME/vms/$2" ;;
      *) echo "unexpected $1" >&2; exit 1 ;;
    esac
    """#
}
