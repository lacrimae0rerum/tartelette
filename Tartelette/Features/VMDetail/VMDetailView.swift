import SwiftUI
import TarteletteKit

struct VMDetailView: View {
  let vmName: String

  var body: some View {
    ContentUnavailableView(vmName, systemImage: "desktopcomputer")
  }
}
