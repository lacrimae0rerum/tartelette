import AppKit
import SwiftUI
import TarteletteKit
import Virtualization

/// Edits every `tart run` option of a VM's run profile, plus the app-level choices that shape the
/// launch (clipboard engine, IP resolver, stop timeout).
///
/// Shared by the Run Options tab and the “Start with Options…” sheet. Options the installed Tart
/// doesn't support, or that don't apply to the guest OS or this Mac, are disabled with a reason.
struct RunOptionsEditor: View {
  @Binding var profile: RunProfile
  let vmName: String
  let os: VMOperatingSystem

  var body: some View {
    Form {
      DisplayOptionsSection(profile: $profile, os: os)
      ClipboardOptionsSection(profile: $profile, os: os)
      NetworkOptionsSection(options: $profile.options)
      SharingOptionsSection(options: $profile.options, os: os)
      DiskOptionsSection(options: $profile.options)
      DeviceOptionsSection(profile: $profile, os: os)
      if os == .macOS {
        ProvisioningOptionsSection(options: $profile.options)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Validation

/// Problems Tart would reject (errors) or that are likely surprises (warnings), checked before
/// launching so the user sees them inline instead of as a failed start.
struct RunOptionsIssue: Hashable, Identifiable {
  enum Severity { case error, warning, info }
  var id: String { message }
  let severity: Severity
  let message: String
}

enum RunOptionsValidation {
  static func issues(for profile: RunProfile, os: VMOperatingSystem, softnet: SoftnetState) -> [RunOptionsIssue] {
    let options = profile.options
    var issues: [RunOptionsIssue] = []
    func error(_ message: String) { issues.append(RunOptionsIssue(severity: .error, message: message)) }
    func warning(_ message: String) { issues.append(RunOptionsIssue(severity: .warning, message: message)) }
    func info(_ message: String) { issues.append(RunOptionsIssue(severity: .info, message: message)) }

    if options.captureSystemKeys, options.display != .window {
      error("Sending system shortcuts to the guest only works with Tart's window.")
    }
    if options.suspendable {
      if os != .macOS { error("Only macOS VMs can be suspended.") }
      if options.noTrackpad || options.noKeyboard || options.noPointer {
        error("Suspendable VMs need their keyboard, pointer and trackpad.")
      }
      if profile.clipboardEngine.resolved(for: os) == .spice {
        info("Tart's built-in clipboard doesn't work with suspendable VMs; use the Tartelette bridge instead.")
      }
    }
    if options.noTrackpad, os != .macOS { error("The trackpad option only applies to macOS VMs.") }
    if options.nested {
      if os == .macOS { error("macOS VMs don't support nested virtualization.") }
      if !HostSupport.nestedVirtualization {
        error("Nested virtualization needs a Mac with an M3 chip or later running macOS 15 or later.")
      }
    }
    if options.rosettaTag?.isEmpty == false, os == .macOS { error("Rosetta sharing is for Linux VMs.") }
    if options.provisioning?.isEmpty == false {
      if os != .macOS { error("Provisioning is for macOS VMs.") }
      if !HostSupport.atLeast(27) { error("Provisioning needs macOS 27 or later on this Mac.") }
    }
    if options.serial, options.serialPath?.isEmpty == false {
      warning("A serial device path is ignored while “Open a serial console” is on.")
    }

    let byTag = Dictionary(grouping: options.directories.filter { !$0.path.isEmpty }) { $0.tag ?? "" }
    for (tag, shares) in byTag where shares.count > 1 && shares.contains(where: { ($0.name ?? "").isEmpty }) {
      error(
        tag.isEmpty
          ? "When sharing several folders with the default mount tag, give each one a name."
          : "Folders sharing the mount tag “\(tag)” each need a name.")
    }
    for share in options.directories where !share.path.isEmpty && !share.path.hasPrefix("http") {
      let path = (share.path as NSString).expandingTildeInPath
      if !FileManager.default.fileExists(atPath: path) { warning("The shared folder “\(share.path)” doesn't exist.") }
    }
    for disk in options.disks where disk.location.hasSuffix("-amd64.iso") {
      error("“\((disk.location as NSString).lastPathComponent)” targets Intel PCs. Use the arm64 version.")
    }
    for disk in options.disks where disk.location.isEmpty {
      error("An additional disk has no location.")
    }

    switch options.network {
    case .shared: break
    case .bridged(let interfaces):
      if interfaces.isEmpty { error("Choose at least one network interface to bridge.") }
    case .softnet:
      switch softnet {
      case .missing: error("Softnet isn't installed. Install it with “brew install cirruslabs/cli/softnet”.")
      case .unprivileged: warning("Softnet needs administrator setup before it can run from Tartelette.")
      case .ready, .unknown: break
      }
    case .hostOnly:
      if !HostSupport.atLeast(26) { error("Host-only networking needs macOS 26 or later on this Mac.") }
    }

    if options.display == .vnc {
      info("Screen Sharing needs Remote Login enabled in the guest.")
    }
    return issues
  }
}

/// Facts about this Mac that gate run options.
enum HostSupport {
  static func atLeast(_ major: Int) -> Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0))
  }

  static var nestedVirtualization: Bool {
    if #available(macOS 15, *) {
      return VZGenericPlatformConfiguration.isNestedVirtualizationSupported
    }
    return false
  }

