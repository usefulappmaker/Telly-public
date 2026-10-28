// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor final class CatalogueStore: ObservableObject {
    let itv = ITVCatalogueStore()
    let channel4 = Channel4CatalogueStore()
    let channel5 = Channel5CatalogueStore()
    let u = UCatalogueStore()
    @Published private(set) var categoryDates: [String:Date] = {
        guard let data = try? Data(contentsOf:CatalogueStore.categoryDateFile), data.count < 2_000_000 else { return [:] }
        return (try? JSONDecoder().decode([String:Date].self,from:data)) ?? [:]
    }()
    private static var categoryDateFile: URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("category-dates-v1.json") }
    @Published var home: HomeFeed?
    @Published var genres: [Genre] = Genre.seed()
    @Published private(set) var programmeLoadingIDs = Set<UUID>()
    func beginProgrammeLoading(_ id: UUID) { programmeLoadingIDs.insert(id) }
    func endProgrammeLoading(_ id: UUID) { programmeLoadingIDs.remove(id) }
    @Published var resumingEpisode = false
    @Published var loading = false
    @Published var error: String?
    @Published var storageWarning: String?
    var programmeOpened: ((CatalogueShow, String) -> Void)?
    private let discovery: DiscoveryAPI
    private let catalogue: CatalogueAPI
    private let cache: DiscoveryCache
    private var started = false
    private var details: [String: CatalogueShow] = [:]
    private var recent = [String]()
    init(discovery: DiscoveryAPI = DiscoveryAPI(), catalogue: CatalogueAPI = CatalogueAPI(), cache: DiscoveryCache = DiscoveryCache()) {
        self.discovery = discovery; self.catalogue = catalogue; self.cache = cache
    }
    func boot() async {
        guard !started else { return }; started = true
        #if DEBUG
        if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] != nil { loadUIFixture(); return }
        #endif
        home = await cache.read(HomeFeed.self, key: "homepage")
        genres = await cache.read([Genre].self, key: "genres") ?? Genre.seed()
        await refreshHome()
    }
    func refreshHome() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] != nil { loadUIFixture(); return }
        #endif
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        details.removeAll(); recent.removeAll()
        async let feed = discovery.homepage()
        async let categories = discovery.genres()
        do {
            home = try await feed
            do { try await cache.write(home!, key: "homepage") } catch { storageWarning = "Homepage could not be saved for offline browsing." }
        } catch { if !Task.isCancelled { self.error = "Could not refresh discovery. \(error.localizedDescription)" } }
        do {
            let refreshed = try await categories
            if !refreshed.isEmpty { genres = refreshed; try? await cache.write(genres, key: "genres") }
        } catch { /* Keep cached/bundled categories independently of homepage availability. */ }
    }
    #if DEBUG
    /// Offline fixtures exercise layout/focus without depending on BBC availability.
    private func loadUIFixture() {
        let titles = ["The Reluctant Vampire", "Blue Lights", "The Americas", "Asia", "A much longer programme title on two lines", "Wild Isles", "Doctor Who", "The Capture"]
        let shows = titles.enumerated().map { index, title in
            CatalogueShow(id: "preview-\(index)", title: title, summary: "Discover the latest programmes on Telly.", image: URL(string: "http://127.0.0.1:18745/\(index % 2 == 0 ? "wide.png" : "portrait.png")"), letter: "a", channel: "BBC", categories: [], expectedEpisodes: index % 2 == 0 ? 8 : 0, singleEpisode: false, episodes: [], indexedAt: nil, uhdListed: index % 2 == 0)
        }
        let features = shows.map { HomeFeature(show: $0, headline: $0.title, synopsis: $0.summary, image: $0.image) }
        home = HomeFeed(features: ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "cards" ? [] : features, rows: [HomeRow(id: "preview", title: "New & Trending", shows: shows)])
    }
    #endif

    func open(_ show: CatalogueShow) async throws -> CatalogueShow {
        var result = try await resolveShow(show)
        result.catalogueDate = CategorySorting.knownDate(result,cached:categoryDates)
        if let date = result.catalogueDate, categoryDates[result.id] != date {
            categoryDates[result.id] = date
            if let data = try? JSONEncoder().encode(categoryDates), data.count < 2_000_000 { try? data.write(to:Self.categoryDateFile,options:.atomic) }
        }
        return result
    }
    private func resolveShow(_ show: CatalogueShow) async throws -> CatalogueShow {
        #if DEBUG
        if ["itv-programme", "itv-collection"].contains(ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] ?? ""), show.provider == .itv,
           let path = show.providerURL?.path, let metadata = itv.cached(path) {
            return try ITVCatalogueAPI.details(metadata, fallback: show)
        }
        #endif
        if show.provider == .itv { return try await itv.details(show) }
        if show.provider == .channel4 { return try await channel4.details(show) }
        if show.provider == .channel5 { return try await channel5.details(show) }
        if show.provider == .u { return try await u.details(show) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "programme" { return show }
        #endif
        if let loaded = details[show.id] { programmeOpened?(loaded, show.id); return loaded }
        let old = await cache.read(CatalogueShow.self, key: "show-" + show.id)
        do {
            let metadata: CatalogueShow
            if let episodeID = show.discoveryEpisodeID {
                metadata = try await discovery.parent(of: Programme(id: episodeID, title: show.title, summary: "", image: nil, version: "", guidance: nil))
            } else { metadata = try await discovery.show(show.id) }
            let updated = try await catalogue.details(metadata)
            details[show.id] = updated; recent.removeAll { $0 == show.id }; recent.append(show.id)
            while recent.count > 12 { details.removeValue(forKey: recent.removeFirst()) }
            try? await cache.write(updated, key: "show-" + show.id)
            programmeOpened?(updated, show.id)
            return updated
        } catch { if !Task.isCancelled, let old { return old }; throw error }
    }
}
struct PageSnapshot: Codable { let shows: [CatalogueShow]; let page: Int; let totalPages: Int; let count: Int }
@MainActor final class PageStore: ObservableObject {
    @Published var shows: [CatalogueShow] = []
    @Published var page = 1
    @Published var totalPages = 1
    @Published var count = 0
    @Published var loading = false
    @Published var error: String?
    private var requestID = UUID()
    let api: DiscoveryAPI
    let cache: DiscoveryCache
    init(api: DiscoveryAPI = DiscoveryAPI(), cache: DiscoveryCache = DiscoveryCache()) { self.api = api; self.cache = cache }
    func load(category: String? = nil, letter: String? = nil, page: Int) async {
        let id = UUID(); requestID = id; loading = true; error = nil; shows = []
        defer { if requestID == id { loading = false } }
        let key = "page-\(category ?? letter ?? "none")-\(page)"
        let cached = await cache.read(PageSnapshot.self, key: key)
        if let cached, requestID == id {
            shows = cached.shows; self.page = cached.page; totalPages = cached.totalPages; count = cached.count
        }
        do {
            let result = try await api.page(category: category, letter: letter, page: page)
            try Task.checkCancellation(); guard requestID == id else { return }
            self.page = result.page; count = result.total; totalPages = max(1, Int(ceil(Double(result.total) / Double(result.perPage))))
            shows = result.shows
            try? await cache.write(PageSnapshot(shows: shows, page: self.page, totalPages: totalPages, count: count), key: key)
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            if let cached { shows = cached.shows }
            self.error = error.localizedDescription
        }
    }
}


