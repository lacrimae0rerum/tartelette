import SwiftUI
import TarteletteKit

/// Maps a `SheetRoute` to its sheet view.
struct SheetContainer: View {
  let route: SheetRoute

  var body: some View {
    switch route {
    case .newVM(let tab, let reference): NewVMSheet(initialTab: tab, imageReference: reference)
    case .clone(let source): CloneSheet(source: source)
    case .rename(let vm): RenameSheet(vmName: vm)
    case .push(let vm): PushSheet(vmName: vm)
    case .pull: PullSheet()
    case .exportVM(let vm): ExportSheet(vmName: vm)
    case .importVM: ImportSheet()
    case .prune: PruneSheet()
    case .login: LoginSheet()
    case .stopOptions(let vm): StopOptionsSheet(vmName: vm)
    case .confirmDelete(let names): ConfirmDeleteSheet(names: names)
    case .runWithOptions(let vm): RunOptionsSheet(vmName: vm)
    }
  }
}
