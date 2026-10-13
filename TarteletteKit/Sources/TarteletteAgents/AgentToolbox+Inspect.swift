import Foundation
import TarteletteCLI
import TarteletteCore

extension AgentToolbox {
  /// `list_vms`: the local VMs agents may see, with their access.
  ///
  /// Reads each VM's `config.json` for its OS instead of `tart get`, which would bump Tart's
  /// access date. Also forgets registered agent VMs that no longer exist.
  public func listVMs() async throws -> [AgentVMSummary] {
    try await perform(.listVMs, vm: nil) { context in
      let vms = try await localVMs()
      forgetMissingAgentVMs(context.entries)
      var fingerprints: [String: String] = [:]
      for vm in vms {
        fingerprints[vm.name] = VMFingerprint.of(vmNamed: vm.name, paths: tartPaths)
      }
      let visible = context.authorizer.visibleAccess(for: vms.map(\.name), fingerprints: fingerprints)
      let summaries = vms.compactMap { vm in
        visible[vm.name].map { summary(of: vm, configuration: try? client.configuration(of: vm.name), access: $0) }
      }
      return (summaries, "\(summaries.count) VMs")
    }
  }

  /// `vm_info` (inspect): the summary plus CPU, memory and display, and the IP address while running.
  public func vmInfo(name: String) async throws -> AgentVMDetails {
    try await perform(.vmInfo, vm: name) { context in
      let fingerprint = try authorize(.inspect, vm: name, in: context)
      let vm = try await localVM(named: name)
      let configuration = try? client.configuration(of: name)
      var ipAddress: String?
      if vm.state.isRunning {
        ipAddress = try? await client.ipAddress(IPOptions(name: name, waitSeconds: 2))
      }
      let details = AgentVMDetails(
        summary: summary(
          of: vm, configuration: configuration,
          access: context.authorizer.effectiveAccess(for: name, fingerprint: fingerprint)),
        cpuCount: configuration?.cpuCount,
        memoryMB: configuration.map { $0.memorySize / 1_048_576 },
        display: configuration?.display.map { "\($0.width)x\($0.height)" },
        ipAddress: ipAddress)
      return (details, vm.state.rawValue)
    }
  }

  /// Unregisters agent VMs whose directory is gone. Entry by entry rather than `prune(keeping:)`,
  /// so a VM another helper process registers meanwhile is never dropped. Failures are ignored:
  /// the listing doesn't depend on it.
  private func forgetMissingAgentVMs(_ entries: [AgentVMEntry]) {
    for entry in entries where VMFingerprint.of(vmNamed: entry.name, paths: tartPaths) == nil {
      try? registry.unregister(name: entry.name)
    }
  }
}
