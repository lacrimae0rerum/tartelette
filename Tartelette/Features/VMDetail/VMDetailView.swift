import SwiftUI
import TarteletteKit

/// The detail screen of one local VM: a header with its controls and a tab per area.
///
/// The selected tab lives in `NavigationModel.vmDetailTab`, so menu commands, the Dock menu and
/// the menu bar extra can jump straight to e.g. Clipboard & Files.
struct VMDetailView: View {
  let vmName: String

  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var navigation = model.navigation

    if let vm = model.library.vm(named: vmName) {
      VStack(spacing: 0) {
        VMHeaderView(vm: vm)
        DetailTabBar(selection: $navigation.vmDetailTab)
        Divider()
        tabContent(vm)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .navigationTitle(vmName)
      .navigationSubtitle(subtitle(vm))
    } else if let image = model.library.images.first(where: { $0.name == vmName }) {
      CachedImageDetail(image: image)
    } else {
      EmptyStateView(
        "“\(vmName)” Isn't Available", systemImage: "questionmark.square.dashed",
        message: "It may have been renamed or deleted from the command line."
      ) {
        Button("Show Dashboard") { model.navigation.selection = .dashboard }
      }
    }
  }

  @ViewBuilder
  private func tabContent(_ vm: VMListing) -> some View {
    switch model.navigation.vmDetailTab {
    case .overview: VMOverviewTab(vm: vm)
    case .performance: VMPerformanceTab(vm: vm)
    case .configuration: VMConfigurationTab(vm: vm)
    case .runOptions: VMRunOptionsTab(vmName: vm.name)
    case .clipboard: VMClipboardTab(vm: vm)
    case .console: VMConsoleTab(vm: vm)
    case .logs: VMLogsTab(vmName: vm.name)
    }
  }

  private func subtitle(_ vm: VMListing) -> String {
    let state = vm.state.title
    guard vm.state.isRunning, let sample = model.metrics.latest(for: vm.name) else { return state }
    return "\(state) · CPU \(Formatting.cpu(sample.cpuPercent)) · \(Formatting.memory(sample.memoryBytes))"
  }
}

// MARK: - Tab bar

/// A compact, Xcode-inspector-like tab strip. Falls back to icons only when space is tight.
private struct DetailTabBar: View {
  @Binding var selection: VMDetailTab
  @Namespace private var highlight

  var body: some View {
    ViewThatFits(in: .horizontal) {
      strip(showsTitles: true)
      strip(showsTitles: false)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
  }

  private func strip(showsTitles: Bool) -> some View {
    HStack(spacing: 2) {
      ForEach(VMDetailTab.allCases) { tab in
        Button {
          withAnimation(.snappy(duration: 0.22)) { selection = tab }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: tab.systemImage)
              .imageScale(.medium)
            if showsTitles {
              Text(tab.title).lineLimit(1).fixedSize()
            }
          }
          .font(.callout.weight(selection == tab ? .semibold : .regular))
          .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
          .padding(.horizontal, showsTitles ? 10 : 9)
          .padding(.vertical, 5)
          .background {
            if selection == tab {
              Capsule()
                .fill(.quaternary)
                .matchedGeometryEffect(id: "selection", in: highlight)
            }
          }
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
      }
      Spacer(minLength: 0)
    }
  }
}

// MARK: - Cached OCI image

/// Shown when an OCI cache entry (not a local VM) is selected: images can't be run directly.
private struct CachedImageDetail: View {
  let image: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(
      image.name, systemImage: "square.stack.3d.up",
      message:
        "This is a cached image, not a virtual machine. Clone it to get a VM you can run and configure."
        + "\n\(Formatting.gigabytes(image.diskGB)) disk · \(Formatting.gigabytes(image.sizeGB)) on this Mac"
    ) {
      Button("Clone to New VM…") { model.navigation.present(.clone(source: image.name)) }
        .buttonStyle(.borderedProminent)
      Button("Show Images") { model.navigation.selection = .images }
    }
    .navigationTitle(image.name)
  }
}

// MARK: - Shared tab chrome

/// The standard scrolling container for a detail tab.
struct DetailScroll<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        content()
      }
      .padding(20)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

/// An inline notice (info, warning or error) used across the detail tabs.
struct InlineNotice: View {
  enum Kind {
    case info, warning, error

    var tint: Color {
      switch self {
      case .info: .blue
      case .warning: .orange
      case .error: .red
      }
    }

    var systemImage: String {
      switch self {
      case .info: "info.circle.fill"
      case .warning: "exclamationmark.triangle.fill"
      case .error: "xmark.octagon.fill"
      }
    }
  }

  let kind: Kind
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?

  init(_ kind: Kind, _ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
    self.kind = kind
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: kind.systemImage)
        .foregroundStyle(kind.tint)
      Text(message)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .controlSize(.small)
      }
    }
    .padding(10)
    .background(kind.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(kind.tint.opacity(0.25), lineWidth: 0.5)
    )
    .accessibilityElement(children: .combine)
  }
}
