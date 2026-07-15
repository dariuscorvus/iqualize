import SwiftUI

/// Top-level Preset Browser: a `NavigationSplitView` whose sidebar stacks a search field on
/// top, the scrolling catalog list in the middle, and the OPRA/iQualize catalog picker pinned
/// at the bottom. The picker switches between OPRA's community database and iQualize's own
/// built-in presets the user has hidden from their picker. The detail pane shows the selected
/// OPRA product's community EQ curves.
///
/// The search field is a plain `VStack` sibling above the `List`, not `.searchable`. A
/// `.searchable(placement: .sidebar)` field renders as a transparent overlay inside the
/// scrolling list and the rows draw straight through it (issue #108); a fixed sibling can't be
/// overlapped.
@available(macOS 14.2, *)
struct PresetBrowserView: View {
    let presetStore: PresetStore
    let onImportOPRA: (OPRAProductEntry, OPRACurveEntry) -> Void

    private enum Catalog: String, CaseIterable {
        case opra = "OPRA"
        case iqualize = "iQualize"
    }

    @State private var catalog: Catalog = .opra

    // OPRA catalog state.
    @State private var products: [OPRAProductEntry] = []
    @State private var searchText = ""
    @State private var selectedProductID: String?
    @State private var loadState: LoadState = .loading

    private enum LoadState { case loading, loaded, failed(String) }

    private var filteredProducts: [OPRAProductEntry] {
        guard !searchText.isEmpty else { return products }
        return products.filter {
            "\($0.vendorName) \($0.productName)".localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredHiddenPresets: [EQPresetData] {
        let hidden = presetStore.hiddenBuiltInPresets
        guard !searchText.isEmpty else { return hidden }
        return hidden.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        // A fixed two-pane HStack rather than a NavigationSplitView. The split view's divider
        // stays user-draggable even with the toggle removed and `columnVisibility` pinned, so
        // the sidebar could be dragged shut. A fixed-width sidebar has no draggable divider and
        // can't collapse. Selection is driven by `selectedProductID`, so we don't need the
        // split view's navigation behavior.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                Divider()
                sidebarList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Picker("Catalog", selection: $catalog) {
                    ForEach(Catalog.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
            }
            .frame(width: 280)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
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

    // MARK: - Sidebar list

    @ViewBuilder
    private var sidebarList: some View {
        switch catalog {
        case .opra:
            opraSidebar
        case .iqualize:
            iqualizeSidebar
        }
    }

    @ViewBuilder
    private var opraSidebar: some View {
        switch loadState {
        case .loading:
            ProgressView("Loading OPRA database…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            List(filteredProducts, selection: $selectedProductID) { product in
                productRow(product).tag(product.id)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var iqualizeSidebar: some View {
        let hidden = filteredHiddenPresets
        if hidden.isEmpty {
            Text(searchText.isEmpty
                 ? "All built-in presets are already in your list"
                 : "No matching presets")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(hidden) { preset in
                HStack {
                    Text(preset.name)
                    Spacer()
                    Button("Restore") { presetStore.restoreBuiltInPreset(id: preset.id) }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func productRow(_ product: OPRAProductEntry) -> some View {
        HStack(spacing: 10) {
            thumbnail(for: product)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(product.vendorName) \(product.productName)")
                    .font(.body)
                if let subtype = product.subtype {
                    Text(subtype.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for product: OPRAProductEntry) -> some View {
        Group {
            if let url = product.thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
            } else {
                Image(systemName: "headphones")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 24)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch catalog {
        case .opra:
            if let selectedProductID, let product = products.first(where: { $0.id == selectedProductID }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(product.vendorName) \(product.productName)")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider()
                    List(product.curves) { curve in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(curve.author).font(.body)
                                if let details = curve.details {
                                    Text(details).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Import") { onImportOPRA(product, curve) }
                        }
                    }
                }
            } else {
                placeholder("Select a headphone to see available EQ profiles")
            }
        case .iqualize:
            placeholder("Restore a built-in preset to add it back to your picker")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        loadState = .loading
        do {
            products = try await OPRACatalog.shared.loadIfNeeded()
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}
