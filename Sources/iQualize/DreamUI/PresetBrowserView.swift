import SwiftUI

/// Search-and-import UI for OPRA's community headphone EQ database. Sidebar lists matching
/// products; selecting one shows its available community EQ curves in the detail pane.
@available(macOS 14.2, *)
struct PresetBrowserView: View {
    let onImport: (OPRAProductEntry, OPRACurveEntry) -> Void

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

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detail
        }
        .task { await load() }
    }

    @ViewBuilder
    private var sidebar: some View {
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
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search headphones…")
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

    @ViewBuilder
    private var detail: some View {
        if let selectedProductID, let product = products.first(where: { $0.id == selectedProductID }) {
            List(product.curves) { curve in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(curve.author).font(.body)
                        if let details = curve.details {
                            Text(details).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Import") { onImport(product, curve) }
                }
            }
            .navigationTitle("\(product.vendorName) \(product.productName)")
        } else {
            Text("Select a headphone to see available EQ profiles")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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
