import AppKit
import SwiftUI
import TarteletteKit

/// The main window: onboarding when Tart is missing, otherwise the split view.
struct ContentView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    @Bindable var navigation = model.navigation

    Group {
      if model.context.isAvailable {
        MainSplitView()
      } else {
        TartMissingView()
      }
    }
    .frame(minWidth: 900, minHeight: 560)
    .sheet(item: $navigation.presentedSheet) { route in
      SheetContainer(route: route)
        .environment(model)
    }
    .alert(
      navigation.alert?.title ?? "",
      isPresented: Binding(get: { navigation.alert != nil }, set: { if !$0 { navigation.alert = nil } }),
      presenting: navigation.alert
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { alert in
      Text(alert.message)
    }
    .confirmationDialog(
      navigation.confirmation?.title ?? "",
      isPresented: Binding(get: { navigation.confirmation != nil }, set: { if !$0 { navigation.confirmation = nil } }),
      titleVisibility: .visible,
      presenting: navigation.confirmation
    ) { confirmation in
      Button(confirmation.actionTitle, role: confirmation.isDestructive ? .destructive : nil) {
        confirmation.action()
      }
      Button("Cancel", role: .cancel) {}
    } message: { confirmation in
      Text(confirmation.message)
    }
    .onAppear {
      navigation.openMainWindow = { [openWindow] in
        openWindow(id: "main")
        NSApp.activate()
      }
      navigation.openSettings = { [openSettings] in
        openSettings()
        NSApp.activate()
      }
    }
  }
}

private struct MainSplitView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var navigation = model.navigation

    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
    } detail: {
      DetailRouter()
    }
    .searchable(text: $navigation.searchText, placement: .sidebar, prompt: "Filter")
    .toolbar { MainToolbar() }
  }
}

/// Chooses the detail screen for the sidebar selection.
private struct DetailRouter: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    switch model.navigation.selection ?? .dashboard {
    case .dashboard:
      DashboardView()
    case .vm(let name):
      if model.library.vm(named: name) != nil {
        VMDetailView(vmName: name)
          .id(name)
      } else if !model.library.hasLoaded {
        ProgressView()
      } else {
        EmptyStateView(
          "“\(name)” Is Gone", systemImage: "questionmark.square.dashed",
          message: "The VM was renamed or deleted outside Tartelette."
        ) {
          Button("Show Dashboard") { model.navigation.selection = .dashboard }
        }
      }
    case .images:
      ImagesView()
    case .registries:
      RegistriesView()
    case .storage:
      StorageView()
    case .activity:
      ActivityView()
    }
  }
}

/// Window toolbar: New, Start/Stop for the selected VM, Refresh, Settings.
private struct MainToolbar: ToolbarContent {
  @Environment(AppModel.self) private var model

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button("New Virtual Machine…", systemImage: "plus") { model.navigation.present(.newVM(initialTab: .image)) }
        Button("Create macOS VM from IPSW…", systemImage: "apple.logo") {
          model.navigation.present(.newVM(initialTab: .macOS))
        }
        Button("Create Linux VM…", systemImage: "server.rack") { model.navigation.present(.newVM(initialTab: .linux)) }
        Divider()
        Button("Pull Image…", systemImage: "icloud.and.arrow.down") { model.navigation.present(.pull) }
        Button("Import from File…", systemImage: "square.and.arrow.down") { model.navigation.present(.importVM) }
      } label: {
        Label("New", systemImage: "plus")
      } primaryAction: {
        model.navigation.present(.newVM(initialTab: .image))
      }
      .help("New virtual machine")
    }

    if let name = model.navigation.selectedVMName, model.library.vm(named: name) != nil {
      ToolbarItem(placement: .primaryAction) {
        if model.library.isRunning(name) {
          Menu {
            StopMenuItems(name: name)
          } label: {
            Label("Shut Down", systemImage: "stop.fill")
          } primaryAction: {
            model.library.requestShutdown(name)
          }
          .help("Shut down “\(name)”")
        } else {
          Menu {
            StartMenuItems(name: name)
          } label: {
            Label("Start", systemImage: "play.fill")
          } primaryAction: {
            model.library.start(name)
          }
          .help("Start “\(name)”")
        }
      }
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        model.library.refreshSoon()
        Task { await model.metrics.refreshStorage() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh")
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        model.navigation.openSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .help("Settings (⌘,)")
    }
  }
}