  static var rosettaAvailability: String? {
    #if arch(arm64)
      switch VZLinuxRosettaDirectoryShare.availability {
      case .installed: nil
      case .notInstalled: "Rosetta isn't installed. Install it with “softwareupdate --install-rosetta”."
      case .notSupported: "Rosetta isn't supported on this Mac."
      @unknown default: nil
      }
    #else
      "Rosetta sharing needs a Mac with Apple silicon."
    #endif
  }
}

/// Whether Tart's userspace network filter can run.
enum SoftnetState: Equatable {
  case unknown, missing, unprivileged, ready

  @MainActor
  static func inspect(_ context: TartContext) -> SoftnetState {
    guard let environment = context.environment else { return .unknown }
    guard let url = SoftnetSupport.locate(environment: environment) else { return .missing }
    return SoftnetSupport.isPrivileged(url) ? .ready : .unprivileged
  }
}

/// Renders validation issues as inline notices.
struct RunOptionsIssueList: View {
  let issues: [RunOptionsIssue]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(issues) { issue in
        switch issue.severity {
        case .error: InlineNotice(.error, issue.message)
        case .warning: InlineNotice(.warning, issue.message)
        case .info: InlineNotice(.info, issue.message)
        }
      }
    }
  }
}

// MARK: - Capability helper

/// Disables a control and explains why when the installed Tart lacks a `run` flag.
private struct RequiresFlag: ViewModifier {
  let flag: String
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View {
    let supported = model.context.capabilities.supports("run", option: flag)
    content
      .disabled(!supported)
      .help(supported ? "" : "The installed Tart doesn't support \(flag). Update Tart to use it.")
  }
}

extension View {
  fileprivate func requiresFlag(_ flag: String) -> some View { modifier(RequiresFlag(flag: flag)) }
}

// MARK: - Display

private struct DisplayOptionsSection: View {
  @Binding var profile: RunProfile
  let os: VMOperatingSystem

  var body: some View {
    Section {
      Picker(selection: $profile.options.display) {
        Text("Tart window").tag(RunOptions.DisplayMode.window)
        Text("No window (headless)").tag(RunOptions.DisplayMode.headless)
        Text("Screen Sharing").tag(RunOptions.DisplayMode.vnc)
        Text("VNC (Virtualization framework)").tag(RunOptions.DisplayMode.vncExperimental)
      } label: {
        Text("Show the VM in")
        Text(displayCaption)
      }

      if profile.options.display == .vnc || profile.options.display == .vncExperimental {
        Toggle(isOn: $profile.options.showWindowWithVNC) {
          Text("Also open Tart's window")
        }
      }

      Toggle(isOn: $profile.options.captureSystemKeys) {
        Text("Send system shortcuts to the guest")
        Text("⌘Tab, ⌘Space and similar go to the VM while its window is active.")
      }
      .disabled(profile.options.display != .window)
      .requiresFlag("--capture-system-keys")

      if os == .macOS {
        Toggle(isOn: $profile.options.recovery) {
          Text("Start in macOS Recovery")
          Text("Boots the recovery system, e.g. to change security settings or resize partitions.")
        }
        .requiresFlag("--recovery")
      }
    } header: {
      Text("Display")
    }
  }

