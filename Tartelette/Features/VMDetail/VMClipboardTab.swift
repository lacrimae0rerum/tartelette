import AppKit
import SwiftUI
import TarteletteKit

/// Copy and paste between this Mac and the VM, plus file transfers in both directions.
struct VMClipboardTab: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    let clipboard = model.clipboard
    let state = clipboard.state(for: vm.name)
    let engine = clipboard.engine(for: vm.name)
    let running = vm.state.isRunning
    let connected = running && state.agentStatus.isAvailable

    DetailScroll {
      ConnectionCard(vm: vm, state: state, engine: engine)

      if running {
        TransferButtons(vmName: vm.name, state: state, isEnabled: running)
      }

      HStack(alignment: .top, spacing: 16) {
        SectionCard("On This Mac", systemImage: "laptopcomputer") {
          HostClipboardPreview()
        }
        SectionCard("Last Received from the VM", systemImage: "arrow.down.doc") {
          ClipboardPreview(
            payload: state.lastReceived,
            emptyTitle: state.lastReceivedSummary.map { "Received \($0)" } ?? "Nothing received yet")
        }
      }

      FilesCard(vmName: vm.name, os: model.library.os(of: vm.name), isEnabled: running, isConnected: connected)

      HistoryCard(events: state.events)
    }
  }
}

// MARK: - Connection & live sync

private struct ConnectionCard: View {
  let vm: VMListing
  let state: VMClipboardState
  let engine: ClipboardEngine
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @State private var pasteboardAccess = PasteboardAccess.current

