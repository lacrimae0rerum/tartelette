import SwiftUI

/// A titled, rounded container used to group related content on scrolling screens.
struct SectionCard<Content: View, Accessory: View>: View {
  let title: String
  var systemImage: String?
  @ViewBuilder var accessory: () -> Accessory
  @ViewBuilder var content: () -> Content

  init(
    _ title: String,
    systemImage: String? = nil,
    @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.accessory = accessory
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        if let systemImage {
          Label(title, systemImage: systemImage).font(.headline)
        } else {
          Text(title).font(.headline)
        }
        Spacer()
        accessory()
      }
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
    )
  }
}
