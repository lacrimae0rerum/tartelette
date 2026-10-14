import SwiftUI

/// The running install, rollback or removal of the managed Tart: what it's doing, a progress bar
/// (indeterminate while it can't be measured) and Cancel when it can be cancelled.
struct TartInstallProgressView: View {
  let progress: TartOperationProgress
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(progress.text)
          .font(.callout)
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .leading)
        if progress.canCancel {
          Button("Cancel", action: cancel)
            .controlSize(.small)
        }
      }
      if let fraction = progress.fraction {
        ProgressView(value: fraction)
      } else {
        ProgressView()
          .progressViewStyle(.linear)
      }
    }
    .accessibilityElement(children: .contain)
  }
}
