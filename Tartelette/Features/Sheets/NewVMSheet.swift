import SwiftUI
import TarteletteKit

struct NewVMSheet: View {
  let initialTab: NewVMTab
  var imageReference: String? = nil
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack {
      ContentUnavailableView("New Virtual Machine", systemImage: "plus.square.on.square")
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
