import SwiftUI
import TarteletteKit

struct ExportSheet: View {
  let vmName: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack {
      ContentUnavailableView("Export", systemImage: "square.and.arrow.up")
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
