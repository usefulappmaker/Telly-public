// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor final class Channel4CatalogueStore: ObservableObject {
    @Published private(set) var home: [CatalogueShow] = []
    private var pages: [String: [CatalogueShow]] = [:]
    private(set) var knownShows: [CatalogueShow] = []
    private(set) var searchRevision = 0
    private var seed: [String: [String: Any]] = [:]
    private let api = Channel4CatalogueAPI()
    private var refreshing = false
    private static var cacheFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("channel4-catalogue-v1.json") }
    init() {
        if let url = Bundle.main.url(forResource: "Channel4Seed", withExtension: "json"), let data = try? Data(contentsOf: url), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            seed = raw
            for (path, value) in raw where path.hasPrefix("/categories") { pages[path] = Channel4CatalogueAPI.page(value).shows }
        }
        if let data = try? Data(contentsOf: Self.cacheFile), data.count < 8_000_000, let saved = try? JSONDecoder().decode([String:[CatalogueShow]].self, from: data) { pages.merge(saved) { _, new in new } }
        home = Array((pages["/categories"] ?? []).prefix(20))
        rebuildSearchCache()
    }
    private func rebuildSearchCache() {
        var seen = Set<String>()
        knownShows = pages.keys.sorted().flatMap { pages[$0] ?? [] }.filter { seen.insert($0.id).inserted }
        searchRevision &+= 1
    }
    func cached(_ id: String?) -> [CatalogueShow] { pages["/categories" + (id.map { "/" + $0 } ?? "")] ?? [] }
    func page(_ id: String?, offset: Int = 0) async throws -> Channel4Page {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "channel4", let raw = seed["/categories" + (id.map { "/" + $0 } ?? "")] {
            let page = Channel4CatalogueAPI.page(raw)
            return Channel4Page(shows: offset == 0 ? page.shows : [], total: page.shows.count, offset: offset)
        }
        #endif
        let page = try await api.category(id, offset: offset)
        try Task.checkCancellation()
        if offset == 0 {
            pages["/categories" + (id.map { "/" + $0 } ?? "")] = page.shows
            rebuildSearchCache()
            if let data = try? JSONEncoder().encode(pages), data.count < 8_000_000 { try? data.write(to: Self.cacheFile, options: .atomic) }
        }
        return page
    }
    func search(_ query: String) async throws -> [CatalogueShow] { try await api.search(query) }
    func refreshHome() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        if let page = try? await page(nil) { home = Array(page.shows.prefix(20)) }
    }
    func details(_ show: CatalogueShow) async throws -> CatalogueShow {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "channel4", let path = show.providerURL?.path, let raw = seed[path] { return try Channel4CatalogueAPI.details(raw, fallback: show) }
        #endif
        return try await api.details(show)
    }
}

