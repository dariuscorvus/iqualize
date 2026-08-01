import Foundation

/// Normalizing, rankable search over the OPRA product catalog.
///
/// The catalog's model names are written inconsistently — `HD800S`, `HD 800 S`, `HD-800-S`,
/// `hd_800_s` all name the same headphone — so a literal `contains` returns very different
/// result sets depending on how the user happens to space or punctuate the query (#156). This
/// type collapses those variants to one canonical form before matching.
///
/// Kept out of the SwiftUI view so it is independently testable domain logic.
enum OPRASearch {
    /// Canonical form used for both indexed names and user queries: Unicode-normalized,
    /// diacritics stripped, case-folded, and reduced to alphanumerics only. Every separator
    /// (space, hyphen, underscore, punctuation) is discarded, so compact, spaced, and
    /// hyphenated spellings of the same model collapse to the same string.
    ///
    /// `HD800S`, `HD 800 S`, `HD-800-S`, `hd_800_s` → `hd800s`.
    static func normalize(_ text: String) -> String {
        // Decompose accented characters (é → e + combining accent), then drop the combining
        // marks, so diacritics don't defeat matching. `folding` also lowercases.
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        result.reserveCapacity(folded.unicodeScalars.count)
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    /// Match tiers, best first. `filter` sorts by this then by the catalog's existing
    /// vendor/product order, so equal-ranked results stay deterministic.
    enum Rank: Int, Comparable {
        /// The query equals the whole "Vendor Product" display label, case-insensitively.
        case exactDisplay = 0
        /// The normalized query equals the normalized label exactly.
        case exactNormalized = 1
        /// The normalized label begins with the normalized query (token/model prefix).
        case normalizedPrefix = 2
        /// The normalized query appears somewhere inside the normalized label.
        case normalizedSubstring = 3

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The best tier at which `query` matches `product`, or `nil` when it doesn't match.
    /// `rawQuery`/`normalizedQuery` are the caller-normalized forms, passed in so a `filter`
    /// over the whole catalog normalizes the query only once.
    ///
    /// Matching considers both the combined "Vendor Product" label and the product name alone,
    /// so a bare model query (`HD600`) ranks the headphone actually named that above one whose
    /// label merely contains it (`Sony Custom HD 600 Edition`).
    static func rank(
        of product: OPRAProductEntry,
        rawQuery: String,
        normalizedQuery: String
    ) -> Rank? {
        let display = "\(product.vendorName) \(product.productName)"
        if display.localizedCaseInsensitiveCompare(rawQuery) == .orderedSame {
            return .exactDisplay
        }
        guard !normalizedQuery.isEmpty else { return nil }

        let normalizedDisplay = normalize(display)
        let normalizedName = normalize(product.productName)
        if normalizedDisplay == normalizedQuery || normalizedName == normalizedQuery {
            return .exactNormalized
        }
        if normalizedDisplay.hasPrefix(normalizedQuery) || normalizedName.hasPrefix(normalizedQuery) {
            return .normalizedPrefix
        }
        if normalizedDisplay.contains(normalizedQuery) { return .normalizedSubstring }
        return nil
    }

    /// Products matching `query`, best tier first, ties broken by the catalog's existing order
    /// (a stable sort over an already vendor/product-sorted catalog). An empty or
    /// whitespace-only query returns the catalog unchanged.
    static func filter(_ products: [OPRAProductEntry], matching query: String) -> [OPRAProductEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return products }
        let normalizedQuery = normalize(trimmed)

        let ranked: [(index: Int, product: OPRAProductEntry, rank: Rank)] = products.enumerated().compactMap {
            guard let rank = rank(of: $0.element, rawQuery: trimmed, normalizedQuery: normalizedQuery) else {
                return nil
            }
            return (index: $0.offset, product: $0.element, rank: rank)
        }

        return ranked.sorted {
            $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index
        }.map(\.product)
    }
}
