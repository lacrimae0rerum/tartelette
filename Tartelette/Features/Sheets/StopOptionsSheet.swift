import SwiftUI
import TarteletteKit

struct StopOptionsSheet: View {
  let vmName: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack {
      ContentUnavailableView("Stop", systemImage: "stop.circle")
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
