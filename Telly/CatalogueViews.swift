// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CryptoKit

private enum TellyTab: String, CaseIterable { case home = "Home", browse = "Browse", search = "Search", live = "Live", saved = "Saved", settings = "Settings" }
struct HomeView: View {
    @StateObject private var catalogue = CatalogueStore()
    @StateObject private var index = CatalogueIndexStore()
    @StateObject private var library = Library()
    @StateObject private var history = WatchHistory()
    @State private var liveLaunch: LiveLaunch?
    @State private var tab = TellyTab.home
    @State private var navigationRevision = 0
    @FocusState private var focusedTab: TellyTab?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 30) {
                HStack(spacing:14) {
                    ForEach(TellyTab.allCases,id:\.self) { value in
                        TellyTabButton(tab:value,selection:$tab,focus:$focusedTab) {
                            // Re-selecting a root tab also discards nested view-based destinations.
                            if value == tab && (value == .home || value == .browse) { navigationRevision &+= 1 }
                            tab = value
                        }
                    }
                }
                Spacer(minLength: 0)
                TellyHeaderLogo(loading: catalogue.loading || catalogue.resumingEpisode || !catalogue.programmeLoadingIDs.isEmpty)
            }.padding(.horizontal, 64).padding(.vertical, 18)
            NavigationStack {
                switch tab {
                case .home: DiscoveryHome(catalogue: catalogue, library: library)
                case .browse: BrowseView(catalogue: catalogue, library: library, index: index)
                case .search: CatalogueSearchView(index: index, catalogue: catalogue, library: library)
                case .live: LiveView(launch: liveLaunch)
                case .saved: SavedProgrammes(catalogue: catalogue, library: library)
                case .settings: SettingsView(catalogue: catalogue)
                }
            }.id("\(tab.rawValue)-\(navigationRevision)")
        }.environmentObject(history).tint(Color(white: 0.75)).progressViewStyle(FTVProgressViewStyle()).defaultFocus($focusedTab, .home)
        .onOpenURL { url in
            guard let id = LiveChannelLink.channelID(from: url) else { return }
            NotificationCenter.default.post(name: .tellyLaunchLive, object: nil)
            liveLaunch = LiveLaunch(channelID: id); tab = .live
        }
        .task { await catalogue.itv.refreshHome() }
        .task { await catalogue.channel4.refreshHome() }
        .task { await catalogue.channel5.refresh() }
        .task { await catalogue.u.refresh() }
        .task {
            catalogue.programmeOpened = { show, sourceID in Task { await index.record(show, replacingID: sourceID) } }
            await index.prepare(); await catalogue.boot()
        }
        .task(id: "\(phase)-\(index.refreshRevision)") {
            if phase == .active { await index.maintain() }
        }
        #if DEBUG
        .onAppear { if let value = ProcessInfo.processInfo.environment["TELLY_UI_TAB"], let selected = TellyTab.allCases.first(where: { $0.rawValue.lowercased() == value }) { tab = selected } }
        #endif
        .onChange(of: phase) { _, value in if value == .active { Task { await catalogue.refreshHome() } } }
    }
}
private struct TellyTabButton: View {
    let tab: TellyTab
    @Binding var selection: TellyTab
    let focus: FocusState<TellyTab?>.Binding
    let action: () -> Void
    private var focused: Bool { focus.wrappedValue == tab }
    var body: some View {
        Button(action:action) {
            Text(tab.rawValue).font(.headline).padding(.horizontal, 24).padding(.vertical, 16)
                .foregroundStyle(focused || selection == tab ? .white : .white.opacity(0.7))
                .background(focused ? Color.white.opacity(0.2) : selection == tab ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(TellyTabStyle()).focused(focus, equals: tab).focusEffectDisabled()
            .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}
private struct TellyTabStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
}
private struct BannerRotationKey: Hashable { let index: Int; let count: Int; let paused: Bool }
@MainActor final class HomeState: ObservableObject { @Published var banner = 0 }
struct DiscoveryHome: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var state = HomeState()
    @StateObject private var featured = UnifiedFeaturedStore()
    @State private var bannerFeatures: [HomeFeature] = []
    @State private var pendingFeatures: [HomeFeature]?
    @Environment(\.scenePhase) private var phase
    @FocusState private var bannerFocused: Bool
    @FocusState private var focusedCard: String?
    @State private var visible = false
    private var rotationKey: BannerRotationKey {
        BannerRotationKey(index: state.banner, count: bannerFeatures.count, paused: !visible || bannerFocused || phase != .active)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if let error = catalogue.error { Text(error).foregroundStyle(.orange).font(.callout) }
                if !bannerFeatures.isEmpty {
                    let index = min(state.banner, bannerFeatures.count - 1)
                    let feature = bannerFeatures[index]
                    NavigationLink { CatalogueShowView(show: feature.show, catalogue: catalogue, library: library) } label: {
                        ZStack(alignment: .bottomLeading) {
                            Color.clear.overlay {
                                GeometryReader { geometry in
                                    AsyncImage(url: feature.image) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.gray.opacity(0.15)) }
                                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                }
                            }
                            LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Featured").font(.caption).tracking(4).foregroundStyle(.white.opacity(0.7))
                                Text(feature.headline).font(.system(size: 48, weight: .bold)).lineLimit(2)
                                Text(feature.synopsis).font(.title3).lineLimit(2).frame(maxWidth: 1000, alignment: .leading)
                            }.padding(38)
                        }.overlay(alignment: .bottomTrailing) { ProviderBadge(provider: feature.show.provider, subdued: true).padding(30) }.aspectRatio(2.35, contentMode: .fit).cornerRadius(18)
                    }.buttonStyle(ProgrammeCardStyle()).focused($bannerFocused)
                    .onMoveCommand { direction in
                        guard bannerFocused else { return }
                        switch direction {
                        case .left: advanceBanner(by: -1)
                        case .right: advanceBanner(by: 1)
                        default: break
                        }
                    }
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: advanceBanner(by: 1)
                        case .decrement: advanceBanner(by: -1)
                        @unknown default: break
                        }
                    }
                    // Match the 30-point bottom focus space beneath programme rows.
                    .padding(.bottom, 30)
                }
                ContinueWatchingRow(catalogue: catalogue, library: library)
                MixedHomepageRows(catalogue:catalogue,library:library,focus:$focusedCard)
                if catalogue.home == nil {
                    if catalogue.loading { ProgressView("Getting the latest programmes…") }
                    else { Button("Retry homepage") { Task { await catalogue.refreshHome() } } }
                }
            }.padding(.horizontal, 64).padding(.vertical, 26)
        }.scrollClipDisabled()
        .onAppear { visible = true; featured.seed(catalogue) }
        .task { await featured.refresh(catalogue) }
        .onReceive(catalogue.$home) { featured.update(.bbc,$0?.features ?? []) }
        .onReceive(catalogue.itv.$home) { featured.itv($0) }
        .onReceive(catalogue.channel4.$home) { _ in featured.seed(catalogue) }
        .onReceive(catalogue.channel5.$knownShows) { _ in featured.seed(catalogue) }
        .onReceive(catalogue.u.$knownShows) { _ in featured.seed(catalogue) }
        .onReceive(featured.$features) { values in
            if bannerFocused { pendingFeatures = values } else { applyFeatures(values) }
        }
        .onChange(of:bannerFocused) { _,focused in
            if !focused, let values = pendingFeatures { pendingFeatures = nil; applyFeatures(values) }
        }
        .task(id: phase) {
            #if DEBUG
            guard phase == .active else { return }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "cards" { focusedCard = "bbc:preview:preview-0" }
            if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "banner-focused" { bannerFocused = true }
            #endif
        }
        .onDisappear { visible = false }
        .onChange(of: rotationKey) { _, _ in recordBannerValidation() }
        .task(id: rotationKey) {
            guard !rotationKey.paused, rotationKey.count > 1 else { return }
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard !Task.isCancelled, visible, !bannerFocused, phase == .active else { return }
            withAnimation(.easeInOut(duration: 0.4)) { state.banner = (state.banner + 1) % rotationKey.count }
        }
    }
    private func applyFeatures(_ values: [HomeFeature]) {
        let current = bannerFeatures.indices.contains(state.banner) ? bannerFeatures[state.banner].id : nil
        bannerFeatures = values
        state.banner = current.flatMap { id in values.firstIndex { $0.id == id } } ?? 0
    }
    private func advanceBanner(by offset: Int) {
        let count = bannerFeatures.count
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            state.banner = (min(state.banner, count - 1) + offset + count) % count
        }
    }
    private func recordBannerValidation() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] != nil else { return }
        let values: [String: Any] = ["index": state.banner, "count": rotationKey.count, "focused": bannerFocused, "visible": visible, "active": phase == .active, "timestamp": Date().timeIntervalSince1970]
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UI-validation.json")
        if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: output, options: .atomic) }
        #endif
    }

}
private struct MixedHomepageRows: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    let focus: FocusState<String?>.Binding
    @ObservedObject private var itv: ITVCatalogueStore
    @ObservedObject private var channel4: Channel4CatalogueStore
    @ObservedObject private var channel5: Channel5CatalogueStore
    @ObservedObject private var u: UCatalogueStore
    @State private var rows: [HomepageRail] = []
    @State private var rebuildScheduled = false
    init(catalogue: CatalogueStore,library: Library,focus: FocusState<String?>.Binding) {
        self.catalogue = catalogue; self.library = library; self.focus = focus
        self.itv = catalogue.itv; self.channel4 = catalogue.channel4
        self.channel5 = catalogue.channel5; self.u = catalogue.u
    }
    private func rebuild() {
        rows = HomepageRows.make(bbc:catalogue.home?.rows ?? [],itv:itv.home,
            channel4:channel4.home,channel4All:channel4.knownShows,
            channel5:channel5.home,channel5All:channel5.knownShows,u:u.home,uAll:u.knownShows)
    }
    // Published properties notify before assignment. Read the completed catalogue
    // update on the next actor turn, never recalculate genre lists on focus moves.
    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor in
            await Task.yield()
            rebuild(); rebuildScheduled = false
        }
    }
    var body: some View {
        LazyVStack(alignment:.leading,spacing:34) {
            ForEach(rows) { row in
                VStack(alignment:.leading,spacing:18) {
                    HStack {
                        HomepageNetworkHeading(provider:row.provider,title:row.title)
                        Spacer()
                        if let path = row.more {
                            NavigationLink("View all") { ITVCollectionView(title:row.title,path:path,catalogue:catalogue,library:library) }
                        }
                    }
                    if row.provider == .itv, row.id == rows.first(where:{ $0.provider == .itv })?.id, let warning = itv.warning {
                        Text(warning).font(.callout).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing:28) {
                            ForEach(row.shows) { show in
                                NavigationLink { CatalogueShowView(show:show,catalogue:catalogue,library:library) } label: {
                                    HomeProgrammeCard(show:show,poster:row.posters).frame(width:row.posters ? 260 : 330)
                                }.buttonStyle(ProgrammeCardStyle()).focused(focus,equals:"\(row.id):\(show.id)")
                            }
                        }.padding(.vertical,30).padding(.horizontal,24)
                    }.scrollClipDisabled().padding(.horizontal,-24)
                }
            }
        }.onAppear { rebuild() }
        .onReceive(catalogue.$home) { _ in scheduleRebuild() }
        .onReceive(itv.$home) { _ in scheduleRebuild() }
        .onReceive(channel4.$home) { _ in scheduleRebuild() }
        .onReceive(channel5.$knownShows) { _ in scheduleRebuild() }
        .onReceive(u.$knownShows) { _ in scheduleRebuild() }
    }
}

