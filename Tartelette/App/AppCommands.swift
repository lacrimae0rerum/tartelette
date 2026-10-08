import AppKit
import SwiftUI
import TarteletteKit

/// Menu bar commands and keyboard shortcuts.
struct AppCommands: Commands {
  let model: AppModel

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Tartelette") { AboutPanel.show(tartVersion: model.context.version) }
    }

    CommandGroup(replacing: .newItem) {
      Button("New Virtual Machine…") { model.navigation.present(.newVM(initialTab: .image)) }
        .keyboardShortcut("n")
      Button("Pull Image…") { model.navigation.present(.pull) }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Button("Import Virtual Machine…") { model.navigation.present(.importVM) }
        .keyboardShortcut("o")
    }

    CommandGroup(before: .sidebar) {
      NavigationCommands(model: model)
      Divider()
    }

    CommandMenu("Virtual Machine") {
      VirtualMachineCommands(model: model)
    }

    CommandMenu("Clipboard") {
      ClipboardCommands(model: model)
    }

    CommandGroup(replacing: .help) {
      Link("Tart Documentation", destination: Links.tartDocumentation)
      Link("Tart Guest Agent", destination: Links.guestAgent)
      Link("Cirrus Labs Images", destination: Links.images)
    }
  }
}

private struct NavigationCommands: View {
  let model: AppModel

  var body: some View {
    Button("Dashboard") { select(.dashboard) }.keyboardShortcut("1")
    Button("Images") { select(.images) }.keyboardShortcut("2")
    Button("Registries") { select(.registries) }.keyboardShortcut("3")
    Button("Storage") { select(.storage) }.keyboardShortcut("4")
    Button("Activity") { select(.activity) }.keyboardShortcut("5")
    Divider()
    Button("Refresh") { model.library.refreshSoon() }
      .keyboardShortcut("r", modifiers: [.command, .shift])
  }

  private func select(_ item: SidebarItem) {
    model.navigation.selection = item
    model.navigation.openMainWindow()
  }
}

private struct VirtualMachineCommands: View {
  let model: AppModel

  var body: some View {
    let library = model.library
    let name = model.navigation.selectedVMName
    let running = name.map(library.isRunning) ?? false
    let hasVM = name.flatMap(library.vm(named:)) != nil

    Button(name.map { library.state(of: $0) == .suspended } == true ? "Resume" : "Start") {
      if let name { library.start(name) }
    }
    .keyboardShortcut("r")
    .disabled(!hasVM || running)
    Button("Start with Options…") {
      if let name { model.navigation.present(.runWithOptions(vm: name)) }
    }
    .keyboardShortcut("r", modifiers: [.command, .option])
    .disabled(!hasVM || running)
    Button("Show Window") { if let name { library.showWindow(name) } }
      .keyboardShortcut("w", modifiers: [.command, .shift])
      .disabled(!running)

    Divider()

    Button("Shut Down") { if let name { library.requestShutdown(name) } }
      .keyboardShortcut(".")
      .disabled(!running)
    Button("Stop") { if let name { library.stop(name) } }
      .keyboardShortcut(".", modifiers: [.command, .option])
      .disabled(!running)
    Button("Suspend") { if let name { library.suspend(name) } }
      .keyboardShortcut("z", modifiers: [.command, .control])
      .disabled(!(name.map(library.canSuspend) ?? false))

    Divider()

    Button("Open Terminal") { if let name { library.openTerminal(name) } }
      .keyboardShortcut("t", modifiers: [.command, .control])
      .disabled(!running)
    Button("Open SSH Session") { if let name { Task { await library.openSSH(name) } } }
      .keyboardShortcut("s", modifiers: [.command, .control])
      .disabled(!running)
    Button("Copy IP Address") { if let name { Task { await library.copyIP(name) } } }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(!running)

    Divider()

    Button("Clone…") { if let name { model.navigation.present(.clone(source: name)) } }
      .keyboardShortcut("d")
      .disabled(!hasVM)
    Button("Rename…") { if let name { model.navigation.present(.rename(vm: name)) } }
      .disabled(!hasVM || running)
    Button("Push to Registry…") { if let name { model.navigation.present(.push(vm: name)) } }
      .disabled(!hasVM || running)
    Button("Export…") { if let name { model.navigation.present(.exportVM(vm: name)) } }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(!hasVM)

    Divider()

    Button("Delete…") { if let name { model.navigation.present(.confirmDelete(names: [name])) } }
      .keyboardShortcut(.delete)
      .disabled(!hasVM || running)
  }
}

private struct ClipboardCommands: View {
  let model: AppModel

  var body: some View {
    let name = model.navigation.selectedVMName
    let running = name.map(model.library.isRunning) ?? false
    Button("Send Mac Clipboard to VM") {
      if let name { Task { await model.clipboard.sendHostClipboard(to: name) } }
    }
    .keyboardShortcut("v", modifiers: [.command, .control])
    .disabled(!running)
    Button("Get VM Clipboard") {
      if let name { Task { await model.clipboard.fetchGuestClipboard(from: name) } }
    }
    .keyboardShortcut("c", modifiers: [.command, .control])
    .disabled(!running)
    Divider()
    if let name {
      let state = model.clipboard.state(for: name)
      Toggle("Live Sync", isOn: Binding(
        get: { state.liveSyncEnabled },
        set: { model.clipboard.setLiveSync($0, for: name) }
      ))
      .keyboardShortcut("l", modifiers: [.command, .control])
    } else {
      Toggle("Live Sync", isOn: .constant(false)).disabled(true)
    }
  }
}

/// The standard About panel with app and Tart versions.
enum AboutPanel {
  static func show(tartVersion: String?) {
    let credits = NSMutableAttributedString(
      string: "A native companion for Tart virtual machines on Apple silicon.\n",
      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    credits.append(NSAttributedString(
      string: "Tart \(tartVersion ?? "not detected")",
      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    NSApp.activate()
  }
}
