// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

@MainActor final class ContinuousCatalogueStore: ObservableObject {
    @Published var shows: [CatalogueShow] = []
    @Published var count = 0
    @Published var loading = false
    @Published var error: String?
    private let api: DiscoveryAPI
    init(api: DiscoveryAPI = DiscoveryAPI()) { self.api = api }
    private var page = 0
    private var totalPages: Int?
    var hasMore: Bool { totalPages.map { page < $0 } ?? true }
    private var generation = UUID()
    func reset() { generation = UUID(); shows = []; count = 0; page = 0; totalPages = nil; loading = false; error = nil }
    func next(category: String?, letter: String?, sort: CategorySortOrder = .alphabetical) async {
        guard !loading, hasMore else { return }
        let id = generation
        loading = true; error = nil
        defer { if generation == id { loading = false } }
        do {
            let result = try await api.page(category:category,letter:letter,page:page + 1,sort:sort)
            try Task.checkCancellation()
            guard id == generation else { return }
            guard result.page == page+1 else {throw BBCError.message("The catalogue could not continue. Please retry.")}
            var existing = Set(shows.map(\.id)); let added = result.shows.filter { existing.insert($0.id).inserted }
            guard !added.isEmpty || result.total == 0 else {throw BBCError.message("No further programmes were returned. Please retry.")}
            shows += added; count = result.total; page = result.page
            totalPages = max(1, Int(ceil(Double(result.total) / Double(result.perPage))))
        } catch {if id == generation && !Task.isCancelled {self.error = error.localizedDescription}}
    }
}
