import AppKit
import SwiftUI
import TarteletteKit

@main
struct TarteletteApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    let model = appDelegate.model

    Window("Tartelette", id: "main") {
      ContentView()
        .environment(model)
    }
    .defaultSize(width: 1180, height: 760)
    .windowResizability(.contentMinSize)
    .commands { AppCommands(model: model) }

    Settings {
      SettingsView()
        .environment(model)
    }

    MenuBarExtra(isInserted: Binding(
      get: { model.settings.showMenuBarExtra },
      set: { model.settings.showMenuBarExtra = $0 }
    )) {
      MenuBarContentView()
        .environment(model)
    } label: {
      MenuBarLabel(library: model.library)
    }
    .menuBarExtraStyle(.window)
  }
}

/// The menu bar icon: the outlined tartlet, filled while any VM runs.
struct MenuBarLabel: View {
  let library: VMLibrary

  var body: some View {
    let running = library.runningCount
    Image(running > 0 ? "MenuBarIconActive" : "MenuBarIcon")
      .accessibilityLabel(running > 0 ? "Tartelette, \(running) running" : "Tartelette")
  }
}
