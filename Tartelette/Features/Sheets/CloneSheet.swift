import SwiftUI
import TarteletteKit

struct CloneSheet: View {
  let source: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack {
      ContentUnavailableView("Clone", systemImage: "plus.square.on.square")
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