  private var displayCaption: String {
    switch profile.options.display {
    case .window: "Tart's own window with the VM's screen."
    case .headless: "No window. Reach the VM with Terminal, SSH or the console."
    case .vnc: "macOS Screen Sharing: copy and paste, drag and drop. Needs Remote Login in the guest."
    case .vncExperimental: "Built-in VNC server. Works during macOS installation and in Recovery."
    }
  }
}

// MARK: - Clipboard

private struct ClipboardOptionsSection: View {
  @Binding var profile: RunProfile
  let os: VMOperatingSystem

  var body: some View {
    Section {
      Picker(selection: $profile.clipboardEngine) {
        ForEach(ClipboardEngine.allCases) { engine in
          Text(engine.title).tag(engine)
        }
      } label: {
        Text("Copy and paste")
        Text(caption)
      }

      Picker(selection: $profile.ipResolver) {
        Text("DHCP leases").tag(IPOptions.Resolver.dhcp)
        Text("ARP table").tag(IPOptions.Resolver.arp)
        Text("Guest agent").tag(IPOptions.Resolver.agent)
      } label: {
        Text("Find the IP address with")
        Text("Use ARP or the guest agent for bridged networking.")
      }
    } header: {
      Text("Clipboard & Address")
    }
  }

  private var caption: String {
    let resolved = profile.clipboardEngine.resolved(for: os)
    let summary = resolved.summary
    if profile.clipboardEngine == .automatic {
      return "Uses \(resolved.title) for \(os.displayName) guests. \(summary)"
    }
    return summary
  }
}

// MARK: - Network

private enum NetworkMode: String, CaseIterable, Identifiable {
  case shared, bridged, softnet, hostOnly
  var id: String { rawValue }

  init(_ network: RunOptions.Network) {
    self =
      switch network {
      case .shared: .shared
      case .bridged: .bridged
      case .softnet: .softnet
      case .hostOnly: .hostOnly
      }
  }

  var title: String {
    switch self {
    case .shared: "Shared (NAT)"
    case .bridged: "Bridged"
    case .softnet: "Softnet (isolated)"
    case .hostOnly: "Host only"
    }
  }

  var flag: String? {
    switch self {
    case .shared: nil
    case .bridged: "--net-bridged"
    case .softnet: "--net-softnet"
    case .hostOnly: "--net-host"
    }
  }
}

private struct NetworkOptionsSection: View {
  @Binding var options: RunOptions
  @Environment(AppModel.self) private var model
  @State private var interfaces: [BridgedInterface] = []
  @State private var softnet: SoftnetState = .unknown
  @State private var isEnablingSoftnet = false

  var body: some View {
    let mode = NetworkMode(options.network)

    Section {
      Picker(selection: Binding(get: { mode }, set: select)) {
        ForEach(NetworkMode.allCases) { candidate in
          Text(candidate.title)
            .tag(candidate)
            .selectionDisabled(!isAvailable(candidate))
        }
      } label: {
        Text("Network")
        Text(caption(for: mode))
      }

      switch options.network {
      case .shared:
        EmptyView()
      case .bridged(let selected):
        bridgedRows(selected: selected)
      case .softnet(let softnetOptions):
        softnetRows(softnetOptions)
      case .hostOnly:
        if !HostSupport.atLeast(26) {
          InlineNotice(.error, "Host-only networking needs macOS 26 or later on this Mac.")
        }
      }
    } header: {
      Text("Network")
    }
    .task {
      interfaces = NetworkInterfaces.bridgeable()
      softnet = SoftnetState.inspect(model.context)
    }
  }

  private func isAvailable(_ mode: NetworkMode) -> Bool {
    guard let flag = mode.flag else { return true }
    if mode == .hostOnly, !HostSupport.atLeast(26) { return false }
    return model.context.capabilities.supports("run", option: flag)
  }

  private func caption(for mode: NetworkMode) -> String {
    switch mode {
    case .shared: "The VM shares this Mac's connection through NAT."
    case .bridged: "The VM joins the network directly and gets its own address from your router."
    case .softnet: "NAT with a packet filter: the VM can only reach the internet unless you allow more."
    case .hostOnly: "The VM can only talk to this Mac and other VMs."
    }
  }

