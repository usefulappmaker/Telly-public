// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor final class ITVCatalogueStore: ObservableObject {
    @Published var home: [ITVRail] = []
    @Published var categories: [ITVCategory] = []
    @Published var loading = false
    @Published var warning: String?
    private var pages: [String: [String: Any]] = [:]
    private var searchPages: [String: [CatalogueShow]] = [:]
    private(set) var knownShows: [CatalogueShow] = []
    private(set) var searchRevision = 0
    private var savedAt: [String: Date] = [:]
    private var requests: [String: Task<[String: Any], Error>] = [:]
    private let api: ITVCatalogueAPI
    private static var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ITV-catalogue-cache.json")
    }
    private func persist() {
        // Cache only catalogue metadata; signed playback URLs and licence data never enter this store.
        if let data = try? JSONSerialization.data(withJSONObject: pages), data.count < 16 * 1024 * 1024 {
            try? FileManager.default.createDirectory(at: Self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.cacheFile, options: .atomic)
        }
    }
    private func recordRefresh(_ success: Bool) {
        let data = try? JSONSerialization.data(withJSONObject: ["success": success, "rails": home.count, "updatedAt": Date().timeIntervalSince1970])
        try? data?.write(to: Self.cacheFile.deletingLastPathComponent().appendingPathComponent("ITV-catalogue-status.json"), options: .atomic)
    }
    init(api: ITVCatalogueAPI = ITVCatalogueAPI()) {
        self.api = api
        if let url = Bundle.main.url(forResource: "ITVCatalogueSeed", withExtension: "json"),
           let data = try? Data(contentsOf: url), let seed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            pages = seed
            home = ITVCatalogueAPI.rails(seed["/"] ?? [:])
            categories = ITVCatalogueAPI.categories(seed["/watch/categories/drama-soaps"] ?? [:])
        }
        if let data = try? Data(contentsOf: Self.cacheFile), data.count < 16 * 1024 * 1024,
           let cached = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            pages.merge(cached) { _, updated in updated }
            home = ITVCatalogueAPI.rails(pages["/"] ?? [:])
        }
        searchPages = pages.mapValues { ITVCatalogueAPI.rails($0).flatMap(\.shows) }
        rebuildSearchCache()
    }
    private func rebuildSearchCache() {
        var shows = [String: CatalogueShow]()
        for path in searchPages.keys.sorted() { for show in searchPages[path] ?? [] { shows[show.id] = show } }
        knownShows = shows.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        searchRevision &+= 1
    }
    func cached(_ path: String) -> [String: Any]? { pages[path] }
    func page(_ path: String, refresh: Bool = false) async throws -> [String: Any] {
        if !refresh, let date = savedAt[path], Date().timeIntervalSince(date) < 900, let data = pages[path] { return data }
        if let pending = requests[path] { return try await pending.value }
        let api = api
        let task = Task { try await api.page(path) }; requests[path] = task
        defer { requests[path] = nil }
        do {
            let data = try await task.value
            guard !ITVCatalogueAPI.rails(data).isEmpty || data["programme"] != nil || data["collection"] is [String: Any] else { throw BBCError.message("ITV returned no programmes for this page.") }
            pages[path] = data; savedAt[path] = Date()
            searchPages[path] = ITVCatalogueAPI.rails(data).flatMap(\.shows)
            if pages.count > 80, let oldest = savedAt.filter({ $0.key != "/" && $0.key != path }).min(by: { $0.value < $1.value })?.key {
                pages[oldest] = nil; savedAt[oldest] = nil; searchPages[oldest] = nil
            }
            rebuildSearchCache()
            persist()
            if path == "/" { home = ITVCatalogueAPI.rails(data) }
            let fresh = ITVCatalogueAPI.categories(data); if !fresh.isEmpty { categories = fresh }
            return data
        } catch { throw BBCError.message("Couldn't refresh ITV's catalogue. Please retry shortly.") }
    }
    func refreshHome() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do { _ = try await page("/", refresh: true); warning = nil; recordRefresh(true) }
        catch { warning = "Showing the saved ITV catalogue. Refresh is currently unavailable."; recordRefresh(false) }
    }
    func details(_ show: CatalogueShow) async throws -> CatalogueShow {
        guard let url = show.providerURL else { throw BBCError.message("This ITV programme has no catalogue address.") }
        do { return try ITVCatalogueAPI.details(await page(url.path), fallback: show) }
        catch {
            guard let cached = pages[url.path] else { throw error }
            // Availability is rechecked when parsing saved metadata and playback requests a fresh session.
            return try ITVCatalogueAPI.details(cached, fallback: show)
        }
    }
    func search(_ query: String) async throws -> [CatalogueShow] { try await api.search(query) }
}

struct ProviderBadge: View {
    let provider: ContentProvider
    var subdued = false
    var categoryHeading = false
    var body: some View {
        Image(provider.logo).renderingMode(.template).resizable().scaledToFit()
            .frame(width: categoryHeading ? 134.4 : subdued ? 88 : 64,
                   height: categoryHeading ? 56 : subdued ? 36 : 27,
                   alignment: categoryHeading ? .leading : .center)
            .foregroundStyle(.white.opacity(subdued ? 0.35 : 0.85))
            .accessibilityLabel(provider.title)
    }
}