struct Channel4HomeRows: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var store: Channel4CatalogueStore
    var body: some View {
        if !store.home.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                HomepageNetworkHeading(provider:.channel4,title:"Popular on Channel 4")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 28) {
                        ForEach(store.home) { show in
                            NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show).frame(width: 330) }.buttonStyle(ProgrammeCardStyle())
                        }
                    }.padding(.vertical, 30).padding(.horizontal, 24)
                }.scrollClipDisabled().padding(.horizontal, -24)
            }
        }
    }
}
struct Channel4CategoryPreview: View {
    let genres: [Genre]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @State private var shows: [CatalogueShow] = []
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ProviderBadge(provider: .channel4, categoryHeading: true).accessibilityIdentifier("category-network-channel4")
                Spacer()
                NavigationLink("View all") { Channel4CategoryView(genres: genres, catalogue: catalogue, library: library) }.accessibilityLabel("View all Channel 4 " + (genres.first?.title ?? "programmes"))
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 28) {
                    ForEach(Array(CategorySorting.sorted(shows,by:.alphabetical).prefix(16))) { show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show).frame(width: 330) }.buttonStyle(ProgrammeCardStyle())
                    }
                }.padding(.vertical, 30).padding(.horizontal, 24)
            }.scrollClipDisabled().padding(.horizontal, -24)
            if loading && shows.isEmpty { ProgressView() }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }.task {
            guard shows.isEmpty else { return }
            var seen = Set<String>()
            shows = genres.flatMap { catalogue.channel4.cached($0.id) }.filter { seen.insert($0.id).inserted }
            loading = true
            var fresh = [CatalogueShow]()
            for genre in genres {
                do { fresh += try await catalogue.channel4.page(genre.id).shows }
                catch { if !Task.isCancelled { self.error = "Some Channel 4 listings could not refresh. Showing available programmes." } }
            }
            guard !Task.isCancelled else { return }
            if !fresh.isEmpty { seen = []; shows = fresh.filter { seen.insert($0.id).inserted } }
            loading = false
        }
    }
}
@MainActor final class Channel4CategoryState: ObservableObject {
    @Published var shows: [CatalogueShow] = []
    @Published var loading = false
    @Published var error: String?
    private var offsets: [String:Int] = [:]
    private var ended: Set<String> = []
    func next(_ genres: [Genre], store: Channel4CatalogueStore) async {
        guard !loading else { return }; loading = true; error = nil; defer { loading = false }
        var seen = Set(shows.map(\.id))
        for genre in genres where !ended.contains(genre.id) {
            let offset = offsets[genre.id, default: 0]
            do {
                let page = try await store.page(genre.id, offset: offset)
                try Task.checkCancellation()
                guard page.offset == offset else { throw BBCError.message("Channel 4 returned an unexpected page. Please retry.") }
                let fresh = page.shows.filter { seen.insert($0.id).inserted }
                shows += fresh
                offsets[genre.id] = offset + page.shows.count
                if page.shows.isEmpty || fresh.isEmpty || offset + page.shows.count >= page.total { ended.insert(genre.id) }
            } catch { if !Task.isCancelled { self.error = "Could not load more Channel 4 programmes. Please retry." } }
        }
    }
}
struct Channel4CategoryView: View {
    let genres: [Genre]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var state = Channel4CategoryState()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack { ProviderBadge(provider: .channel4, categoryHeading: true); Text(genres.map(\.title).joined(separator: " & ")).font(.largeTitle).bold() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 28)], spacing: 30) {
                    ForEach(Array(CategorySorting.sorted(state.shows,by:.alphabetical).enumerated()), id: \.element.id) { position, show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show) }.buttonStyle(ProgrammeCardStyle())
                            .task { if position >= state.shows.count - 8 { await state.next(genres, store: catalogue.channel4) } }
                    }
                }
                if state.loading { ProgressView() }
                if let error = state.error { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await state.next(genres, store: catalogue.channel4) } } }
            }.padding(60)
        }.task { if state.shows.isEmpty { await state.next(genres, store: catalogue.channel4) } }.onExitCommand { dismiss() }
    }
}

#if DEBUG
/// Uses production destinations with bundled public catalogue metadata.
struct Channel4Preview: View {
    @StateObject private var catalogue = CatalogueStore()
    @StateObject private var library = Library()
    @StateObject private var history = WatchHistory()
    var body: some View {
        NavigationStack {
            if ProcessInfo.processInfo.environment["TELLY_C4_PREVIEW"] == "category" {
                Channel4CategoryView(genres: [Genre(id:"film",title:"Films")], catalogue:catalogue,library:library)
            } else if let url = Bundle.main.url(forResource:"Channel4Seed",withExtension:"json"), let data = try? Data(contentsOf:url),
                      let seed = try? JSONSerialization.jsonObject(with:data) as? [String:[String:Any]],
                      let brand = seed["/programmes/the-great-british-bake-off"]?["brand"] as? [String:Any], let show = Channel4CatalogueAPI.show(brand) {
                CatalogueShowView(show:show,catalogue:catalogue,library:library)
            }
        }.environmentObject(history).tint(Color(white:0.75))
    }
}
#endif