  private func select(_ mode: NetworkMode) {
    switch mode {
    case .shared: options.network = .shared
    case .bridged:
      let preferred = interfaces.first.map { [$0.bsdName] } ?? []
      options.network = .bridged(interfaces: preferred)
    case .softnet: options.network = .softnet(RunOptions.SoftnetOptions())
    case .hostOnly: options.network = .hostOnly
    }
  }

  @ViewBuilder
  private func bridgedRows(selected: [String]) -> some View {
    if interfaces.isEmpty {
      Text("No network interfaces can be bridged on this Mac.")
        .foregroundStyle(.secondary)
    }
    ForEach(interfaces) { interface in
      Toggle(
        isOn: Binding(
          get: { selected.contains(interface.bsdName) },
          set: { isOn in
            var updated = selected.filter { $0 != interface.bsdName }
            if isOn { updated.append(interface.bsdName) }
            options.network = .bridged(interfaces: updated)
          })
      ) {
        Text(interface.displayName ?? interface.bsdName)
        Text(interface.bsdName).font(.caption.monospaced())
      }
    }
    Text("Each selected interface adds a network card to the VM.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func softnetRows(_ softnetOptions: RunOptions.SoftnetOptions) -> some View {
    let binding = Binding<RunOptions.SoftnetOptions>(
      get: { softnetOptions },
      set: { options.network = .softnet($0) })

    switch softnet {
    case .missing:
      InlineNotice(.error, "Softnet isn't installed. Install it with “brew install cirruslabs/cli/softnet”.")
    case .unprivileged:
      InlineNotice(
        .warning, "Softnet must run as root. Tart only sets this up in a terminal, so Tartelette can do it for you.",
        actionTitle: isEnablingSoftnet ? "Setting Up…" : "Set Up…"
      ) { enableSoftnet() }
    case .ready, .unknown:
      EmptyView()
    }

    TokenListEditor(
      title: "Also allow", tokens: binding.allow, placeholder: "192.168.0.0/24",
      validator: NetworkValidators.cidr)
    TokenListEditor(
      title: "Block", tokens: binding.block, placeholder: "0.0.0.0/0", validator: NetworkValidators.cidr)
    TokenListEditor(
      title: "Forward ports (outside:inside)", tokens: binding.expose, placeholder: "2222:22",
      validator: NetworkValidators.portMapping)
    Text("The longest matching prefix wins; blocking wins a tie. Forwarded ports are reachable from your network, not from this Mac.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func enableSoftnet() {
    guard let environment = model.context.environment, let url = SoftnetSupport.locate(environment: environment) else {
      return
    }
    isEnablingSoftnet = true
    Task {
      defer { isEnablingSoftnet = false }
      do {
        try await SoftnetSupport.enablePrivileges(for: url, runner: model.context.runner)
      } catch is CancellationError {
      } catch ProcessRunError.cancelled {
      } catch {
        model.navigation.show(error: error, title: "Couldn't set up Softnet")
      }
      softnet = SoftnetState.inspect(model.context)
    }
  }
}

/// Input checks for network token lists.
enum NetworkValidators {
  static func cidr(_ value: String) -> String? {
    let parts = value.split(separator: "/")
    guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
      return "Use CIDR notation, e.g. 10.0.0.0/8."
    }
    let octets = parts[0].split(separator: ".")
    guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else {
      return "“\(parts[0])” isn't an IPv4 address."
    }
    return nil
  }

  static func portMapping(_ value: String) -> String? {
    let parts = value.split(separator: ":")
    guard parts.count == 2, let outside = UInt16(parts[0]), let inside = UInt16(parts[1]), outside > 0, inside > 0 else {
      return "Use OUTSIDE:INSIDE port numbers, e.g. 8080:80."
    }
    return nil
  }
}

// MARK: - Sharing

private struct SharingOptionsSection: View {
  @Binding var options: RunOptions
  let os: VMOperatingSystem