@MainActor final class UnifiedFeaturedStore: ObservableObject {
    @Published private(set) var features: [HomeFeature] = []
    private var sources: [ContentProvider:[HomeFeature]] = [:]
    private var editorial = Set<ContentProvider>()
    private let client = FeaturedCatalogueClient()
    private var refreshing = false
    private var refreshedAt: Date?
    private static var cache: URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("featured-networks-v1.json") }
    init() {
        if let data = try? Data(contentsOf:Self.cache), data.count < 1_000_000,
           let cached = try? JSONDecoder().decode([String:[HomeFeature]].self,from:data) {
            for provider in FeaturedCatalogue.providers { sources[provider] = cached[provider.rawValue] }
            features = FeaturedCatalogue.mix(sources)
        }
    }
    func update(_ provider: ContentProvider, _ candidates: [HomeFeature], editorial: Bool = true) {
        guard !candidates.isEmpty else { return }
        if editorial { self.editorial.insert(provider) }
        else if self.editorial.contains(provider) || sources[provider]?.isEmpty == false { return }
        sources[provider] = candidates; features = FeaturedCatalogue.mix(sources)
        let saved = Dictionary(uniqueKeysWithValues:sources.map { ($0.key.rawValue,Array($0.value.prefix(12))) })
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to:Self.cache,options:.atomic) }
    }
    func itv(_ rails: [ITVRail]) {
        let shows = rails.filter { ["featured","trending"].contains($0.id) }.flatMap(\.shows)
        update(.itv,shows.map { FeaturedCatalogue.feature($0) })
    }
    func seed(_ catalogue: CatalogueStore) {
        update(.bbc,catalogue.home?.features ?? [])
        itv(catalogue.itv.home)
        let c4 = catalogue.channel4.knownShows
        let preferred = ["The Great British Bake Off","Gogglebox","Taskmaster","The Piano","Married at First Sight UK"]
        let picks = preferred.compactMap { name in c4.first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame } }
        update(.channel4,(picks.isEmpty ? catalogue.channel4.home : picks).map { FeaturedCatalogue.feature($0) },editorial:false)
        update(.channel5,catalogue.channel5.home.map { FeaturedCatalogue.feature($0) },editorial:false)
        update(.u,catalogue.u.home.map { FeaturedCatalogue.feature($0) },editorial:false)
    }
    func refresh(_ catalogue: CatalogueStore) async {
        seed(catalogue)
        guard !refreshing, refreshedAt.map({ Date().timeIntervalSince($0) > 900 }) ?? true else { return }
        refreshing = true; defer { refreshing = false }
        let knownU = catalogue.u.knownShows, known5 = catalogue.channel5.knownShows, client = client
        await withTaskGroup(of:(ContentProvider,[HomeFeature]).self) { group in
            group.addTask { (.u,(try? await client.u(knownU)) ?? []) }
            group.addTask { (.channel5,(try? await client.channel5(known5)) ?? []) }
            for await (provider,values) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                update(provider,values)
            }
        }
        if !Task.isCancelled { refreshedAt = Date() }
    }
}
