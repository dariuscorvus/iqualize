import SwiftUI

/// Search field with a leading magnifying-glass icon and a trailing clear button, styled as a
/// fixed sibling pinned above a scrolling list — not `.searchable`, which renders as a
/// transparent overlay inside a `List` and lets rows draw straight through it (issue #108).
/// Shared by the Preset Browser sidebar and the main window's preset sidebar.
struct PresetSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background)
    }
}
