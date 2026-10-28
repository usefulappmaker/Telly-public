// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UnifiedCategoriesGrid: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var itv: ITVCatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var index: CatalogueIndexStore
    private var categories: [UnifiedCategory] { UnifiedCategory.make(bbc: catalogue.genres, itv: itv.categories, channel4: Channel4CatalogueAPI.categories, channel5: Channel5CatalogueAPI.categories, u: UCatalogueAPI.genres) }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 3), spacing: 24) {
            NavigationLink { UHDCategoryView(index: index, catalogue: catalogue, library: library) } label: {
                CategoryTile(title: "4K UHD", icon: "4k.tv")
            }.buttonStyle(ProgrammeCardStyle()).accessibilityLabel("4K UHD").accessibilityIdentifier("browse-category-uhd")
            ForEach(categories) { category in
                NavigationLink {
                    UnifiedCategoryView(category: category, catalogue: catalogue, library: library)
                } label: {
                    CategoryTile(title: category.title, icon: CategoryTile.icon(category.id))
                }.buttonStyle(ProgrammeCardStyle()).accessibilityLabel(category.title)
                    .accessibilityIdentifier("browse-category-" + category.id)
            }
        }
    }
}

struct UnifiedCategoryView: View {
    let category: UnifiedCategory
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text(category.title).font(.largeTitle).bold()
                if !category.bbc.isEmpty {
                    BBCNetworkCategoryPreview(title: category.title, genres: category.bbc, catalogue: catalogue, library: library)
                }
                if !category.itv.isEmpty {
                    ITVCategoryPreview(genre: category.itv[0], catalogue: catalogue, library: library)
                }
                if !category.channel4.isEmpty {
                    Channel4CategoryPreview(genres: category.channel4, catalogue: catalogue, library: library)
                }
                if !category.channel5.isEmpty {
                    Channel5CategoryPreview(genres: category.channel5, catalogue: catalogue, library: library, store: catalogue.channel5)
                }
                if !category.u.isEmpty {
                    UCategoryPreview(genres: category.u, catalogue: catalogue, library: library, store: catalogue.u)
                }
            }.padding(60)
        }.onExitCommand { dismiss() }
    }
}

/// One network row, including related BBC subcategories without repeating headings.
private struct BBCNetworkCategoryPreview: View {
    let title: String
    let genres: [Genre]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var page = BBCMergedCategoryStore()
    @AppStorage(CategorySortOrder.preferenceKey) private var sortRaw = CategorySortOrder.alphabetical.rawValue
    private var sortOrder: CategorySortOrder { CategorySortOrder(rawValue:sortRaw) ?? .alphabetical }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ProviderBadge(provider: .bbc, categoryHeading: true).accessibilityIdentifier("category-network-bbc")
                Spacer()
                NavigationLink("View all") { BBCNetworkCategoryPage(title: title, genres: genres, catalogue: catalogue, library: library) }
                    .accessibilityLabel("View all BBC " + title)
            }
            CategoryProgrammeRow(shows: page.shows, catalogue: catalogue, library: library)
            if page.loading { ProgressView() }
            if let error = page.error {
                Text(error).font(.callout).foregroundStyle(.orange)
                Button("Retry BBC") { Task { await page.next(genres:genres,sort:sortOrder) } }
            } else if !page.loading && page.shows.isEmpty { Text("No BBC programmes are currently listed.").foregroundStyle(.secondary) }
        }.task(id:sortRaw) { page.reset(); await page.next(genres:genres,sort:sortOrder) }
    }
}

private struct BBCNetworkCategoryPage: View {
    let title: String
    let genres: [Genre]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var page = BBCMergedCategoryStore()
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CategorySortOrder.preferenceKey) private var sortRaw = CategorySortOrder.alphabetical.rawValue
    private var sortOrder: CategorySortOrder { CategorySortOrder(rawValue:sortRaw) ?? .alphabetical }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack { ProviderBadge(provider: .bbc, categoryHeading: true); Text(title).font(.largeTitle).bold(); Spacer(); CategorySortToggle() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 28)], spacing: 30) {
                    ForEach(Array(CategorySorting.sorted(page.shows,by:sortOrder,cached:catalogue.categoryDates).enumerated()), id: \.element.id) { position, show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show) }
                            .buttonStyle(ProgrammeCardStyle())
                            .task { if position >= page.shows.count - 6 { await page.next(genres:genres,sort:sortOrder) } }
                    }
                }
                if page.loading { ProgressView() }
                if let error = page.error {
                    Text(error).foregroundStyle(.orange)
                    Button("Retry BBC") { Task { await page.next(genres:genres,sort:sortOrder) } }
                }
            }.padding(60)
        }.task(id:sortRaw) { page.reset(); await page.next(genres:genres,sort:sortOrder) }
        .onExitCommand { dismiss() }
    }
}

private struct ITVCategoryPreview: View {
    let genre: ITVCategory
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @State private var shows: [CatalogueShow] = []
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0
    @AppStorage(CategorySortOrder.preferenceKey) private var sortRaw = CategorySortOrder.alphabetical.rawValue
    private var sortOrder: CategorySortOrder { CategorySortOrder(rawValue:sortRaw) ?? .alphabetical }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ProviderBadge(provider: .itv, categoryHeading: true).accessibilityIdentifier("category-network-itv")
                Spacer()
                NavigationLink("View all") { ITVCollectionView(title: genre.title, path: genre.path, catalogue: catalogue, library: library) }
                    .accessibilityLabel("View all ITV " + genre.title)
            }
            CategoryProgrammeRow(shows: Array(CategorySorting.sorted(shows,by:sortOrder,cached:catalogue.categoryDates).prefix(30)), catalogue: catalogue, library: library)
            if loading { ProgressView() }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
                Button("Retry ITV " + genre.title) { retry += 1 }
            } else if !loading && shows.isEmpty { Text("No ITV programmes are currently listed.").foregroundStyle(.secondary) }
        }.task(id: retry) {
            // Show saved programmes immediately, including when a refresh fails.
            if let cached = catalogue.itv.cached(genre.path) { shows = uniqueShows(cached) }
            loading = true; error = nil
            do {
                let page = try await catalogue.itv.page(genre.path, refresh: retry > 0)
                try Task.checkCancellation(); shows = uniqueShows(page)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
    private func uniqueShows(_ page: [String: Any]) -> [CatalogueShow] {
        var seen = Set<String>()
        return ITVCatalogueAPI.rails(page).flatMap(\.shows).filter { seen.insert($0.id).inserted }
    }
}

private struct CategoryProgrammeRow: View {
    let shows: [CatalogueShow]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @AppStorage(CategorySortOrder.preferenceKey) private var sortRaw = CategorySortOrder.alphabetical.rawValue
    private var sortOrder: CategorySortOrder { CategorySortOrder(rawValue:sortRaw) ?? .alphabetical }
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 28) {
                ForEach(CategorySorting.sorted(shows,by:sortOrder,cached:catalogue.categoryDates)) { show in
                    NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: {
                        ShowCard(show: show).frame(width: 330)
                    }.buttonStyle(ProgrammeCardStyle())
                }
            }.padding(.vertical, 24).padding(.horizontal, 12)
        }.scrollClipDisabled().padding(.horizontal, -12)
    }
}
