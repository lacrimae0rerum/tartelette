import Foundation

/// The tools agents can call, named as the MCP server exposes them and as the audit log records them.
public enum AgentTool: String, Sendable, Hashable, CaseIterable, Codable {
  case listVMs = "list_vms"
  case vmInfo = "vm_info"
  case startVM = "start_vm"
  case stopVM = "stop_vm"
  case createSandbox = "create_sandbox"
  case deleteVM = "delete_vm"
  case exec
  case readFile = "read_file"
  case writeFile = "write_file"
}