  var body: some View {
    Section {
      if options.directories.isEmpty {
        Text("No shared folders.")
          .foregroundStyle(.secondary)
      }
      ForEach($options.directories) { $share in
        DirectoryShareRow(share: $share) {
          options.directories.removeAll { $0.id == share.id }
        }
      }
      HStack {
        Button("Add Folder…", systemImage: "folder.badge.plus") { addFolders() }
        Spacer()
      }
      .requiresFlag("--dir")
      Text(
        os == .linux
          ? "Mount in the guest with: mount -t virtiofs com.apple.virtio-fs.automount /mnt/shared"
          : "Shared folders appear in /Volumes/My Shared Files in the guest."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)

      if os == .linux {
        RosettaRow(options: $options)
      }
    } header: {
      Text("Shared Folders")
    }
  }

  private func addFolders() {
    let panel = NSOpenPanel()
    panel.title = "Share Folders with the VM"
    panel.prompt = "Share"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    let existingNames = Set(options.directories.compactMap(\.name))
    for url in panel.urls {
      let path = (url.path as NSString).abbreviatingWithTildeInPath
      var share = RunOptions.DirectoryShare(path: path)
      // Several folders on the default tag must be named; name them after the folder.
      if !options.directories.isEmpty || panel.urls.count > 1 {
        let base = url.lastPathComponent
        share.name = existingNames.contains(base) ? "\(base)-\(options.directories.count + 1)" : base
      }
      options.directories.append(share)
    }
    if options.directories.count > 1 {
      for index in options.directories.indices where (options.directories[index].name ?? "").isEmpty {
        options.directories[index].name = URL(fileURLWithPath: options.directories[index].path).lastPathComponent
      }
    }
  }
}

private struct DirectoryShareRow: View {
  @Binding var share: RunOptions.DirectoryShare
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: (share.path as NSString).expandingTildeInPath))
          .resizable()
          .frame(width: 18, height: 18)
        Text(share.path)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Spacer()
        Toggle("Read only", isOn: $share.readOnly)
          .toggleStyle(.checkbox)
        Button(role: .destructive, action: onRemove) {
          Image(systemName: "minus.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Stop sharing \(share.path)")
      }
      HStack(spacing: 8) {
        TextField(
          "Name", text: Binding(get: { share.name ?? "" }, set: { share.name = $0.isEmpty ? nil : $0 }),
          prompt: Text("Name (optional)"))
        TextField(
          "Mount tag", text: Binding(get: { share.tag ?? "" }, set: { share.tag = $0.isEmpty ? nil : $0 }),
          prompt: Text("Mount tag (default automount)"))
      }
      .textFieldStyle(.roundedBorder)
      .controlSize(.small)
    }
    .padding(.vertical, 2)
  }
}

private struct RosettaRow: View {
  @Binding var options: RunOptions

  var body: some View {
    let enabled = Binding(
      get: { options.rosettaTag?.isEmpty == false },
      set: { options.rosettaTag = $0 ? (options.rosettaTag?.isEmpty == false ? options.rosettaTag : "rosetta") : nil })

    Toggle(isOn: enabled) {
      Text("Share Rosetta for x86-64 binaries")
      Text(HostSupport.rosettaAvailability ?? "Mount the share in the guest and register it with binfmt.")
    }
    .disabled(HostSupport.rosettaAvailability != nil && !enabled.wrappedValue)
    .requiresFlag("--rosetta")

    if enabled.wrappedValue {
      TextField(
        "Mount tag", text: Binding(get: { options.rosettaTag ?? "" }, set: { options.rosettaTag = $0 }),
        prompt: Text("rosetta"))
    }
  }
}

// MARK: - Disks

private struct DiskOptionsSection: View {
  @Binding var options: RunOptions
  @Environment(AppModel.self) private var model

