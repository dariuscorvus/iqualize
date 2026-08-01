import XCTest
@testable import iQualize

@available(macOS 14.2, *)
final class OPRASearchTests: XCTestCase {
    private func product(_ id: String, vendor: String, name: String) -> OPRAProductEntry {
        OPRAProductEntry(
            id: id, vendorName: vendor, productName: name,
            subtype: nil, thumbnailURL: nil, curves: [])
    }

    // A catalog in the same vendor/product-sorted order OPRACatalog.parse produces.
    private lazy var catalog: [OPRAProductEntry] = [
        product("apple-airpods", vendor: "Apple", name: "AirPods Max"),
        product("focal-utopia", vendor: "Focal", name: "Utopia"),
        product("sennheiser-hd600", vendor: "Sennheiser", name: "HD 600"),
        product("sennheiser-hd650", vendor: "Sennheiser", name: "HD 650"),
        product("sennheiser-hd800s", vendor: "Sennheiser", name: "HD 800 S"),
        product("sony-1000", vendor: "Sony", name: "WH-1000XM5"),
        product("beyer-dt770", vendor: "beyerdynamic", name: "DT 770 PRO"),
    ]

    private func ids(_ query: String) -> [String] {
        OPRASearch.filter(catalog, matching: query).map(\.id)
    }

    // MARK: - normalize

    // Compact, spaced, hyphenated, and underscored spellings collapse to one canonical form.
    func testNormalizeCollapsesSeparators() {
        let canonical = "hd800s"
        for variant in ["HD800S", "HD 800 S", "HD-800-S", "hd_800_s", "  HD 800  S  ", "H.D 800/S"] {
            XCTAssertEqual(OPRASearch.normalize(variant), canonical, "\(variant) should normalize to \(canonical)")
        }
    }

    // Diacritics fold to their base letters.
    func testNormalizeStripsDiacritics() {
        XCTAssertEqual(OPRASearch.normalize("Sennheiser Ié"), "sennheiserie")
        XCTAssertEqual(OPRASearch.normalize("Åmp"), "amp")
    }

    // MARK: - equivalent spellings (the reported bug)

    // The core #156 case: compact vs. spaced model names return the same product.
    func testCompactAndSpacedModelMatchIdentically() {
        XCTAssertEqual(ids("Sennheiser HD800S"), ids("Sennheiser HD 800 S"))
        XCTAssertEqual(ids("Sennheiser HD800S"), ["sennheiser-hd800s"])
    }

    // Compact, spaced, hyphenated, underscored, and mixed-case model queries all agree.
    func testAllSeparatorVariantsMatch() {
        for query in ["HD800S", "HD 800 S", "HD-800-S", "hd_800_s", "hd800s", "Hd 800 s"] {
            XCTAssertEqual(ids(query), ["sennheiser-hd800s"], "query \(query) should match only HD 800 S")
        }
    }

    // MARK: - partial and manufacturer-only queries

    // A manufacturer-only query returns every product for that vendor, vendor/product-ordered.
    func testManufacturerOnlyQuery() {
        XCTAssertEqual(ids("Sennheiser"), ["sennheiser-hd600", "sennheiser-hd650", "sennheiser-hd800s"])
    }

    // Manufacturer matching ignores case and spacing (beyerdynamic is one compact word).
    func testManufacturerNormalizedMatch() {
        XCTAssertEqual(ids("beyer dynamic"), ["beyer-dt770"])
        XCTAssertEqual(ids("BEYERDYNAMIC"), ["beyer-dt770"])
    }

    // A partial model query still matches.
    func testPartialModelQuery() {
        XCTAssertEqual(ids("HD 8"), ["sennheiser-hd800s"])
        XCTAssertEqual(Set(ids("HD 6")), ["sennheiser-hd600", "sennheiser-hd650"])
    }

    // Repeated and leading/trailing whitespace doesn't change the result.
    func testRepeatedWhitespace() {
        XCTAssertEqual(ids("   Sennheiser    HD   800  S "), ["sennheiser-hd800s"])
    }

    // MARK: - empty and no-match

    // An empty or whitespace-only query returns the whole catalog unchanged.
    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(ids(""), catalog.map(\.id))
        XCTAssertEqual(ids("   "), catalog.map(\.id))
    }

    // A query with no plausible match returns nothing — normalization must not over-match.
    func testUnrelatedQueryReturnsNothing() {
        XCTAssertEqual(ids("Grado SR80"), [])
        XCTAssertEqual(ids("zzzz"), [])
    }

    // MARK: - ranking and determinism

    // Exact display-name and normalized-exact matches outrank substring matches.
    func testRankingPrefersExactOverSubstring() {
        let ranked = [
            product("substring", vendor: "Sony", name: "Custom HD 600 Edition"),
            product("exact", vendor: "Sennheiser", name: "HD 600"),
        ]
        // "HD600" is a normalized-exact match for the Sennheiser and a substring for the Sony;
        // the exact match must come first regardless of catalog order.
        XCTAssertEqual(OPRASearch.filter(ranked, matching: "Sennheiser HD600").map(\.id), ["exact"])
        XCTAssertEqual(OPRASearch.filter(ranked, matching: "HD600").map(\.id), ["exact", "substring"])
    }

    // Equal-ranked results keep the catalog's incoming order (deterministic, stable).
    func testEqualRankKeepsCatalogOrder() {
        XCTAssertEqual(ids("Sennheiser"), ["sennheiser-hd600", "sennheiser-hd650", "sennheiser-hd800s"])
    }
}
