import SwiftUI
import TarteletteKit

/// `tart import`: the New VM sheet opened on its Import tab, so every way of creating a VM
/// shares one consistent sheet.
struct ImportSheet: View {
  var body: some View {
    NewVMSheet(initialTab: .importArchive)
  }
}