struct BrowseView: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var index: CatalogueIndexStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Browse programmes").font(.largeTitle).bold()
                UnifiedCategoriesGrid(catalogue: catalogue, itv: catalogue.itv, library: library, index: index)
                Text("Choose a category. Programme listings load one page at a time; episodes load when you open a programme.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(60)
        }
    }
}
struct ProgrammePage: View {
    let title: String
    let category: String?
    let letter: String?
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var page = ContinuousCatalogueStore()
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CategorySortOrder.preferenceKey) private var sortRaw = CategorySortOrder.alphabetical.rawValue
    private var sortOrder: CategorySortOrder { category == nil ? .alphabetical : CategorySortOrder(rawValue:sortRaw) ?? .alphabetical }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 48, weight: .bold))
                    Spacer()
                    if category != nil { CategorySortToggle() }
                    if page.count > 0 {Text("\(page.count) programmes").font(.callout).foregroundStyle(.secondary)}
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 28)], spacing: 30) {
                    ForEach(Array(CategorySorting.sorted(page.shows,by:sortOrder,cached:catalogue.categoryDates).enumerated()), id: \.element.id) { position, show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show) }.buttonStyle(ProgrammeCardStyle())
                            .task {if position >= page.shows.count-6 {await page.next(category:category,letter:letter,sort:sortOrder)}}
                    }
                }
                if page.loading {ProgressView()}
                if let error = page.error {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    Button("Retry") {Task {await page.next(category:category,letter:letter,sort:sortOrder)}}
                }
            }.padding(60)
        }
        .task(id:sortOrder) { page.reset(); await page.next(category:category,letter:letter,sort:sortOrder) }
        .onExitCommand { dismiss() }
    }
}
/// Give the image a finite proposal before scaledToFill; intrinsic artwork sizes
/// must never determine a row's card width or its focus outline.
struct ProgrammeThumbnail: View {
    let url: URL?
    let uhd: Bool
    var hdr = false
    var provider: ContentProvider = .bbc
    var fallback: URL? = nil
    var body: some View {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ProgrammeArtwork(url: url, fallback: fallback).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { if uhd { UHDListedBadge(hdr: hdr).padding(10) } }
    }
}
struct ProgrammeArtwork: View {
    let url: URL?
    var fit = false
    var fallback: URL? = nil
    @State private var usingFallback = false
    @State private var bitmap: UIImage?
    var body: some View {
        Group {
            if let bitmap { Image(uiImage: bitmap).resizable().aspectRatio(contentMode: fit || usingFallback ? .fit : .fill).padding(usingFallback ? 42 : 0) }
            else { Rectangle().fill(.gray.opacity(0.15)).overlay(Image(systemName: "play.tv").font(.largeTitle)) }
        }.task(id: [url, fallback]) {
            bitmap = nil; usingFallback = false
            for candidate in [url, fallback].compactMap({ $0 }) {
                do {
                    let image = try await ProgrammeArtworkLoader.shared.image(candidate)
                    try Task.checkCancellation()
                    usingFallback = candidate != url; bitmap = image; return
                } catch { if Task.isCancelled { return } }
            }
        }
    }
}
struct ProgrammeCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ProgrammeCardSurface(content: configuration.label, pressed: configuration.isPressed) }
}
private struct ProgrammeCardSurface<Content: View>: View {
    let content: Content
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        content
            .background(focused ? Color.white.opacity(0.16) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? .white : .clear, lineWidth: 3) }
            .scaleEffect(pressed ? 0.99 : focused ? 1.045 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 16, y: 8)
            .animation(.easeOut(duration: 0.15), value: focused)
            .focusEffectDisabled().zIndex(focused ? 1 : 0)
    }
}
struct ShowCard: View {
    let show: CatalogueShow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgrammeThumbnail(url: show.image, uhd: show.uhdListed == true, hdr: show.hdrListed == true, provider: show.provider)
            Text(show.title).font(.headline).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .topLeading)
            HStack {
                Text(show.premium == true ? (show.provider == .channel4 ? "Channel 4+" : "ITV Premium") : show.singleEpisode ? "" : show.expectedEpisodes == 1 ? "1 episode" : show.expectedEpisodes > 1 ? "\(show.expectedEpisodes) episodes" : "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 12)
                ProviderBadge(provider: show.provider, subdued: true)
            }.frame(minHeight: 40)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
@MainActor final class ShowState: ObservableObject {
    @Published var show: CatalogueShow?
    @Published var seriesID = ""
    @Published var displayedEpisodes: [CatalogueEpisode] = []
    @Published var selection: Programme?
    @Published var error: String?
    @Published var retry = 0
    @Published var episodePage = 1
}
/// Every shared programme card uses this destination, including Saved and Search.
struct CatalogueShowView: View {
    let show: CatalogueShow
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var preferUHDSeries = false
    var body: some View {
        if let path = ITVCatalogueAPI.collectionPath(show) {
            ITVCollectionView(title: show.title, path: path, catalogue: catalogue, library: library)
        } else {
            ProgrammeDetailsView(show: show, catalogue: catalogue, library: library, preferUHDSeries: preferUHDSeries)
        }
    }
}
private struct ProgrammeDetailsView: View {
    let show: CatalogueShow
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var preferUHDSeries = false
    @StateObject private var state = ShowState()
    @FocusState private var focusedEpisode: String?
    var current: CatalogueShow { state.show ?? show }
    var orderedSeries: [CatalogueSeries] { EpisodeSequence.orderedSeries(current.series) }
    var selectedEpisodes: [CatalogueEpisode] { state.displayedEpisodes }
    private func selectSeries(_ id: String) {
        state.seriesID = id; state.episodePage = 1
        state.displayedEpisodes = EpisodeSequence.displayed(orderedSeries.first { $0.id == id }?.episodes ?? [],in:current)
    }
    var visibleEpisodes: [CatalogueEpisode] { Array(selectedEpisodes.dropFirst((state.episodePage - 1) * 30).prefix(30)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text(current.title).font(.largeTitle).bold(); Spacer()
                    ProgrammeBookmarkButton(show: current, library: library)
                }
                if current.premium == true { Text(current.provider == .channel4 ? "Channel 4+ · subscription playback is not available in this build" : "ITV Premium · account playback is not supported in this build").font(.callout).foregroundStyle(.secondary) }
                Text(current.summary).font(.title3).foregroundStyle(.secondary)
                if let error = state.error { Text(error).foregroundStyle(.orange); Button("Retry") { state.retry += 1 } }
                if orderedSeries.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 20) {
                            ForEach(orderedSeries) { series in
                                Button(series.title) { selectSeries(series.id) }
                                    .tint((state.seriesID.isEmpty ? EpisodeSequence.latestSeries(orderedSeries)?.id : state.seriesID) == series.id ? Color(white: 0.75) : .gray)
                            }
                        }.padding(.vertical, 30).padding(.horizontal, 24)
                    }.scrollClipDisabled().padding(.horizontal, -24)
                }
                if selectedEpisodes.count > 30 {
                    HStack(spacing: 24) {
                        Button("Previous episodes") { state.episodePage -= 1 }.disabled(state.episodePage <= 1)
                        Text("Episodes \((state.episodePage - 1) * 30 + 1)–\(min(state.episodePage * 30, selectedEpisodes.count))")
                        Button("More episodes") { state.episodePage += 1 }.disabled(state.episodePage * 30 >= selectedEpisodes.count)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 30)], spacing: 30) {
                    ForEach(visibleEpisodes) { episode in
                        Button { state.selection = episode.programme } label: { ProgrammeCard(programme: episode.programme) }.buttonStyle(ProgrammeCardStyle()).focused($focusedEpisode, equals: episode.id)
                            .accessibilityIdentifier("episode-" + episode.id)
                    }
                }
                if state.show != nil && selectedEpisodes.isEmpty { Text("No episodes are currently available.").foregroundStyle(.secondary) }
            }.padding(60)
        }.task(id: state.retry) {
            state.error = nil
            do {
                state.show = try await catalogue.open(show)
                if state.seriesID.isEmpty {
                    let available = preferUHDSeries ? orderedSeries.filter { $0.episodes.contains { $0.programme.uhdListed == true } } : orderedSeries
                    state.seriesID = EpisodeSequence.latestSeries(available.isEmpty ? orderedSeries : available)?.id ?? ""
                }
                selectSeries(state.seriesID)
            } catch { if !Task.isCancelled { state.error = error.localizedDescription } }
        }.modifier(ProgrammeLoadingFeedback(active:state.show == nil && state.error == nil,catalogue:catalogue))
        .defaultFocus($focusedEpisode, visibleEpisodes.first?.id)
        .task(id: visibleEpisodes.first?.id) {
            guard let first = visibleEpisodes.first?.id else { return }
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            focusedEpisode = first
        }.sheet(item: $state.selection) { DetailView(programme: $0, show: current, library: library) }
    }
}
struct SavedProgrammes: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let warning = library.migrationWarning { Text(warning).foregroundStyle(.orange).font(.callout) }
                if library.saved.isEmpty { Text("Save a programme to follow all of its series and episodes here.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330))], spacing: 30) {
                    ForEach(library.saved) { show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show) }.buttonStyle(ProgrammeCardStyle())
                    }
                }
            }.padding(60)
        }.task { await library.migrate(); await library.refreshArtwork() }
    }
}
@MainActor final class LiveState: ObservableObject {
    @Published var bbc: [LiveChannel] = []
    @Published var itv: [LiveChannel] = ITVLiveAPI.seed()
    @Published var channel4: [LiveChannel] = Channel4CatalogueAPI.liveSeed
    @Published var channel4Error: String?
    @Published var channel5: [LiveChannel] = Channel5CatalogueAPI.liveSeed
    @Published var channel5Error: String?
    @Published var channel5Pairing = false
    @Published var bbcError: String?
    @Published var itvError: String?
    @Published var retry = 0
    @Published var playing = false
    @Published var pairing = false
    var selected: LiveChannel?
    var channels: [LiveChannel] { bbc + itv + channel4 + channel5 }
    func refreshBBC() async {
        do {
            let api = DiscoveryAPI()
            let list = bbc.isEmpty ? try await api.channels() : bbc
            let fresh = await api.nowPlaying(list); try Task.checkCancellation()
            bbc = fresh; bbcError = nil
        } catch {
            if !Task.isCancelled { bbcError = "BBC live listings could not be refreshed. Please retry." }
        }
    }
    func refreshChannel5() async {
        do {
            let list = try await Channel5CatalogueAPI().live()
            try Task.checkCancellation(); channel5 = list; channel5Error = nil
        } catch { if !Task.isCancelled { channel5Error = "Channel 5 live listings could not refresh. Showing available channels." } }
    }
    func refreshChannel4() async {
        do {
            let channels = try await Channel4CatalogueAPI().live()
            try Task.checkCancellation(); channel4 = channels; channel4Error = nil
        } catch { if !Task.isCancelled { channel4Error = "Channel 4 live listings could not refresh. Showing the channel list." } }
    }
    func refreshITV() async {
        do {
            let fresh = try await ITVLiveAPI().channels(); try Task.checkCancellation()
            itv = fresh; itvError = nil
        } catch {
            if !Task.isCancelled {
                itv = itv.map { value in
                    var value = value
                    if let current = value.current, current.end <= Date() { value.current = nil }
                    return value
                }
                itvError = "ITV live listings could not be refreshed. Showing the available channel list."
            }
        }
    }
}
struct LiveView: View {
    var launch: LiveLaunch? = nil
    @Environment(\.scenePhase) private var phase
    @StateObject private var state = LiveState()
    @StateObject private var playback = PlaybackModel()
    @ObservedObject private var account = ITVAccountModel.shared
    @ObservedObject private var channel5Account = Channel5AccountModel.shared
    @State private var providerFilter: ContentProvider?
    private func play(_ channel: LiveChannel) {
        state.selected = channel
        if channel.provider == .channel5 && !channel5Account.signedIn { state.channel5Pairing = true }
        else if channel.provider == .itv && !account.signedIn { state.pairing = true }
        else { playback.startLive(channel) { state.playing = true } }
    }
    private func channels(in section: LiveChannelSection) -> [LiveChannel] {
        LiveChannelOrder.sorted(state.channels.filter {
            (providerFilter == nil || $0.provider == providerFilter) && LiveChannelOrder.section($0.id) == section
        },id: { $0.id },title: { $0.title })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                NetworkFilter(selection: $providerFilter)
                if let error = state.bbcError { Text(error).foregroundStyle(.orange) }
                if let error = state.itvError { Text(error).foregroundStyle(.orange) }
                if let error = state.channel4Error { Text(error).foregroundStyle(.orange) }
                if let error = state.channel5Error { Text(error).foregroundStyle(.orange) }
                if state.bbcError != nil || state.itvError != nil || state.channel4Error != nil || state.channel5Error != nil { Button("Retry channels") { state.retry += 1 } }
                if let error = playback.error { Text(error).foregroundStyle(.orange) }
                ForEach(LiveChannelSection.allCases,id:\.self) { section in
                    let channels = channels(in:section)
                    if !channels.isEmpty {
                        if section == .itvThemed || section == .channel5Themed {
                            ProviderBadge(provider:section == .itvThemed ? .itv : .channel5,categoryHeading:true)
                                .accessibilityLabel(section.title).padding(.top,20)
                        } else if section == .additional {
                            Text(section.title).font(.title2).bold().padding(.top,20)
                        }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 370))], spacing: 30) {
                    ForEach(channels) { channel in
                        Button { play(channel) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                LiveChannelArtwork(channel: channel)
                                Text(channel.current?.title ?? channel.title).font(.headline).lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .topLeading)
                                HStack { Text(channel.title).font(.callout).foregroundStyle(.secondary); Spacer(); ProviderBadge(provider: channel.provider, subdued: true) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(ProgrammeCardStyle()).disabled(playback.loading)
                    }
                }
                    }
                }
            }.padding(60)
        }.task(id: "\(state.retry)-\(phase)-\(state.playing)-\(state.pairing)-\(state.channel5Pairing)") {
            guard phase == .active, !state.playing, !state.pairing, !state.channel5Pairing else { return }
            await account.reload(); await channel5Account.reload()
            while !Task.isCancelled {
                async let bbc: Void = state.refreshBBC()
                async let itv: Void = state.refreshITV()
                async let channel4: Void = state.refreshChannel4()
                async let channel5: Void = state.refreshChannel5()
                _ = await (bbc, itv, channel4, channel5)
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            }
        }.task(id: launch?.id) {
            guard let launch else { return }
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                var channel = state.channels.first { $0.id == launch.channelID }
                if channel == nil, launch.channelID.hasPrefix("itv:") {
                    channel = ITVLiveAPI.seed().first { $0.id == launch.channelID }
                    if channel == nil { channel = try await ITVLiveAPI().channels().first { $0.id == launch.channelID } }
                }
                if channel == nil, launch.channelID.hasPrefix("c4:") { channel = Channel4CatalogueAPI.liveSeed.first { $0.id == launch.channelID } }
                if channel == nil, launch.channelID.hasPrefix("c5:") {
                    channel = Channel5CatalogueAPI.liveSeed.first { $0.id == launch.channelID }
                    if channel == nil { channel = try await Channel5CatalogueAPI().live().first { $0.id == launch.channelID } }
                }
                if channel == nil, let known = LiveShelfChannel.defaults.first(where: { $0.id == launch.channelID }) { channel = LiveChannel(id: known.id, title: known.title) }
                if channel == nil { channel = try await DiscoveryAPI().channels().first { $0.id == launch.channelID } }
                try Task.checkCancellation()
                guard let channel else { state.bbcError = "This channel is not currently available."; return }
                await account.reload(); await channel5Account.reload(); play(channel)
            } catch { if !Task.isCancelled { state.bbcError = error.localizedDescription } }
        }.onChange(of: playback.itvSignInRequired) { _, required in
            if required { Task { await account.reload(); state.pairing = true } }
        }.sheet(isPresented: $state.pairing, onDismiss: {
            if account.signedIn, let channel = state.selected, channel.provider == .itv {
                playback.startLive(channel) { state.playing = true }
            }
        }) { ITVAccountView() }
        .onChange(of: playback.channel5SignInRequired) { _, required in
            if required { Task { await channel5Account.reload(); state.channel5Pairing = true } }
        }.sheet(isPresented: $state.channel5Pairing, onDismiss: {
            if channel5Account.signedIn, let channel = state.selected, channel.provider == .channel5 { playback.startLive(channel) { state.playing = true } }
        }) { Channel5AccountView() }
        .fullScreenCover(isPresented: $state.playing, onDismiss: { playback.stop() }) { PlaybackScreen(model: playback) }
        .modifier(LoadingBackAction(active: playback.loading) { playback.stop() })
        .onDisappear { if !state.playing { playback.stop() } }
    }
}
struct SettingsView: View {
    @AppStorage("bbcOneRegion") private var bbcOne = "bbc_one_london"
    @AppStorage("bbcTwoRegion") private var bbcTwo = "bbc_two_england"
    @ObservedObject var catalogue: CatalogueStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Settings").font(.largeTitle).bold()
                Text("Playback automatically selects the best available quality, including 4K HDR when available. Live channel quality adapts to the stream each broadcaster supplies.").foregroundStyle(.secondary)
                Text("Programme listings load only when you select a category or letter. Series and episodes load when you open a programme. Saved programmes include all their series.")
                if let warning = catalogue.storageWarning { Text(warning).foregroundStyle(.orange) }
                NavigationLink {
                    RegionSelectionView(title: "BBC One region", choices: RegionalChannels.bbcOne, selection: $bbcOne)
                } label: { RegionSettingLabel(title: "BBC One region", value: RegionalChannels.bbcOne.first { $0.id == bbcOne }?.title ?? "London") }
                NavigationLink {
                    RegionSelectionView(title: "BBC Two version", choices: RegionalChannels.bbcTwo, selection: $bbcTwo)
                } label: { RegionSettingLabel(title: "BBC Two version", value: RegionalChannels.bbcTwo.first { $0.id == bbcTwo }?.title ?? "England / Scotland") }
                NavigationLink("ITV account") { ITVAccountView() }
                NavigationLink("Channel 5 account") { Channel5AccountView() }
                NavigationLink("U account") { UAccountView() }
                UHDSetupView()
                Text("Telly \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") • Independent TV player").font(.caption).foregroundStyle(.secondary)
            }.padding(60)
        }
    }
}

