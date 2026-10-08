import SwiftUI
import TarteletteKit

/// “Stop with Options…”: choose between a guest shutdown, a power-off with a timeout, suspending,
/// or (for suspended VMs) discarding the saved state.
struct StopOptionsSheet: View {
  let vmName: String
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var method: Method = .shutdown
  @State private var timeout = TartCommand.defaultStopTimeoutSeconds

  private enum Method: String, CaseIterable, Identifiable {
    case shutdown, powerOff, suspend
    var id: String { rawValue }
  }

  var body: some View {
    let library = model.library
    let state = library.state(of: vmName)

    SheetScaffold(
      title: state == .suspended ? "Discard Suspended State" : "Stop “\(vmName)”",
      subtitle: subtitle(state),
      systemImage: state == .suspended ? "pause.circle" : "stop.circle",
      commandLine: commandLine(state),
      primaryTitle: primaryTitle(state),
      primaryRole: state == .suspended ? .destructive : nil,
      isPrimaryDisabled: state == .stopped,
      onPrimary: { perform(state) }
    ) {
      switch state {
      case .running:
        runningOptions(canSuspend: library.canSuspend(vmName))
      case .suspended:
        InlineNotice(
          .warning,
          "“\(vmName)” is suspended. Stopping it deletes the saved memory snapshot; the next start boots from scratch and unsaved work in the VM is lost.")
      case .stopped, .unknown:
        InlineNotice(.info, "“\(vmName)” isn't running.")
      }
    }
    .onAppear {
      timeout = model.profiles.profile(for: vmName).stopTimeout
    }
  }

  @ViewBuilder
  private func runningOptions(canSuspend: Bool) -> some View {
    Picker("Method", selection: $method) {
      Text("Shut down").tag(Method.shutdown)
      Text("Power off").tag(Method.powerOff)
      if canSuspend {
        Text("Suspend").tag(Method.suspend)
      }
    }
    .pickerStyle(.radioGroup)
    .labelsHidden()

    switch method {
    case .shutdown:
      Text(
        "Asks the guest operating system to shut down, like choosing Shut Down from its menu. Apps can save their work; the guest may ask for confirmation."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    case .powerOff:
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Turns the VM off immediately, like holding down the power button. Unsaved work in the guest is lost."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Stepper(value: $timeout, in: 1...600) {
          LabeledContent("Force quit Tart after") {
            Text("\(timeout) s").monospacedDigit()
          }
        }
        .frame(maxWidth: 320)
      }
    case .suspend:
      Text("Saves the VM's memory to disk and stops it. Starting it again resumes exactly where it left off.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func subtitle(_ state: VMState) -> String {
    switch state {
    case .running: "Choose how to stop the VM."
    case .suspended: "The VM's saved state will be removed."
    default: "Nothing to stop."
    }
  }

  private func primaryTitle(_ state: VMState) -> String {
    if state == .suspended { return "Discard State" }
    guard state == .running else { return "Stop" }
    switch method {
    case .shutdown: return "Shut Down"
    case .powerOff: return "Power Off"
    case .suspend: return "Suspend"
    }
  }

  private func commandLine(_ state: VMState) -> String? {
    switch (state, method) {
    case (.suspended, _), (.running, .powerOff):
      TartCommand.stop(name: vmName, timeoutSeconds: timeout).commandLine
    case (.running, .suspend):
      TartCommand.suspend(name: vmName).commandLine
    case (.running, .shutdown):
      model.library.pid(of: vmName).map { "kill -USR2 \($0)  # asks “\(vmName)” to shut down" }
    default:
      nil
    }
  }

  private func perform(_ state: VMState) {
    let library = model.library
    switch (state, method) {
    case (.suspended, _), (.running, .powerOff):
      library.stop(vmName, timeout: timeout)
    case (.running, .shutdown):
      library.requestShutdown(vmName)
    case (.running, .suspend):
      library.suspend(vmName)
    default:
      break
    }
    dismiss()
  }
}