  var body: some View {
    Section {
      if options.disks.isEmpty {
        Text("No additional disks.")
          .foregroundStyle(.secondary)
      }
      ForEach($options.disks) { $disk in
        DiskAttachmentRow(disk: $disk) {
          options.disks.removeAll { $0.id == disk.id }
        }
      }
      HStack {
        Menu {
          Button("Disk Image or ISO…", systemImage: "opticaldisc") { addImages() }
          Menu("Cached Image") {
            if model.library.images.isEmpty {
              Text("No cached images")
            }
            ForEach(model.library.images) { image in
              Button(image.name) {
                options.disks.append(RunOptions.DiskAttachment(location: image.name, readOnly: true))
              }
            }
          }
          Button("Network Block Device", systemImage: "network") {
            options.disks.append(RunOptions.DiskAttachment(location: "nbd://localhost:10809/"))
          }
          Button("Block Device", systemImage: "externaldrive") {
            options.disks.append(RunOptions.DiskAttachment(location: "/dev/disk"))
          }
        } label: {
          Label("Add Disk", systemImage: "plus")
        }
        .fixedSize()
        .requiresFlag("--disk")
        Spacer()
      }

      Picker(selection: $options.rootDisk.sync) {
        Text("Default (full)").tag(RunOptions.DiskSync?.none)
        Text("Full").tag(RunOptions.DiskSync?.some(.full))
        Text("Flush only (fsync)").tag(RunOptions.DiskSync?.some(.fsync))
        Text("None — fastest, risky").tag(RunOptions.DiskSync?.some(.disabled))
      } label: {
        Text("Main disk synchronisation")
        Text("Less synchronisation is faster but can lose data if this Mac crashes.")
      }
      .requiresFlag("--root-disk-opts")

      Picker(selection: $options.rootDisk.caching) {
        Text("Default").tag(RunOptions.DiskCaching?.none)
        Text("Automatic").tag(RunOptions.DiskCaching?.some(.automatic))
        Text("Cached").tag(RunOptions.DiskCaching?.some(.cached))
        Text("Uncached").tag(RunOptions.DiskCaching?.some(.uncached))
      } label: {
        Text("Main disk caching")
        Text("Tart caches Linux disks and lets macOS decide for macOS disks.")
      }
      .requiresFlag("--root-disk-opts")
    } header: {
      Text("Disks")
    }
  }

  private func addImages() {
    let panel = NSOpenPanel()
    panel.title = "Attach Disk Images"
    panel.prompt = "Attach"
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      let isISO = url.pathExtension.lowercased() == "iso"
      options.disks.append(RunOptions.DiskAttachment(location: url.path, readOnly: isISO))
    }
  }
}

private struct DiskAttachmentRow: View {
  @Binding var disk: RunOptions.DiskAttachment
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .foregroundStyle(.secondary)
          .frame(width: 18)
        TextField("Location", text: $disk.location, prompt: Text("Path, image name or nbd:// URL"))
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
        Button(role: .destructive, action: onRemove) {
          Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Detach \(disk.location)")
      }
      HStack(spacing: 12) {
        Toggle("Read only", isOn: $disk.readOnly)
          .toggleStyle(.checkbox)
        Picker("Sync", selection: $disk.sync) {
          Text("Default").tag(RunOptions.DiskSync?.none)
          Text("Full").tag(RunOptions.DiskSync?.some(.full))
          Text("fsync").tag(RunOptions.DiskSync?.some(.fsync))
          Text("None").tag(RunOptions.DiskSync?.some(.disabled))
        }
        .fixedSize()
        Picker("Caching", selection: $disk.caching) {
          Text("Default").tag(RunOptions.DiskCaching?.none)
          Text("Automatic").tag(RunOptions.DiskCaching?.some(.automatic))
          Text("Cached").tag(RunOptions.DiskCaching?.some(.cached))
          Text("Uncached").tag(RunOptions.DiskCaching?.some(.uncached))
        }
        .fixedSize()
        Spacer()
      }
      .controlSize(.small)
    }
    .padding(.vertical, 2)
  }

  private var icon: String {
    let location = disk.location.lowercased()
    if location.hasPrefix("nbd") { return "network" }
    if location.hasPrefix("/dev/") { return "externaldrive" }
    if location.hasSuffix(".iso") { return "opticaldisc" }
    if location.contains("/") && !location.hasPrefix("/") && !location.hasPrefix("~") { return "square.stack.3d.up" }
    return "doc"
  }
}

// MARK: - Devices

private struct DeviceOptionsSection: View {
  @Binding var profile: RunProfile
  let os: VMOperatingSystem