struct ITVCatalogueView: View {
    @ObservedObject var store: ITVCatalogueStore
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @State private var path = "/"
    @State private var rails: [ITVRail] = []
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0
    init(store: ITVCatalogueStore, catalogue: CatalogueStore, library: Library, path: String = "/") {
        self.store = store; self.catalogue = catalogue; self.library = library; _path = State(initialValue: path)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { ProviderBadge(provider: .itv); Text("ITV programmes").font(.largeTitle).bold(); Spacer()
                    Button("Refresh") { retry += 1 }.disabled(loading)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        Button("Featured") { path = "/" }
                        ForEach(store.categories) { category in Button(category.title) { path = category.path } }
                    }.padding(.vertical, 20).padding(.horizontal, 12)
                }.scrollClipDisabled()
                if loading { ProgressView("Updating ITV programmes…") }
                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                ITVProgrammeRails(rails: rails, catalogue: catalogue, library: library)
                if rails.isEmpty && !loading { Text("No ITV programmes are currently available.") }
            }.padding(60)
        }.task(id: "\(path)-\(retry)") {
            let requested = path
            rails = store.cached(path).map(ITVCatalogueAPI.rails) ?? []
            error = nil; loading = true
            do {
                let data = try await store.page(requested, refresh: retry > 0)
                try Task.checkCancellation(); guard requested == path else { return }
                rails = ITVCatalogueAPI.rails(data)
            } catch { if !Task.isCancelled { self.error = rails.isEmpty ? error.localizedDescription : "Showing saved ITV listings. Refresh is unavailable." } }
            if !Task.isCancelled { loading = false }
        }
    }
}
struct ITVProgrammeRails: View {
    let rails: [ITVRail]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var body: some View {
        ForEach(rails) { rail in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(rail.title).font(.title2).bold(); Spacer()
                    if let path = rail.more {
                        NavigationLink("View all") { ITVCollectionView(title: rail.title, path: path, catalogue: catalogue, library: library) }
                    }
                }
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 28) {
                        ForEach(rail.shows) { show in
                            NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) }
                                label: { ShowCard(show: show).frame(width: 330) }.buttonStyle(ProgrammeCardStyle())
                        }
                    }.padding(.vertical, 30).padding(.horizontal, 24)
                }.scrollClipDisabled().padding(.horizontal, -24)
            }
        }
    }
}
struct ITVHomeRows: View {
    @ObservedObject var store: ITVCatalogueStore
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HomepageNetworkHeading(provider:.itv,title:"Discover ITV")
            if let warning = store.warning { Text(warning).font(.callout).foregroundStyle(.secondary) }
            ITVProgrammeRails(rails: Array(store.home.prefix(4)), catalogue: catalogue, library: library)
        }
    }
}
struct ITVCollectionView: View {
    let title: String
    let path: String
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @State private var shows = [CatalogueShow]()
    @State private var error: String?
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss
    @State private var retry = 0
    @AppStorage(CategorySortOrder.preferenceKey) private var sortRaw = CategorySortOrder.alphabetical.rawValue
    private var sortOrder: CategorySortOrder { CategorySortOrder(rawValue:sortRaw) ?? .alphabetical }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack { Text(title).font(.largeTitle).bold(); Spacer(); CategorySortToggle() }
                if let error { Text(error).foregroundStyle(.orange); Button("Retry") { retry += 1 } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 28)], spacing: 30) {
                    ForEach(CategorySorting.sorted(shows,by:sortOrder,cached:catalogue.categoryDates)) { show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) }
                            label: { ShowCard(show: show) }.buttonStyle(ProgrammeCardStyle())
                    }
                }.accessibilityIdentifier("itv-collection-grid")
                if !loading && error == nil && shows.isEmpty {
                    Text("No programmes are currently available in this collection.").foregroundStyle(.secondary)
                }
            }.padding(60)
        }.modifier(ProgrammeLoadingFeedback(active:loading,catalogue:catalogue))
        .onExitCommand { dismiss() }.task(id: retry) {
            loading = true; error = nil
            if shows.isEmpty, let cached = catalogue.itv.cached(path) { shows = ITVCatalogueAPI.rails(cached).flatMap(\.shows) }
            do {
                #if DEBUG
                let props: [String: Any]
                if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "itv-collection", let cached = catalogue.itv.cached(path) { props = cached }
                else { props = try await catalogue.itv.page(path, refresh: retry > 0) }
                #else
                let props = try await catalogue.itv.page(path, refresh: retry > 0)
                #endif
                try Task.checkCancellation()
                var seen = Set<String>()
                shows = ITVCatalogueAPI.rails(props).flatMap(\.shows).filter { seen.insert($0.id).inserted }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}

struct ITVCategoryGrid: View {
    @ObservedObject var store: ITVCatalogueStore
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { ProviderBadge(provider: .itv); Text("ITV categories").font(.title2).bold() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 3), spacing: 24) {
                ForEach(store.categories) { category in
                    NavigationLink { ITVCatalogueView(store: store, catalogue: catalogue, library: library, path: category.path) }
                        label: { CategoryTile(title: category.title, icon: CategoryTile.icon(category.title)) }.buttonStyle(ProgrammeCardStyle())
                }
            }
        }
    }
}

#if DEBUG
struct ITVProgrammePreview: View {
    @StateObject private var catalogue = CatalogueStore()
    @StateObject private var library = Library()
    @StateObject private var history = WatchHistory()
    var body: some View {
        NavigationStack {
            if let show = catalogue.itv.knownShows.first(where: { $0.id == (ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "itv-collection" ? "itv:7s8VA28o6BGW0fkkddmaWQ" : "itv:10a8290") }) {
                CatalogueShowView(show: show, catalogue: catalogue, library: library)
            }
        }.environmentObject(history).tint(Color(white: 0.75))
    }
}
#endif
