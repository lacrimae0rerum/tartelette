import AppKit
import SwiftUI
import TarteletteKit

/// Edits a VM's hardware with `tart set`.
///
/// Tart resets the display-refit setting on every `set` that omits it and clears the display
/// unit whenever `--display` has none, so the draft always carries both forward explicitly.
struct VMConfigurationTab: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model

  @State private var draft: ConfigurationDraft?
  @State private var baseline: ConfigurationDraft?
  @State private var isApplying = false
  @State private var errorMessage: String?
  @State private var confirmation: String?
  /// Identifies the banner on screen, so an older banner's timer never hides a newer one.
  @State private var confirmationToken = UUID()

  var body: some View {
    let current = ConfigurationDraft(config: model.library.config(of: vm.name), listing: vm)

    Group {
      if let current, let draft = Binding($draft) {
        editor(draft: draft, baseline: current)
      } else if current == nil {
        EmptyStateView(
          "Configuration Unavailable", systemImage: "exclamationmark.triangle",
          message: "Tartelette couldn't read this VM's config.json.")
      } else {
        ProgressView()
      }
    }
    .onAppear { adopt(current, force: true) }
    .onChange(of: current) { _, newValue in adopt(newValue, force: false) }
  }

  /// Takes a fresh baseline from disk, keeping unsaved edits unless `force` is set.
  private func adopt(_ newBaseline: ConfigurationDraft?, force: Bool) {
    guard let newBaseline else { return }
    if force || draft == nil || draft == baseline {
      draft = newBaseline
    }
    baseline = newBaseline
  }

  private func editor(draft: Binding<ConfigurationDraft>, baseline: ConfigurationDraft) -> some View {
    let config = model.library.config(of: vm.name)
    let os = model.library.os(of: vm.name)
    let options = draft.wrappedValue.setOptions(name: vm.name, baseline: baseline)
    let problems = draft.wrappedValue.problems(config: config)
    let isLocked = vm.state != .stopped
    let hasChanges = draft.wrappedValue != baseline

    return Form {
      if isLocked {
        Section {
          InlineNotice(
            .warning,
            vm.state == .suspended
              ? "Resume and shut down “\(vm.name)” before changing its hardware. Stopping a suspended VM discards its saved state."
              : "Shut down “\(vm.name)” to change its hardware.")
        }
      }

      ProcessorMemorySection(draft: draft, config: config)
        .disabled(isLocked)
      DisplaySection(draft: draft, os: os)
        .disabled(isLocked)
      DiskSection(draft: draft, baseline: baseline, format: config?.diskFormat)
        .disabled(isLocked)
      IdentitySection(draft: draft, os: os)
        .disabled(isLocked)
      VMAgentAccessSection(vmName: vm.name)

      if !problems.isEmpty {
        Section {
          ForEach(problems, id: \.self) { problem in
            InlineNotice(.error, problem)
          }
        }
      }
    }
    .formStyle(.grouped)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 10) {
        if hasChanges {
          CommandPreview(commandLine: TartCommand.set(options).commandLine)
        }
        if let errorMessage {
          InlineNotice(.error, errorMessage)
        }
        HStack {
          if let confirmation {
            Label(confirmation, systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .font(.callout)
              .transition(.opacity)
          }
          Spacer()
          if isApplying { ProgressView().controlSize(.small) }
          Button("Revert") {
            self.draft = baseline
            errorMessage = nil
          }
          .disabled(!hasChanges || isApplying)
          Button("Apply") { apply(options) }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges || !problems.isEmpty || isLocked || isApplying)
        }
      }
      .padding(16)
      .background(.bar)
    }
  }

  private func apply(_ options: SetOptions) {
    isApplying = true
    errorMessage = nil
    let name = vm.name
    Task {
      do {
        try await model.library.applySettings(options)
      } catch {
        isApplying = false
        errorMessage = error.localizedDescription
        return
      }
      // Take the new baseline only after the library has re-read both config.json and the listing
      // (disk capacity), so the draft never starts from stale values.
      await model.library.refresh()
      isApplying = false
      if let listing = model.library.vm(named: name) {
        adopt(ConfigurationDraft(config: model.library.config(of: name), listing: listing), force: true)
      }
      showConfirmation("Saved. Changes take effect the next time the VM starts.")
    }
  }

  private func showConfirmation(_ message: String) {
    let token = UUID()
    confirmationToken = token
    withAnimation { confirmation = message }
    Task {
      try? await Task.sleep(for: .seconds(4))
      if confirmationToken == token { withAnimation { confirmation = nil } }
    }
  }
}

// MARK: - Draft

/// The editable subset of `config.json`, compared with the saved values to build `tart set`.
struct ConfigurationDraft: Equatable {
  enum DisplayUnit: String, CaseIterable, Identifiable {
    case automatic = "", points = "pt", pixels = "px"
    var id: String { rawValue }

    var title: String {
      switch self {
      case .automatic: "Automatic"
      case .points: "Points"
      case .pixels: "Pixels"
      }
    }
  }