  var body: some View {
    let options = $profile.options

    Section {
      Toggle(isOn: Binding(get: { !options.wrappedValue.noAudio }, set: { options.wrappedValue.noAudio = !$0 })) {
        Text("Audio")
        Text("Passes the microphone and speakers through to the guest.")
      }
      .disabled(options.wrappedValue.suspendable)
      .requiresFlag("--no-audio")

      Toggle(isOn: Binding(get: { !options.wrappedValue.noKeyboard }, set: { options.wrappedValue.noKeyboard = !$0 })) {
        Text("Keyboard")
      }
      .requiresFlag("--no-keyboard")

      Toggle(isOn: Binding(get: { !options.wrappedValue.noPointer }, set: { options.wrappedValue.noPointer = !$0 })) {
        Text("Pointer")
      }
      .requiresFlag("--no-pointer")

      if os == .macOS {
        Toggle(isOn: Binding(get: { !options.wrappedValue.noTrackpad }, set: { options.wrappedValue.noTrackpad = !$0 })) {
          Text("Trackpad")
          Text("Turn off to use a USB mouse instead, e.g. for older macOS guests.")
        }
        .requiresFlag("--no-trackpad")
      }

      Toggle(
        isOn: Binding(
          get: { !options.wrappedValue.noUSBAccessories }, set: { options.wrappedValue.noUSBAccessories = !$0 })
      ) {
        Text("USB keyboard and pointer")
        Text("macOS guests keep the Mac keyboard and trackpad when this is off.")
      }
      .requiresFlag("--no-usb-accessories")

      if os == .macOS {
        Toggle(isOn: options.suspendable) {
          Text("Suspendable")
          Text("Lets you suspend the VM and resume it later. Disables audio and the entropy device.")
        }
        .requiresFlag("--suspendable")
      } else {
        Toggle(isOn: options.nested) {
          Text("Nested virtualization")
          Text(
            HostSupport.nestedVirtualization
              ? "Lets the guest run its own virtual machines."
              : "Needs a Mac with an M3 chip or later and macOS 15 or later.")
        }
        .disabled(!HostSupport.nestedVirtualization && !options.wrappedValue.nested)
        .requiresFlag("--nested")
      }

      Toggle(isOn: options.serial) {
        Text("Open a serial console")
        Text("Creates a /dev/ttys device; its path appears in the VM's log.")
      }
      .requiresFlag("--serial")

      if !options.wrappedValue.serial {
        TextField(
          "Serial device",
          text: Binding(
            get: { options.wrappedValue.serialPath ?? "" },
            set: { options.wrappedValue.serialPath = $0.isEmpty ? nil : $0 }),
          prompt: Text("Existing serial device or file (optional)"))
        .requiresFlag("--serial-path")
      }

      Stepper(value: $profile.stopTimeout, in: 5...600, step: 5) {
        LabeledContent("Stop timeout") {
          Text("\(profile.stopTimeout) s").monospacedDigit()
        }
      }
    } header: {
      Text("Devices")
    }
  }
}

// MARK: - Provisioning

private struct ProvisioningOptionsSection: View {
  @Binding var options: RunOptions

  var body: some View {
    let available = HostSupport.atLeast(27)
    let enabled = Binding(
      get: { options.provisioning != nil },
      set: { options.provisioning = $0 ? RunOptions.Provisioning(logsInAutomatically: true, enablesRemoteLogin: true) : nil })

    Section {
      Toggle(isOn: enabled) {
        Text("Set up macOS on first boot")
        Text(
          available
            ? "Creates the user account so the setup assistant is skipped. Only applies to new macOS 27 guests."
            : "Needs macOS 27 or later on this Mac.")
      }
      .disabled(!available && options.provisioning == nil)
      .requiresFlag("--provisioning-opts")

      if let provisioning = options.provisioning {
        let field = { (keyPath: WritableKeyPath<RunOptions.Provisioning, String?>) in
          Binding<String>(
            get: { provisioning[keyPath: keyPath] ?? "" },
            set: { options.provisioning?[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
        }
        TextField("Full name", text: field(\.fullName))
        TextField("Account name", text: field(\.username), prompt: Text("admin"))
        SecureField("Password", text: field(\.password))
        Toggle(
          "Log in automatically",
          isOn: Binding(
            get: { provisioning.logsInAutomatically ?? false },
            set: { options.provisioning?.logsInAutomatically = $0 }))
        Toggle(
          "Turn on Remote Login (SSH)",
          isOn: Binding(
            get: { provisioning.enablesRemoteLogin ?? false },
            set: { options.provisioning?.enablesRemoteLogin = $0 }))
      }
    } header: {
      Text("First Boot")
    }
  }
}
