import Foundation

/// A single community EQ curve for a product, from the OPRA database.
/// `data` is the raw JSON of the entry's `data` object — already in the exact shape
/// `PresetImporter.parse(data:filename:)` expects (see `OPRAEqInfo` in PresetImporter.swift).
struct OPRACurveEntry: Identifiable, Sendable {
    let id: String
    let author: String
    let details: String?
    let data: Data
}

/// A product (headphone/IEM) from the OPRA database, joined with its vendor name and
/// every community EQ curve available for it. Products with no curves are never produced —
/// they aren't importable.
struct OPRAProductEntry: Identifiable, Sendable {
    let id: String
    let vendorName: String
    let productName: String
    let subtype: String?
    let thumbnailURL: URL?
    let curves: [OPRACurveEntry]
}

enum OPRACatalogError: LocalizedError {
    case noData

    var errorDescription: String? {
        switch self {
        case .noData:
            return "Couldn't load the OPRA preset database. Check your internet connection and try again."
        }
    }
}

/// Fetches, caches, and parses OPRA's community-maintained headphone EQ database
/// (https://github.com/opra-project/OPRA) for the Preset Browser.
@available(macOS 14.2, *)
@MainActor
final class OPRACatalog {
    static let shared = OPRACatalog()

    private static let sourceURL = URL(string: "https://opra.roonlabs.net/database_v1.jsonl")!
    private nonisolated static let assetBaseURL = URL(string: "https://opra.roonlabs.net/")!
    private static let cacheMaxAge: TimeInterval = 24 * 60 * 60
    private static let lastFetchedKey = "com.iqualize.opraCatalogFetchedAt"

    private var cached: [OPRAProductEntry]?

    private init() {}

    /// Returns the parsed product catalog, using a same-day disk cache when available and
    /// falling back to any existing (even stale) cache if a fresh network fetch fails.
    func loadIfNeeded() async throws -> [OPRAProductEntry] {
        if let cached { return cached }

        let cacheURL = Self.cacheFileURL()
        let lastFetched = UserDefaults.standard.object(forKey: Self.lastFetchedKey) as? Date
        let isFresh = lastFetched.map { Date().timeIntervalSince($0) < Self.cacheMaxAge } ?? false

        if isFresh, let data = try? Data(contentsOf: cacheURL) {
            let products = try await Self.parse(data)
            cached = products
            return products
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: Self.sourceURL)
            try? Self.writeCache(data, to: cacheURL)
            UserDefaults.standard.set(Date(), forKey: Self.lastFetchedKey)
            let products = try await Self.parse(data)
            cached = products
            return products
        } catch {
            guard let data = try? Data(contentsOf: cacheURL) else { throw error }
            let products = try await Self.parse(data)
            cached = products
            return products
        }
    }

    private static func cacheFileURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.iqualize.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("opra_database_v1.jsonl")
    }

    private static func writeCache(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Parses the JSONL database (one JSON object per line: vendor / product / eq) into
    /// joined `OPRAProductEntry` values. Done off the main actor since this walks tens of
    /// thousands of lines.
    nonisolated private static func parse(_ data: Data) async throws -> [OPRAProductEntry] {
        try await Task.detached(priority: .userInitiated) {
            var vendorNames: [String: String] = [:]
            struct PendingProduct {
                var name: String
                var subtype: String?
                var vendorID: String?
                var thumbnailPath: String?
            }
            var products: [String: PendingProduct] = [:]
            var curvesByProduct: [String: [OPRACurveEntry]] = [:]

            guard let text = String(data: data, encoding: .utf8) else { throw OPRACatalogError.noData }

            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let type = object["type"] as? String,
                      let payload = object["data"] as? [String: Any] else { continue }

                switch type {
                case "vendor":
                    guard let id = object["id"] as? String, let name = payload["name"] as? String else { continue }
                    vendorNames[id] = name

                case "product":
                    guard let id = object["id"] as? String, let name = payload["name"] as? String else { continue }
                    products[id] = PendingProduct(
                        name: name,
                        subtype: payload["subtype"] as? String,
                        vendorID: payload["vendor_id"] as? String,
                        thumbnailPath: payload["line_art_96x64_png"] as? String
                    )

                case "eq":
                    guard let id = object["id"] as? String,
                          let author = payload["author"] as? String,
                          let productID = payload["product_id"] as? String,
                          let curveData = try? JSONSerialization.data(withJSONObject: payload) else { continue }
                    let curve = OPRACurveEntry(id: id, author: author, details: payload["details"] as? String, data: curveData)
                    curvesByProduct[productID, default: []].append(curve)

                default:
                    continue
                }
            }

            var entries: [OPRAProductEntry] = []
            entries.reserveCapacity(products.count)
            for (productID, product) in products {
                guard let curves = curvesByProduct[productID], !curves.isEmpty else { continue }
                let vendorName = product.vendorID.flatMap { vendorNames[$0] } ?? "Unknown"
                let thumbnailURL = product.thumbnailPath.flatMap { URL(string: $0, relativeTo: assetBaseURL) }
                entries.append(OPRAProductEntry(
                    id: productID,
                    vendorName: vendorName,
                    productName: product.name,
                    subtype: product.subtype,
                    thumbnailURL: thumbnailURL?.absoluteURL,
                    curves: curves
                ))
            }

            return entries.sorted {
                ($0.vendorName, $0.productName) < ($1.vendorName, $1.productName)
            }
        }.value
    }
}
