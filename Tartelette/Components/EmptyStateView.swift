import SwiftUI

/// A `ContentUnavailableView` with optional actions, used for empty lists and missing features.
struct EmptyStateView<Actions: View>: View {
  let title: String
  let systemImage: String
  var message: String?
  @ViewBuilder var actions: () -> Actions

  init(
    _ title: String,
    systemImage: String,
    message: String? = nil,
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
  ) {
    self.title = title
    self.systemImage = systemImage
    self.message = message
    self.actions = actions
  }

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      if let message { Text(message) }
    } actions: {
      actions()
    }
  }
}
