import SwiftUI

/// Top-level Preset Browser: a `NavigationSplitView` whose sidebar stacks a search field on
/// top, the scrolling catalog list in the middle, and the OPRA/iQualize catalog picker pinned
/// at the bottom. The picker switches between OPRA's community database and iQualize's own
/// built-in presets the user has hidden from their picker or edited and saved in place. The
/// detail pane shows the selected OPRA product's community EQ curves.
///
/// The search field is a plain `VStack` sibling above the `List`, not `.searchable`. A
/// `.searchable(placement: .sidebar)` field renders as a transparent overlay inside the
/// scrolling list and the rows draw straight through it (issue #108); a fixed sibling can't be
/// overlapped.
@available(macOS 14.2, *)
struct PresetBrowserView: View {
    let presetStore: PresetStore
    let onImportOPRA: (OPRAProductEntry, OPRACurveEntry) -> Void
    /// Routes through the EQ window's view model rather than calling
    /// `presetStore.resetBuiltInToOriginal` directly — if the preset being reset is also the
    /// one currently loaded in the EQ window, the view model needs to sync its in-memory bands
    /// back to the original too, or the window keeps showing (and could re-save) the stale
    /// override.
    let onResetBuiltIn: (UUID) -> Void

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
        Self.filter(products, matching: searchText)
    }

    /// Products matching `query` against their "Vendor Product" label, normalized so that
    /// spacing, hyphens, underscores, punctuation, case, and diacritics don't change the result
    /// set (#156) — `HD800S`, `HD 800 S`, and `HD-800-S` all match the same models. Results are
    /// ranked best-tier-first and deterministically ordered. An empty query matches everything.
    /// Pure so the selection-invalidation rule (#155) is testable without a live view.
    static func filter(_ products: [OPRAProductEntry], matching query: String) -> [OPRAProductEntry] {
        OPRASearch.filter(products, matching: query)
    }

    /// The selection to keep after `query` changes: a non-empty query keeps the current
    /// `selection` when it still appears in the filtered results, otherwise `nil`. Clearing the
    /// query ends the active search context, so it also clears the detail selection (#195).
    static func validatedSelection(
        _ selection: String?,
        in products: [OPRAProductEntry],
        matching query: String
    ) -> String? {
        guard let selection else { return nil }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return filter(products, matching: query).contains { $0.id == selection } ? selection : nil
    }

    private var filteredHiddenPresets: [EQPresetData] {
        let hidden = presetStore.hiddenBuiltInPresets
        guard !searchText.isEmpty else { return hidden }
        return hidden.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredOverriddenPresets: [EQPresetData] {
        let overridden = presetStore.overriddenBuiltInPresets
        guard !searchText.isEmpty else { return overridden }
        return overridden.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
                if catalog == .opra {
                    Divider()
                    OPRAAttributionView()
                }
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
        // Clear the search when switching catalogs — a term left over from OPRA
        // otherwise filters the iQualize tab and hides deleted built-ins that are
        // actually there, ready to restore (#115).
        .onChange(of: catalog) {
            searchText = ""
            // Drop any OPRA selection so switching away and back doesn't restore a
            // stale detail pane (#155).
            selectedProductID = nil
        }
        // Editing the search can filter the selected product out of the sidebar. The
        // detail pane derives from `filteredProducts`, so a dropped selection already
        // falls back to the placeholder, but clear the id too so the selection doesn't
        // silently reappear when the query changes again (#155, #195).
        .onChange(of: searchText) {
            selectedProductID = Self.validatedSelection(
                selectedProductID, in: products, matching: searchText)
        }
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
        let overridden = filteredOverriddenPresets
        if hidden.isEmpty && overridden.isEmpty {
            Text(searchText.isEmpty
                 ? "All built-in presets are in your list, unedited"
                 : "No matching presets")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !overridden.isEmpty {
                    Section("Edited") {
                        ForEach(overridden) { preset in
                            HStack {
                                Text(preset.name)
                                Spacer()
                                Button("Reset to Original") { onResetBuiltIn(preset.id) }
                            }
                        }
                    }
                }
                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(hidden) { preset in
                            HStack {
                                Text(preset.name)
                                Spacer()
                                Button("Restore") { presetStore.restoreBuiltInPreset(id: preset.id) }
                            }
                        }
                    }
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
            if let selectedProductID,
               let product = filteredProducts.first(where: { $0.id == selectedProductID }) {
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
            placeholder("Restore a hidden built-in, or reset an edited one back to its original values")
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
