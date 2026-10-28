// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor final class UCatalogueStore: ObservableObject {
    @Published private(set) var knownShows: [CatalogueShow] = [] { didSet { searchRevision &+= 1 } }
    private(set) var searchRevision = 0
    @Published private(set) var error: String?
    private let client = UCatalogueClient()
    private var refreshing = false
    private var refreshed = false
    private var detailsCache: [String:CatalogueShow] = [:]
    private static var cache: URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("u-catalogue-v2.json") }
    init() {
        if let data = try? Data(contentsOf:Self.cache), data.count < 8_000_000,
           let shows = try? JSONDecoder().decode([CatalogueShow].self,from:data), shows.allSatisfy({ $0.provider == .u }) { knownShows = shows }
        if knownShows.isEmpty, let brands = Bundle.main.url(forResource:"USeed",withExtension:"json"),
           let categories = Bundle.main.url(forResource:"UCategorySeed",withExtension:"json"),
           let data = try? Data(contentsOf:brands), let categoryData = try? Data(contentsOf:categories) {
            knownShows = (try? UCatalogueAPI.shows(data,directory:UCatalogueAPI.directory(categoryData))) ?? []
        }
    }
    var home: [CatalogueShow] {
        let comedy = knownShows.filter { UCatalogueAPI.belongs($0,genre:"comedy") }
        let preferred = ["Parks and Recreation", "The Good Place", "Taskmaster", "Would I Lie to You?", "Red Dwarf", "QI", "Not Going Out"]
        let highlights = preferred.compactMap { name in comedy.first { $0.title == name } }
        let ids = Set(highlights.map(\.id))
        return Array((highlights + comedy.filter { !ids.contains($0.id) }).prefix(20))
    }
    func refresh() async {
        guard !refreshing, !refreshed else { return }; refreshing = true
        defer { refreshing = false }
        do {
            let shows = try await client.all(); try Task.checkCancellation()
            knownShows = shows; refreshed = true; error = nil
            if let data = try? JSONEncoder().encode(shows) { try? data.write(to:Self.cache,options:.atomic) }
        } catch { if !Task.isCancelled { self.error = "U listings could not refresh. Showing the saved catalogue." } }
    }
    func category(_ genres: [Genre]) -> [CatalogueShow] {
        knownShows.filter { show in genres.contains { UCatalogueAPI.belongs(show,genre:$0.id) } }
    }
    func details(_ show: CatalogueShow) async throws -> CatalogueShow {
        if let cached = detailsCache[show.id], let date = cached.indexedAt, Date().timeIntervalSince(date) < 300 { return cached }
        let result = try await client.details(show); try Task.checkCancellation()
        if detailsCache.count >= 12 { detailsCache.removeAll() }
        detailsCache[show.id] = result
        return result
    }
}

struct UHomeRows: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var store: UCatalogueStore
    var body: some View {
        if !store.home.isEmpty {
            VStack(alignment:.leading,spacing:20) {
                HomepageNetworkHeading(provider:.u,title:"Comedy on U")
                UShowRow(shows:store.home,catalogue:catalogue,library:library)
            }
        }
    }
}
private struct UShowRow: View {
    let shows: [CatalogueShow]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing:28) {
                ForEach(shows) { show in
                    NavigationLink { CatalogueShowView(show:show,catalogue:catalogue,library:library) } label: { ShowCard(show:show).frame(width:330) }
                        .buttonStyle(ProgrammeCardStyle()).accessibilityIdentifier(show.id)
                }
            }.padding(.vertical,30).padding(.horizontal,24)
        }.scrollClipDisabled().padding(.horizontal,-24)
    }
}
struct UCategoryPreview: View {
    let genres: [Genre]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var store: UCatalogueStore
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                ProviderBadge(provider:.u,categoryHeading:true).accessibilityIdentifier("category-network-u")
                Spacer()
                NavigationLink("View all") { UCategoryView(genres:genres,catalogue:catalogue,library:library,store:store) }
                    .accessibilityLabel("View all U programmes")
            }
            UShowRow(shows:Array(CategorySorting.sorted(store.category(genres),by:.alphabetical).prefix(20)),catalogue:catalogue,library:library)
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
                Button("Retry U") { Task { await store.refresh() } }
            }
        }.task { await store.refresh() }
    }
}
struct UCategoryView: View {
    let genres: [Genre]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var store: UCatalogueStore
    @State private var visible = 30
    @Environment(\.dismiss) private var dismiss
    private var shows: [CatalogueShow] { CategorySorting.sorted(store.category(genres),by:.alphabetical) }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                ProviderBadge(provider:.u,categoryHeading:true)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:330),spacing:28)],spacing:30) {
                    ForEach(Array(shows.prefix(visible).enumerated()),id:\.element.id) { position,show in
                        NavigationLink { CatalogueShowView(show:show,catalogue:catalogue,library:library) } label: { ShowCard(show:show) }
                            .buttonStyle(ProgrammeCardStyle()).accessibilityIdentifier(show.id)
                            .task { if position >= visible - 8 { visible = min(shows.count,visible + 30) } }
                    }
                }
                if shows.isEmpty { Text("No U programmes are currently listed in this category.").foregroundStyle(.secondary) }
                if let error = store.error { Text(error).foregroundStyle(.secondary) }
            }.padding(60)
        }.task { await store.refresh() }.onExitCommand { dismiss() }
    }
}

#if DEBUG
struct UCatalogueValidationView: View {
    @StateObject private var catalogue = CatalogueStore()
    @StateObject private var library = Library()
    @StateObject private var history = WatchHistory()
    var body: some View {
        NavigationStack {
            UCategoryView(genres:[Genre(id:"comedy",title:"Comedy")],catalogue:catalogue,library:library,store:catalogue.u)
        }.environmentObject(history)
    }
}
#endif