  var body: some View {
    let clipboard = model.clipboard
    let status = vm.state.isRunning ? state.agentStatus : .unknown

    SectionCard("Copy & Paste", systemImage: "doc.on.clipboard") {
      Button("Change…") { model.navigation.vmDetailTab = .runOptions }
        .buttonStyle(.link)
        .help("Choose the clipboard engine in Run Options")
    } content: {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(engine.title).font(.headline)
          Text(engine.summary).foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Pill(title: status.title, systemImage: status.systemImage, tint: status.tint)
          if let route = state.route, status.isAvailable {
            Text("via \(route.title)").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if vm.state.isRunning, !status.isAvailable, status != .checking {
            Button("Check Again") { Task { await clipboard.probe(vm.name) } }
              .controlSize(.small)
          }
        }

        switch engine {
        case .bridge, .automatic:
          liveSyncControls(clipboard: clipboard)
        case .spice:
          InlineNotice(
            .info,
            "Tart's built-in clipboard copies plain text while the VM's window is open. Use the buttons below for rich text, images and files.")
        case .off:
          InlineNotice(.info, "Clipboard sharing is off for this VM. You can still copy manually with the buttons below.")
        }

        requirements(status: status)
      }
    }
  }

  @ViewBuilder
  private func liveSyncControls(clipboard: ClipboardCenter) -> some View {
    HStack(spacing: 14) {
      Toggle(
        isOn: Binding(get: { state.liveSyncEnabled }, set: { clipboard.setLiveSync($0, for: vm.name) })
      ) {
        Text("Live sync")
      }
      .toggleStyle(.switch)

      Picker(
        "Direction",
        selection: Binding(get: { state.direction }, set: { clipboard.setDirection($0, for: vm.name) })
      ) {
        ForEach(ClipboardSyncSession.Direction.allCases, id: \.self) { direction in
          Label(direction.title, systemImage: direction.systemImage).tag(direction)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .disabled(!state.liveSyncEnabled)

      Spacer()

      if state.isSyncing {
        Label("Syncing", systemImage: "dot.radiowaves.left.and.right")
          .font(.callout)
          .foregroundStyle(.green)
          .symbolEffect(.pulse, options: .repeating)
      } else if state.liveSyncEnabled, vm.state.isRunning {
        Text("Waiting for the guest agent")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    Text(
      "Anything you copy on one side is ready to paste on the other: text, rich text, images and files (up to \(model.settings.maxAutoTransferMB) MB automatically). Transfers are checksum-verified."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .task {
      // The user can change this in System Settings at any time.
      while !Task.isCancelled {
        pasteboardAccess = PasteboardAccess.current
        try? await Task.sleep(for: .seconds(2))
      }
    }

    if state.liveSyncEnabled {
      switch pasteboardAccess {
      case .denied:
        InlineNotice(
          .warning,
          "macOS doesn't let Tartelette read what you copy, so nothing goes from this Mac to the VM. Allow Tartelette in System Settings › Privacy & Security › Paste from Other Apps.",
          actionTitle: "Open Settings…"
        ) { openURL(PasteboardAccess.settingsURL) }
      case .ask:
        InlineNotice(
          .info,
          "macOS asks before Tartelette reads what you copy in other apps. To sync without prompts, allow Tartelette in System Settings › Privacy & Security › Paste from Other Apps.",
          actionTitle: "Open Settings…"
        ) { openURL(PasteboardAccess.settingsURL) }
      case .allowed:
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private func requirements(status: GuestAgentStatus) -> some View {
    if !vm.state.isRunning {
      InlineNotice(.info, "Start the VM to exchange its clipboard and files.")
    } else if case .unavailable = status {
      let os = model.library.os(of: vm.name)
      InlineNotice(
        .warning,
        os == .linux
          ? "Needs the Tart Guest Agent and a desktop session with wl-clipboard, xclip or xsel. Cirrus Labs Linux images are servers without a desktop, so only file transfers work there."
          : "Needs the Tart Guest Agent (preinstalled in Cirrus Labs base and Xcode images, not in vanilla ones) and a logged-in user. Without it, Tartelette tries SSH with the account from Settings."
      )
    }
  }
}

/// Whether macOS lets Tartelette read the Mac's clipboard. Since macOS 15.4 the system can ask the
/// user, or refuse, before an app reads what was copied in other apps; live sync reads it on every
/// copy.
enum PasteboardAccess {
  case allowed, ask, denied

  static var current: PasteboardAccess {
    guard #available(macOS 15.4, *) else { return .allowed }
    switch NSPasteboard.general.accessBehavior {
    case .alwaysDeny: return .denied
    case .ask: return .ask
    // `.default` means macOS hasn't asked yet; `.alwaysAllow` needs nothing.
    default: return .allowed
    }
  }

  /// System Settings › Privacy & Security › Paste from Other Apps.
  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
}

// MARK: - Manual transfers

private struct TransferButtons: View {
  let vmName: String
  let state: VMClipboardState
  let isEnabled: Bool
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 12) {
      Button {
        Task { await model.clipboard.sendHostClipboard(to: vmName) }
      } label: {
        TransferLabel(
          title: "Send Mac Clipboard to VM", subtitle: "Paste it in the VM with ⌘V",
          systemImage: "arrow.right.doc.on.clipboard")
      }
      .help("Send Mac Clipboard to VM (⌃⌘V)")

      Button {
        Task { await model.clipboard.fetchGuestClipboard(from: vmName) }
      } label: {
        TransferLabel(
          title: "Get VM Clipboard", subtitle: "Then paste it on your Mac",
          systemImage: "arrow.down.doc")
      }
      .help("Get VM Clipboard (⌃⌘C)")

      if state.isTransferring {
        ProgressView()
          .controlSize(.small)
          .padding(.leading, 4)
      }
    }
    .buttonStyle(TransferButtonStyle())
    .disabled(!isEnabled || state.isTransferring)
  }
}

private struct TransferLabel: View {
  let title: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(Color.accentColor)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }
}

private struct TransferButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(14)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(configuration.isPressed ? Color.accentColor.opacity(0.14) : Color.accentColor.opacity(0.07))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
      )
      .opacity(isEnabled ? 1 : 0.5)
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

/// The Mac clipboard right now, refreshed while visible.
///
/// Writers clear the pasteboard (which bumps its change count) and then add items, which doesn't;
/// so after a change it is read again for a few seconds to catch items that arrived late.
private struct HostClipboardPreview: View {
  @State private var payload: ClipboardPayload?
  @State private var changeCount = -1
  @State private var rereads = 0

  var body: some View {
    ClipboardPreview(payload: payload, emptyTitle: "The Mac clipboard is empty")
      .task {
        while !Task.isCancelled {
          let current = NSPasteboard.general.changeCount
          if current != changeCount {
            changeCount = current
            rereads = 3
          }
          if rereads > 0 {
            rereads -= 1
            let snapshot = PasteboardCodec.snapshot()
            if snapshot != payload { payload = snapshot }
          }
          try? await Task.sleep(for: .seconds(1))
        }
      }
  }
}

// MARK: - Files

private struct FilesCard: View {
  let vmName: String
  let os: VMOperatingSystem
  let isEnabled: Bool
  let isConnected: Bool
  @Environment(AppModel.self) private var model
  @State private var destination = "~/Desktop"
  @State private var guestPath = ""

  var body: some View {
    SectionCard("Files", systemImage: "folder") {
      VStack(alignment: .leading, spacing: 12) {
        FileDropZone(
          title: "Drop Files to Copy Them to the VM",
          subtitle: isEnabled
            ? "Files and folders land in \(destination) in the guest. Existing items are never overwritten."
            : "Start the VM to copy files into it.",
          systemImage: "square.and.arrow.down.on.square",
          isEnabled: isEnabled
        ) { urls in
          Task { await model.clipboard.sendFiles(urls, to: vmName, destination: destination) }
        }

        LabeledContent("Copy into") {
          HStack {
            TextField("Guest folder", text: $destination, prompt: Text("~/Desktop"))
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
            Button("Choose Files…") { chooseFiles() }
              .disabled(!isEnabled)
          }
        }

        Divider()

        LabeledContent("Get from VM") {
          HStack {
            TextField(
              "Guest path", text: $guestPath,
              prompt: Text(os == .linux ? "~/report.txt or /var/log/syslog" : "~/Desktop/report.pdf"))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onSubmit(fetch)
            Button("Copy to Downloads", action: fetch)
              .disabled(!isEnabled || guestPath.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        Text("Copies the file or folder to ~/Downloads/\(vmName) on this Mac and shows it in Finder. Separate several paths with commas.")
          .font(.caption)
          .foregroundStyle(.secondary)

        if isEnabled, !isConnected {
          Text("File transfers use the Tart Guest Agent or SSH; Tartelette connects when you start a transfer.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private func chooseFiles() {
    let panel = NSOpenPanel()
    panel.title = "Copy to “\(vmName)”"
    panel.prompt = "Copy"
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    let urls = panel.urls
    Task { await model.clipboard.sendFiles(urls, to: vmName, destination: destination) }
  }

  private func fetch() {
    let paths = guestPath
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !paths.isEmpty, isEnabled else { return }
    Task { await model.clipboard.receiveFiles(paths, from: vmName) }
  }
}

// MARK: - History

private struct HistoryCard: View {
  let events: [ClipboardEventRecord]

  var body: some View {
    SectionCard("History", systemImage: "clock.arrow.circlepath") {
      if events.isEmpty {
        Text("Transfers in both directions appear here.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(events.prefix(20)) { event in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: event.systemImage)
                .foregroundStyle(tint(event.kind))
                .frame(width: 16)
              Text(event.message)
                .lineLimit(2)
                .textSelection(.enabled)
              Spacer()
              Text(event.date, format: .dateTime.hour().minute().second())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .font(.callout)
          }
        }
      }
    }
  }

  private func tint(_ kind: ClipboardEventRecord.Kind) -> Color {
    switch kind {
    case .sent: .accentColor
    case .received: .green
    case .skipped: .secondary
    case .failed: .orange
    case .info: .blue
    }
  }
}
