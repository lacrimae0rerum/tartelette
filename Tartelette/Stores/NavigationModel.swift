import Foundation
import Observation

/// A destination in the sidebar.
nonisolated enum SidebarItem: Hashable, Sendable {
  case dashboard
  case vm(String)
  case images
  case registries
  case storage
  case activity
}

/// The tabs of the VM detail screen (owned by `VMDetailView`; listed here so menu commands can
/// jump to a tab, e.g. “Open Console”).
nonisolated enum VMDetailTab: String, CaseIterable, Identifiable, Hashable, Sendable {
  case overview, performance, configuration, runOptions, clipboard, console, logs

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "Overview"
    case .performance: "Performance"
    case .configuration: "Configuration"
    case .runOptions: "Run Options"
    case .clipboard: "Clipboard & Files"
    case .console: "Console"
    case .logs: "Logs"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "info.circle"
    case .performance: "chart.xyaxis.line"
    case .configuration: "slider.horizontal.3"
    case .runOptions: "play.rectangle.on.rectangle"
    case .clipboard: "doc.on.clipboard"
    case .console: "terminal"
    case .logs: "doc.text.magnifyingglass"
    }
  }
}

/// The source the New VM sheet opens on.
nonisolated enum NewVMTab: String, CaseIterable, Identifiable, Hashable, Sendable {
  /// Clone a Cirrus Labs or custom OCI image.
  case image
  /// `tart create --from-ipsw`.
  case macOS
  /// `tart create --linux`.
  case linux
  /// `tart import <file.tvm>`.
  case importArchive

  var id: String { rawValue }

  var title: String {
    switch self {
    case .image: "From Image"
    case .macOS: "macOS"
    case .linux: "Linux"
    case .importArchive: "Import"
    }
  }
}

/// Every sheet the app can present. Present with `navigation.present(_:)` from anywhere
/// (menus, Dock menu, menu bar extra, context menus); `ContentView` shows it via `SheetContainer`.
nonisolated enum SheetRoute: Identifiable, Hashable, Sendable {
  /// New VM; `imageReference` preselects an OCI image on the From Image tab.
  case newVM(initialTab: NewVMTab, imageReference: String? = nil)
  /// Clone a local VM or a cached/remote image into a new local VM.
  case clone(source: String)
  case rename(vm: String)
  case push(vm: String)
  case pull
  case exportVM(vm: String)
  case importVM
  case prune
  case login
  case stopOptions(vm: String)
  case confirmDelete(names: [String])
  case runWithOptions(vm: String)

  var id: String {
    switch self {
    case .newVM(let tab, let reference): "newVM:\(tab.rawValue):\(reference ?? "")"
    case .clone(let source): "clone:\(source)"
    case .rename(let vm): "rename:\(vm)"
    case .push(let vm): "push:\(vm)"
    case .pull: "pull"
    case .exportVM(let vm): "export:\(vm)"
    case .importVM: "import"
    case .prune: "prune"
    case .login: "login"
    case .stopOptions(let vm): "stop:\(vm)"
    case .confirmDelete(let names): "delete:\(names.joined(separator: ","))"
    case .runWithOptions(let vm): "run:\(vm)"
    }
  }
}

/// A user-facing error or notice shown as an alert.
nonisolated struct AppAlert: Identifiable, Sendable {
  let id = UUID()
  let title: String
  let message: String
}

/// A question with a (usually destructive) action, shown as a confirmation dialog.
struct PendingConfirmation: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let actionTitle: String
  var isDestructive = true
  let action: () -> Void
}

/// Window-level navigation state shared by the main window, menus, the Dock menu and the menu bar.
@Observable
final class NavigationModel {
  var selection: SidebarItem? = .dashboard
  var presentedSheet: SheetRoute?
  var alert: AppAlert?
  var confirmation: PendingConfirmation?
  var searchText = ""
  /// The tab the VM detail screen shows; set it before selecting a VM to jump to a tab.
  var vmDetailTab: VMDetailTab = .overview

  /// Opens (or focuses) the main window. Installed by the first SwiftUI view that has access to
  /// `openWindow`; falls back to activating the app.
  var openMainWindow: () -> Void = {}
  /// Opens the Settings window. Installed by `ContentView`.
  var openSettings: () -> Void = {}

  var selectedVMName: String? {
    if case .vm(let name) = selection { name } else { nil }
  }

  func present(_ route: SheetRoute) {
    openMainWindow()
    presentedSheet = route
  }

  func show(_ vmName: String, tab: VMDetailTab? = nil) {
    if let tab { vmDetailTab = tab }
    selection = .vm(vmName)
    openMainWindow()
  }

  func show(error: any Error, title: String) {
    alert = AppAlert(title: title, message: error.localizedDescription)
  }

  func show(title: String, message: String) {
    alert = AppAlert(title: title, message: message)
  }

  /// Asks before running `action` (e.g. Force Stop, discarding a suspended state).
  func confirm(
    _ title: String, message: String, actionTitle: String, isDestructive: Bool = true, action: @escaping () -> Void
  ) {
    openMainWindow()
    confirmation = PendingConfirmation(
      title: title, message: message, actionTitle: actionTitle, isDestructive: isDestructive, action: action)
  }
}
