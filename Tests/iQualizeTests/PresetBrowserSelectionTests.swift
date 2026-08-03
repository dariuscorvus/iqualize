import XCTest
@testable import iQualize

@available(macOS 14.2, *)
@MainActor
final class PresetBrowserSelectionTests: XCTestCase {
    private func product(_ id: String, vendor: String, name: String) -> OPRAProductEntry {
        OPRAProductEntry(
            id: id, vendorName: vendor, productName: name,
            subtype: nil, thumbnailURL: nil, curves: [])
    }

    private lazy var catalog: [OPRAProductEntry] = [
        product("sony-1000", vendor: "Sony", name: "WH-1000XM5"),
        product("sennheiser-hd600", vendor: "Sennheiser", name: "HD 600"),
        product("apple-airpods", vendor: "Apple", name: "AirPods Max"),
    ]

    // Selecting a product, then querying a different model clears the stale selection.
    func testSelectionClearedWhenQueryExcludesIt() {
        let result = PresetBrowserView.validatedSelection(
            "sony-1000", in: catalog, matching: "Sennheiser")
        XCTAssertNil(result)
    }

    // Editing the query while it still matches the selection keeps it intact.
    func testSelectionRetainedWhenQueryStillMatches() {
        let result = PresetBrowserView.validatedSelection(
            "sony-1000", in: catalog, matching: "sony")
        XCTAssertEqual(result, "sony-1000")
    }

    // Clearing the query ends the active search context and clears the detail selection.
    func testSelectionClearedWhenQueryCleared() {
        let result = PresetBrowserView.validatedSelection(
            "sony-1000", in: catalog, matching: "")
        XCTAssertNil(result)
    }

    // Whitespace-only queries are treated like an empty search.
    func testSelectionClearedWhenQueryContainsOnlyWhitespace() {
        let result = PresetBrowserView.validatedSelection(
            "sony-1000", in: catalog, matching: "   ")
        XCTAssertNil(result)
    }

    // A nil selection stays nil regardless of query.
    func testNilSelectionStaysNil() {
        XCTAssertNil(PresetBrowserView.validatedSelection(nil, in: catalog, matching: "sony"))
        XCTAssertNil(PresetBrowserView.validatedSelection(nil, in: catalog, matching: ""))
    }

    // A selection no longer present in the catalog is dropped.
    func testSelectionClearedWhenAbsentFromCatalog() {
        let result = PresetBrowserView.validatedSelection(
            "removed-id", in: catalog, matching: "")
        XCTAssertNil(result)
    }

    // Matching is case-insensitive and spans the "Vendor Product" label.
    func testFilterMatchesVendorAndProductCaseInsensitively() {
        XCTAssertEqual(PresetBrowserView.filter(catalog, matching: "AIRPODS").map(\.id), ["apple-airpods"])
        XCTAssertEqual(PresetBrowserView.filter(catalog, matching: "hd 600").map(\.id), ["sennheiser-hd600"])
        XCTAssertEqual(PresetBrowserView.filter(catalog, matching: "").count, 3)
    }
}
