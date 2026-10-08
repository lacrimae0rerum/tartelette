import SwiftUI
import TarteletteKit

struct PruneSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack {
      ContentUnavailableView("Prune", systemImage: "scissors")
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 480, height: 300)
  }
}
