// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UHDCategoryView: View {
    @ObservedObject var index: CatalogueIndexStore
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @Environment(\.scenePhase) private var phase
    private var shows: [CatalogueShow] { CategorySorting.sorted(index.uhd,by:.alphabetical) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("4K UHD").font(.largeTitle).bold()
                if let error = index.error { Text(error).font(.callout).foregroundStyle(.orange) }
                HStack(spacing: 24) {
                    Text("\(shows.count) programmes").font(.callout)
                    Spacer()
                    Button { index.requestRefresh() } label: {
                        HStack {
                            if index.loading { ProgressView() }
                            Text("Check for updates")
                        }
                    }.disabled(index.loading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 28)], spacing: 30) {
                    ForEach(shows) { show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library, preferUHDSeries: true) } label: {
                            ShowCard(show: show)
                        }.buttonStyle(ProgrammeCardStyle())
                    }
                }
                if shows.isEmpty && !index.loading { Text("No UHD listings are currently saved. Check for updates to retry.") }
            }.padding(60)
        }
    }
}

private struct SearchRequestKey: Hashable {
    let query: String
    let revisions: [Int]
    let active: Bool
}
struct CatalogueSearchView: View {
    @ObservedObject var index: CatalogueIndexStore
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject private var itv: ITVCatalogueStore
    @ObservedObject private var channel4: Channel4CatalogueStore
    @ObservedObject private var channel5: Channel5CatalogueStore
    @ObservedObject private var u: UCatalogueStore
    @StateObject private var search = CatalogueSearchModel()
    @Environment(\.scenePhase) private var phase
    @State private var query = ""
    @State private var page = 1
    init(index: CatalogueIndexStore, catalogue: CatalogueStore, library: Library) {
        self.index=index;self.catalogue=catalogue;self.library=library
        itv=catalogue.itv;channel4=catalogue.channel4;channel5=catalogue.channel5;u=catalogue.u
    }
    private var results: [CatalogueShow] { search.state.results }
    private var pages: Int { max(1,(results.count+29)/30) }
    private var request: SearchRequestKey {
        SearchRequestKey(query:query,revisions:[index.searchRevision,itv.searchRevision,channel4.searchRevision,channel5.searchRevision,u.searchRevision],active:phase == .active)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let error = search.state.error { Text(error).font(.callout).foregroundStyle(.secondary) }
                if !search.state.query.isEmpty {
                    HStack(spacing: 24) {
                        Text("\(results.count) \(results.count == 1 ? "result" : "results")").font(.title3)
                        Spacer()
                        if search.state.searching { ProgressView().accessibilityLabel("Searching programmes") }
                        if pages > 1 {
                            Button("Previous") { page -= 1 }.disabled(page <= 1)
                            Text("\(min(page, pages)) / \(pages)")
                            Button("Next") { page += 1 }.disabled(page >= pages)
                        }
                    }.frame(height:46)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 28)], spacing: 30) {
                        ForEach(Array(results.dropFirst((min(page,pages)-1)*30).prefix(30))) { show in
                            NavigationLink { CatalogueShowView(show:show,catalogue:catalogue,library:library) } label: { ShowCard(show:show) }.buttonStyle(ProgrammeCardStyle())
                        }
                    }
                    if results.isEmpty && !search.state.searching { Text("No results.") }
                }
            }.padding(60)
        }.searchable(text:$query,prompt:"Search")
        .onChange(of:search.state.query) { _,_ in page=1 }
        .task(id:request) {
            guard phase == .active else { search.cancel();return }
            await search.update(query,source:SearchCatalogueSource(revisions:request.revisions,bbc:index.snapshot,cached:[itv.knownShows,channel4.knownShows,channel5.knownShows,u.knownShows]))
        }.onDisappear { search.cancel() }
        #if DEBUG
        .onAppear { if let preview=ProcessInfo.processInfo.environment["TELLY_SEARCH_QUERY"] { query=preview } }
        #endif
    }
}

#if DEBUG
/// Render the real cached UHD screen without a live catalogue refresh during UI validation.
struct UHDLayoutValidationView: View {
    @StateObject private var index = CatalogueIndexStore()
    @StateObject private var catalogue = CatalogueStore()
    @StateObject private var library = Library()
    @StateObject private var history = WatchHistory()
    var body: some View {
        NavigationStack { UHDCategoryView(index: index, catalogue: catalogue, library: library) }
            .environmentObject(history).task { await index.prepare() }
    }
}
#endif
