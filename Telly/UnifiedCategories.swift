// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct UnifiedCategory: Identifiable {
    let id: String
    let title: String
    var bbc: [Genre] = []
    var itv: [ITVCategory] = []
    var channel4: [Genre] = []
    var channel5: [Genre] = []
    var u: [Genre] = []
    var providers: [ContentProvider] { (bbc.isEmpty ? [] : [.bbc]) + (itv.isEmpty ? [] : [.itv]) + (channel4.isEmpty ? [] : [.channel4]) + (channel5.isEmpty ? [] : [.channel5]) + (u.isEmpty ? [] : [.u]) }

    static func make(bbc: [Genre], itv: [ITVCategory], channel4: [Genre] = [], channel5: [Genre] = [], u: [Genre] = []) -> [UnifiedCategory] {
        var groups: [String: UnifiedCategory] = [:]
        func descriptor(id: String, title: String) -> (String, String) {
            let key = id.lowercased()
            switch key {
            case "drama-and-soaps", "drama-soaps", "drama": return ("drama", "Drama & Soaps")
            case "film", "films": return ("films", "Films")
            case "comedy": return ("comedy", "Comedy")
            case "documentaries", "lifestyle", "factual", "real-life": return ("documentaries-lifestyle", "Documentaries & Lifestyle")
            case "entertainment", "reality": return ("entertainment", "Entertainment")
            case "sport", "sports": return ("sport", "Sport")
            case "news", "news-current-affairs-and-politics": return ("news", "News")
            case "cbbc", "cbeebies", "children", "childrens", "kids": return ("kids", "Kids")
            case "signed", "signed-bsl": return ("signed", "Signed & BSL")
            default:
                let words = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB"))
                    .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
                return (words.joined(separator: "-"), title)
            }
        }
        for genre in bbc {
            let (key, title) = descriptor(id: genre.id, title: genre.title)
            var category = groups[key] ?? UnifiedCategory(id: key, title: title)
            if !category.bbc.contains(where: { $0.id == genre.id }) { category.bbc.append(genre) }
            groups[key] = category
        }
        for genre in itv {
            let (key, title) = descriptor(id: genre.id, title: genre.title)
            var category = groups[key] ?? UnifiedCategory(id: key, title: title)
            if !category.itv.contains(where: { $0.path == genre.path }) { category.itv.append(genre) }
            groups[key] = category
        }
        for genre in channel4 {
            let (key, title) = descriptor(id: genre.id, title: genre.title)
            var category = groups[key] ?? UnifiedCategory(id: key, title: title)
            if !category.channel4.contains(where: { $0.id == genre.id }) { category.channel4.append(genre) }
            groups[key] = category
        }
        for genre in channel5 {
            let (key, title) = descriptor(id: genre.id, title: genre.title)
            var category = groups[key] ?? UnifiedCategory(id: key, title: title)
            if !category.channel5.contains(where: { $0.id == genre.id }) { category.channel5.append(genre) }
            groups[key] = category
        }
        for genre in u {
            let (key, title) = descriptor(id: genre.id, title: genre.title)
            var category = groups[key] ?? UnifiedCategory(id: key, title: title)
            if !category.u.contains(where: { $0.id == genre.id }) { category.u.append(genre) }
            groups[key] = category
        }
        let order = ["drama", "films", "comedy", "documentaries-lifestyle", "sport", "news", "entertainment", "kids", "signed"]
        return groups.values.sorted {
            let a = order.firstIndex(of: $0.id) ?? order.count, b = order.firstIndex(of: $1.id) ?? order.count
            return a == b ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a < b
        }
    }
}

#if canImport(Combine)
import Combine

/// Append a page from each BBC source into one stable, deduplicated network list.
@MainActor final class BBCMergedCategoryStore: ObservableObject {
    @Published private(set) var shows: [CatalogueShow] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var pages: [String: Int] = [:]
    private var totals: [String: Int] = [:]
    private let api: DiscoveryAPI
    init(api: DiscoveryAPI = DiscoveryAPI()) { self.api = api }
    private var generation = UUID()
    func reset() { generation = UUID(); shows = []; pages = [:]; totals = [:]; error = nil; loading = false }
    func next(genres: [Genre], sort: CategorySortOrder = .alphabetical) async {
        guard !loading else { return }
        let pending = genres.filter { pages[$0.id, default: 0] < totals[$0.id, default: 1] }
        guard !pending.isEmpty else { return }
        let id = generation
        loading = true; error = nil
        defer { if generation == id { loading = false } }
        var batches: [[CatalogueShow]] = []
        var failed = false
        for genre in pending {
            do {
                try Task.checkCancellation()
                let requested = pages[genre.id, default: 0] + 1
                let result = try await api.page(category: genre.id, page: requested, sort:sort)
                try Task.checkCancellation()
                guard id == generation else { return }
                guard result.page == requested, !result.shows.isEmpty || result.total == 0 else { throw BBCError.message("BBC returned an unexpected catalogue page.") }
                pages[genre.id] = result.page
                totals[genre.id] = max(1, Int(ceil(Double(result.total) / Double(result.perPage))))
                batches.append(result.shows)
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                failed = true
            }
        }
        guard id == generation else { return }
        // Round-robin results so a broad first source does not bury a related source.
        var seen = Set(shows.map(\.id))
        for position in 0..<(batches.map(\.count).max() ?? 0) {
            for batch in batches where position < batch.count {
                if seen.insert(batch[position].id).inserted { shows.append(batch[position]) }
            }
        }
        if failed { error = "Some BBC programmes could not be loaded. You can retry without losing the programmes already shown." }
    }
}
#endif
