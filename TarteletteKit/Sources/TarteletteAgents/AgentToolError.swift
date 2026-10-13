import Foundation
import TarteletteCore

/// Why an agent tool call failed, phrased for a person reading the agent's transcript.
///
/// Refusals by the user's agent settings are `AgentDenial`s; Tart's own failures are `TartError`s.
public enum AgentToolError: Error, Sendable, Equatable, LocalizedError {
  /// `agents.json` exists but couldn't be read or decoded, so everything is refused.
  case settingsUnreadable(detail: String)
  /// Not a name agents may use (see `AgentToolbox.isValidVMName(_:)`).
  case invalidName(String)
  case vmNotFound(String)
  case nameTaken(String)
  case tooManyAgentVMs(limit: Int)
  /// Cloning needs a stopped source VM.
  case sourceNotStopped(String)
  /// Starting the VM would exceed `VirtualizationLimits.maximumConcurrentMacOSGuests`.
  case macOSGuestLimitReached(vm: String)
  /// The VM didn't reach the awaited state in time, e.g. `waitingFor: "stop"`.
  case timedOut(vm: String, waitingFor: String, seconds: Int)
  case tartNotFound
  /// `tart run` exited while the VM was starting; `logTail` holds the last lines of its log.
  case startFailed(vm: String, logTail: String)
  /// A new VM's directory couldn't be identified, so it couldn't be recorded as an agent VM.
  case unidentifiedVM(String)

  public var errorDescription: String? {
    switch self {
    case .settingsUnreadable(let detail):
      "Tartelette's agent settings couldn't be read, so agent access is refused. "
        + "Check them in Tartelette › Settings › Agents. (\(detail))"
    case .invalidName(let name):
      "“\(name.prefix(80))” isn't a valid VM name. Names have 1 to 64 letters, digits, “.”, “_” or “-”, "
        + "and start with a letter or digit."
    case .vmNotFound(let name):
      "There is no local VM named “\(name)”. Call list_vms to see the VMs shared with agents."
    case .nameTaken(let name):
      "A VM named “\(name)” already exists. Choose another name."
    case .tooManyAgentVMs(let limit):
      "Agents already have \(limit) VMs, the most Tartelette allows. Delete one with delete_vm, "
        + "or raise the limit in Tartelette › Settings › Agents."
    case .sourceNotStopped(let name):
      "Stop “\(name)” before cloning it."
    case .macOSGuestLimitReached(let name):
      "macOS allows at most \(VirtualizationLimits.maximumConcurrentMacOSGuests) macOS VMs to run at the same time. "
        + "Stop one of them before starting “\(name)”."
    case .timedOut(let name, let waitingFor, let seconds):
      "Timed out after \(seconds) seconds waiting for “\(name)” to \(waitingFor)."
    case .tartNotFound:
      "Tartelette couldn't find the tart executable. Install Tart (brew install cirruslabs/cli/tart) "
        + "or choose its location in Tartelette › Settings."
    case .startFailed(let name, let logTail):
      "“\(name)” failed to start." + (logTail.isEmpty ? "" : " The end of its log:\n\(logTail)")
    case .unidentifiedVM(let name):
      "“\(name)” was created, but Tartelette couldn't identify its directory, so agents can't manage it. "
        + "Delete it in Tartelette."
    }
  }
}