  enum Refit: String, CaseIterable, Identifiable {
    case automatic, on, off
    var id: String { rawValue }

    init(_ value: Bool?) {
      self =
        switch value {
        case true?: .on
        case false?: .off
        case nil: .automatic
        }
    }

    var value: Bool? {
      switch self {
      case .automatic: nil
      case .on: true
      case .off: false
      }
    }
  }

  var cpuCount: Int
  var memoryMB: UInt64
  var width: Int
  var height: Int
  var unit: DisplayUnit
  var refit: Refit
  var diskSizeGB: Int
  /// False when Tart couldn't report the disk's capacity (e.g. an ASIF disk held by a running VM);
  /// the size can't be changed then, because growing needs a known starting point.
  var isDiskCapacityKnown: Bool
  var replacementDiskPath: String?
  var randomMAC = false
  var randomSerial = false

  init?(config: VMConfigFile?, listing: VMListing) {
    guard let config else { return nil }
    cpuCount = config.cpuCount
    memoryMB = config.memorySize / 1024 / 1024
    width = config.display?.width ?? 1024
    height = config.display?.height ?? 768
    unit = DisplayUnit(rawValue: config.display?.unit ?? "") ?? .automatic
    refit = Refit(config.displayRefit)
    if let capacity = listing.diskGB, capacity.isFinite, capacity >= 0, capacity < 1_000_000 {
      diskSizeGB = Int(capacity)
      isDiskCapacityKnown = true
    } else {
      diskSizeGB = 0
      isDiskCapacityKnown = false
    }
  }

  var displayArgument: String { "\(width)x\(height)\(unit.rawValue)" }

  /// Only changed fields go into `tart set`, except display refit, which Tart would otherwise reset.
  func setOptions(name: String, baseline: ConfigurationDraft) -> SetOptions {
    let displayChanged = width != baseline.width || height != baseline.height || unit != baseline.unit
    return SetOptions(
      name: name,
      cpuCount: cpuCount != baseline.cpuCount ? cpuCount : nil,
      memoryMB: memoryMB != baseline.memoryMB ? memoryMB : nil,
      display: displayChanged ? displayArgument : nil,
      displayRefit: refit.value,
      randomMAC: randomMAC,
      randomSerial: randomSerial,
      diskPath: replacementDiskPath,
      diskSizeGB: baseline.isDiskCapacityKnown && diskSizeGB > baseline.diskSizeGB ? diskSizeGB : nil
    )
  }

  func problems(config: VMConfigFile?) -> [String] {
    var problems: [String] = []
    let minimumCPU = max(1, config?.cpuCountMin ?? 1)
    if cpuCount < minimumCPU { problems.append("This VM needs at least \(minimumCPU) CPUs.") }
    if let minimum = config?.memorySizeMin, memoryMB * 1024 * 1024 < minimum {
      problems.append("This VM needs at least \(Formatting.memory(minimum)) of memory.")
    }
    if width < 320 || height < 240 { problems.append("The display must be at least 320 × 240.") }
    if let path = replacementDiskPath, !FileManager.default.fileExists(atPath: path) {
      problems.append("The replacement disk image no longer exists.")
    }
    return problems
  }
}

// MARK: - Sections

private struct ProcessorMemorySection: View {
  @Binding var draft: ConfigurationDraft
  let config: VMConfigFile?

  private var hostCores: Int { ProcessInfo.processInfo.activeProcessorCount }
  private var hostMemoryMB: UInt64 { ProcessInfo.processInfo.physicalMemory / 1024 / 1024 }

  var body: some View {
    let minimumCPU = max(1, config?.cpuCountMin ?? 1)
    let minimumMB = max(512, (config?.memorySizeMin ?? 0) / 1024 / 1024)
    let maximumMB = max(minimumMB, hostMemoryMB)

    Section {
      LabeledContent {
        HStack(spacing: 8) {
          Text("\(draft.cpuCount)")
            .monospacedDigit()
            .frame(minWidth: 24, alignment: .trailing)
          Stepper("Processors", value: $draft.cpuCount, in: minimumCPU...max(minimumCPU, hostCores))
            .labelsHidden()
        }
      } label: {
        Text("Processors")
        Text("This Mac has \(hostCores) cores.")
      }

      LabeledContent {
        HStack(spacing: 10) {
          Slider(
            value: Binding(
              get: { Double(draft.memoryMB) },
              set: { draft.memoryMB = UInt64(($0 / 512).rounded() * 512) }),
            in: Double(minimumMB)...Double(maximumMB)
          )
          .frame(minWidth: 160)
          Text(Formatting.megabytes(draft.memoryMB))
            .monospacedDigit()
            .frame(minWidth: 56, alignment: .trailing)
          Stepper(
            "Memory", value: $draft.memoryMB, in: minimumMB...maximumMB, step: 512
          )
          .labelsHidden()
        }
      } label: {
        Text("Memory")
        Text(memoryCaption(minimumMB: minimumMB))
      }
    } header: {
      Text("Processor & Memory")
    }
  }