private struct RegionSettingLabel: View {
    let title: String
    let value: String
    var body: some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary); Image(systemName: "chevron.right") }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}
private struct RegionSelectionView: View {
    let title: String
    let choices: [RegionalChannelChoice]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(.largeTitle).bold()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    ForEach(choices) { choice in
                        Button {
                            selection = choice.id
                            dismiss()
                        } label: {
                            HStack {
                                Text(choice.title); Spacer()
                                Image(systemName: selection == choice.id ? "checkmark.circle.fill" : "circle").opacity(selection == choice.id ? 1 : 0.3)
                            }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 14)
                        }.buttonStyle(OutlinedActionButtonStyle())
                    }
                }.padding(12)
            }
        }.padding(60)
        .onExitCommand { dismiss() }
    }
}


private struct HomeProgrammeCard: View {
    let show: CatalogueShow
    let poster: Bool
    var body: some View {
        if poster {
            AsyncImage(url: show.portraitImage) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { ZStack { Color(white: 0.12); Text(show.title).font(.title3).multilineTextAlignment(.center).padding(24) } }
            }.frame(width: 260, height: 390).clipped().cornerRadius(12)
                .overlay(alignment: .bottomTrailing) { ProviderBadge(provider: show.provider, subdued: true).padding(14) }
                .accessibilityLabel(show.title)
        } else { ShowCard(show: show) }
    }
}