  private func memoryCaption(minimumMB: UInt64) -> String {
    let host = Formatting.memory(ProcessInfo.processInfo.physicalMemory)
    if draft.memoryMB * 4 > hostMemoryMB * 3 {
      return "Leaving little memory for macOS (\(host) installed) can slow everything down."
    }
    return "Minimum \(Formatting.megabytes(minimumMB)) · this Mac has \(host)."
  }
}

private struct DisplaySection: View {
  @Binding var draft: ConfigurationDraft
  let os: VMOperatingSystem

  private static let presets: [(String, Int, Int)] = [
    ("1024 × 768", 1024, 768), ("1280 × 800", 1280, 800), ("1440 × 900", 1440, 900),
    ("1680 × 1050", 1680, 1050), ("1920 × 1080", 1920, 1080), ("1920 × 1200", 1920, 1200),
    ("2560 × 1440", 2560, 1440), ("3840 × 2160", 3840, 2160),
  ]

  var body: some View {
    Section {
      LabeledContent("Resolution") {
        HStack(spacing: 6) {
          TextField("Width", value: $draft.width, format: .number.grouping(.never))
            .labelsHidden()
            .frame(width: 72)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("Width")
          Text("×").foregroundStyle(.secondary)
          TextField("Height", value: $draft.height, format: .number.grouping(.never))
            .labelsHidden()
            .frame(width: 72)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("Height")
          Menu {
            ForEach(Self.presets, id: \.0) { preset in
              Button(preset.0) {
                draft.width = preset.1
                draft.height = preset.2
              }
            }
          } label: {
            Image(systemName: "rectangle.3.group")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("Common resolutions")
        }
        .textFieldStyle(.roundedBorder)
      }

      Picker(selection: $draft.unit) {
        ForEach(ConfigurationDraft.DisplayUnit.allCases) { unit in
          Text(unit.title).tag(unit)
        }
      } label: {
        Text("Units")
        Text(
          os == .linux
            ? "Linux guests always use pixels."
            : "Points size the display for this Mac's screen (Retina-sharp); pixels are exact.")
      }

      Picker(selection: $draft.refit) {
        Text("Automatic").tag(ConfigurationDraft.Refit.automatic)
        Text("Resize with window").tag(ConfigurationDraft.Refit.on)
        Text("Keep fixed size").tag(ConfigurationDraft.Refit.off)
      } label: {
        Text("Window resizing")
        Text("Automatic resizes macOS guests and keeps Linux guests fixed.")
      }
    } header: {
      Text("Display")
    }
  }
}

private struct DiskSection: View {
  @Binding var draft: ConfigurationDraft
  let baseline: ConfigurationDraft
  let format: String?

  var body: some View {
    Section {
      if baseline.isDiskCapacityKnown {
        LabeledContent {
          HStack(spacing: 8) {
            Text("\(draft.diskSizeGB) GB").monospacedDigit()
            Stepper(
              "Disk size", value: $draft.diskSizeGB, in: baseline.diskSizeGB...max(baseline.diskSizeGB, 4_000), step: 10
            )
            .labelsHidden()
          }
        } label: {
          Text("Disk size")
          Text(
            draft.diskSizeGB > baseline.diskSizeGB
              ? "The guest must grow its partition afterwards (the guest agent does this on Cirrus Labs images)."
              : "Disks can only grow. They take space on this Mac only as the guest writes.")
        }
      } else {
        LabeledContent {
          Text("Unknown").foregroundStyle(.secondary)
        } label: {
          Text("Disk size")
          Text("Tart couldn't report this disk's capacity right now, so it can't be resized. Stop the VM and try again.")
        }
      }

      LabeledContent {
        HStack {
          if let path = draft.replacementDiskPath {
            Text((path as NSString).abbreviatingWithTildeInPath)
              .lineLimit(1)
              .truncationMode(.middle)
            Button {
              draft.replacementDiskPath = nil
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Keep the current disk")
          }
          Button("Choose…") { chooseDisk() }
        }
      } label: {
        Text("Replace contents")
        Text(
          draft.replacementDiskPath == nil
            ? "Copy a raw disk image over this VM's disk."
            : "Everything on the current disk will be overwritten.")
      }
    } header: {
      HStack {
        Text("Storage")
        Spacer()
        if let format {
          Text(format.uppercased()).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func chooseDisk() {
    let panel = NSOpenPanel()
    panel.title = "Choose a Disk Image"
    panel.message = "Its contents replace the VM's disk."
    panel.prompt = "Choose"
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      draft.replacementDiskPath = url.path
    }
  }
}

private struct IdentitySection: View {
  @Binding var draft: ConfigurationDraft
  let os: VMOperatingSystem

  var body: some View {
    Section {
      Toggle(isOn: $draft.randomMAC) {
        Text("Generate a new MAC address")
        Text("Gives the VM a new network identity and, usually, a new IP address.")
      }
      if os == .macOS {
        Toggle(isOn: $draft.randomSerial) {
          Text("Generate a new serial number")
          Text("Makes macOS treat the VM as a different Mac (for example, for Apple Account sign-in).")
        }
      }
    } header: {
      Text("Identity")
    }
  }
}
