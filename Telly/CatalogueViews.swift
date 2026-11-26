// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVKit
import CryptoKit

private enum TellyTab: String, CaseIterable { case home = "Home", browse = "Browse", search = "Search", live = "Channels", saved = "Saved", settings = "Settings" }
private extension TellyTab {
    var symbol: String {
        switch self {
        case .home: return "house"
        case .browse: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .live: return "play.tv"
        case .saved: return "bookmark"
        case .settings: return "gearshape"
        }
    }
}
/// Height of the top bar; screens start below it.
let tellyHeaderHeight: CGFloat = 132
/// The artwork shown full-screen behind everything, top bar included. The screen that last appeared owns it,
/// and only its owner clears it, so going back to Home restores Home's artwork in either order of events.
@MainActor final class TellyBackdropModel: ObservableObject {
    @Published private(set) var url: URL?
    private var owner: UUID?
    func show(_ url: URL?, by id: UUID) { owner = id; self.url = url }
    func clear(by id: UUID) { if owner == id { owner = nil; url = nil } }
}
private struct TellyBackdropKey: EnvironmentKey { static let defaultValue: TellyBackdropModel? = nil }
extension EnvironmentValues {
    /// Present inside the main tabs; screens shown elsewhere simply have no full-screen artwork.
    var tellyBackdrop: TellyBackdropModel? {
        get { self[TellyBackdropKey.self] }
        set { self[TellyBackdropKey.self] = newValue }
    }
}
extension View {
    /// Shows this artwork behind the whole app while the view is on screen.
    func tellyBackdrop(_ url: URL?, model: TellyBackdropModel?, id: UUID) -> some View {
        onAppear { model?.show(url, by: id) }
            .onChange(of: url) { _, value in model?.show(value, by: id) }
            .onDisappear { model?.clear(by: id) }
    }
}
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
    @ObservedObject private var profiles = ProfileStore.shared
    @State private var showProfilePicker = ProfileStore.shared.pickerRequired
    /// Artwork the current screen wants full-screen behind the top bar (Home's featured programme, a programme page).
    @StateObject private var backdrop = TellyBackdropModel()
    /// Kids profiles see Home, Live and Saved only.
    private var visibleTabs: [TellyTab] { TellyTab.allCases.filter { !profiles.kidsMode || [.home, .live, .saved].contains($0) } }
    /// Current person, after the tabs (only with 2+ profiles); opens the Who's watching picker.
    @ViewBuilder private var profileTab: some View {
        if profiles.profiles.count > 1 {
            Button { profiles.pickerRequired = false; showProfilePicker = true } label: {
                HStack(spacing: 12) {
                    Text(String(profiles.currentProfile.name.prefix(1)).uppercased()).font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white).frame(width: 50, height: 50).background(Circle().fill(TellyColour.blue))
                    Text(profiles.currentProfile.name)
                }
            }.buttonStyle(ProfilePillStyle()).accessibilityLabel("Profile \(profiles.currentProfile.name). Select to switch profile.")
        }
    }
    /// Logo on the left, the tabs in a frosted-glass capsule in the middle, the profile on the right.
    private var header: some View {
        ZStack {
            HStack { TellyHeaderLogo(); Spacer(minLength: 0); profileTab }
            HStack(spacing: 6) {
                ForEach(visibleTabs,id:\.self) { value in
                    TellyTabButton(tab:value,selection:$tab,focus:$focusedTab) {
                        // Re-selecting a root tab also discards nested view-based destinations.
                        if value == tab && (value == .home || value == .browse) { navigationRevision &+= 1 }
                        tab = value
                    }
                }
            }.padding(8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1) }
        }.focusSection()
        .padding(.horizontal, 64).padding(.top, 34).frame(height: tellyHeaderHeight, alignment: .top)
    }
    var body: some View {
        ZStack(alignment: .top) {
            TellyBackdrop()
            if let url = backdrop.url { HomeHeroBackdrop(url: url) }
            VStack(spacing: 0) {
            header
            NavigationStack {
                switch tab {
                case .home:
                    if profiles.kidsMode { KidsHomeView(catalogue: catalogue, library: library) }
                    else { DiscoveryHome(catalogue: catalogue, library: library) }
                case .browse: BrowseView(catalogue: catalogue, library: library, index: index)
                case .search: CatalogueSearchView(index: index, catalogue: catalogue, library: library)
                case .live: LiveView(launch: liveLaunch)
                case .saved: SavedProgrammes(catalogue: catalogue, library: library)
                case .settings: SettingsView(catalogue: catalogue)
                }
            }.id("\(tab.rawValue)-\(navigationRevision)")
            }
        }.environmentObject(history).environment(\.tellyBackdrop, backdrop).tint(Color(white: 0.75)).defaultFocus($focusedTab, .home)
        .onChange(of: profiles.current) { _, _ in if !visibleTabs.contains(tab) { tab = .home } }
        .onChange(of: profiles.kidsMode) { _, _ in if !visibleTabs.contains(tab) { tab = .home } }
        .fullScreenCover(isPresented: $showProfilePicker) {
            WhoIsWatchingView(required: profiles.pickerRequired, dismiss: { showProfilePicker = false }) { id in
                profiles.select(id); profiles.pickerRequired = false; showProfilePicker = false
            }
        }
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
            HStack(spacing: 10) { Image(systemName: tab.symbol).font(.system(size: 24, weight: .semibold)); Text(tab.rawValue) }
                .font(.system(size: 27, weight: .semibold))
                .padding(.horizontal, 26).frame(height: 62)
                .foregroundStyle(focused ? Color.black : selection == tab ? Color.white : Color.white.opacity(0.72))
                .background { Capsule().fill(focused ? Color.white : selection == tab ? Color.white.opacity(0.16) : Color.clear) }
                .scaleEffect(focused ? 1.06 : 1)
                .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 14, y: 6)
                .animation(.easeOut(duration: 0.15), value: focused)
        }.buttonStyle(TellyTabStyle()).focused(focus, equals: tab).focusEffectDisabled()
            .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}
private struct TellyTabStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
}
/// The featured programme's artwork, full screen behind the top bar, fading into the background on the left and below.
private struct HomeHeroBackdrop: View {
    let url: URL?
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                .frame(width: geometry.size.width, height: geometry.size.height * 0.92).clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: TellyBackdrop.base.opacity(0.97), location: 0), .init(color: TellyBackdrop.base.opacity(0.85), location: 0.3), .init(color: TellyBackdrop.base.opacity(0.45), location: 0.55), .init(color: .clear, location: 0.8)], startPoint: .leading, endPoint: .trailing)
                }
                .overlay {
                    LinearGradient(colors: [TellyBackdrop.base.opacity(0.6), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
                }
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: TellyBackdrop.base, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .animation(.easeInOut(duration: 0.4), value: url)
        }.ignoresSafeArea()
    }
}
/// Large rounded button for the Home hero: frosted until focused, then white.
struct TellyHeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TellyHeroButtonSurface(content: configuration.label, pressed: configuration.isPressed) }
}
private struct TellyHeroButtonSurface<Content: View>: View {
    let content: Content
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        content.font(.system(size: 29, weight: .semibold))
            .padding(.horizontal, 38).frame(height: 80)
            .foregroundStyle(focused ? Color.black : Color.white)
            .background { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(focused ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)) }
            .scaleEffect(pressed ? 0.98 : focused ? 1.06 : 1)
            .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 18, y: 8)
            .animation(.easeOut(duration: 0.15), value: focused)
            .focusEffectDisabled()
    }
}
private struct BannerRotationKey: Hashable { let index: Int; let count: Int; let paused: Bool }
@MainActor final class HomeState: ObservableObject { @Published var banner = 0 }
struct DiscoveryHome: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @Environment(\.tellyBackdrop) private var backdrop
    @State private var backdropID = UUID()
    @StateObject private var state = HomeState()
    @StateObject private var featured = UnifiedFeaturedStore()
    @ObservedObject private var networks = NetworkSettings.shared
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
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Featured").font(.system(size: 23, weight: .bold)).tracking(5).textCase(.uppercase).foregroundStyle(TellyColour.blue)
                        Text(feature.headline).font(.system(size: 76, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7)
                            .shadow(color: .black.opacity(0.5), radius: 12)
                        HStack(spacing: 14) { ProviderBadge(provider: feature.show.provider, subdued: true) }
                        Text(feature.synopsis).font(.system(size: 29)).foregroundStyle(.white.opacity(0.86)).lineLimit(2)
                            .frame(maxWidth: 1000, alignment: .leading)
                        NavigationLink { CatalogueShowView(show: feature.show, catalogue: catalogue, library: library) } label: {
                            Label("Explore programme", systemImage: "play.fill")
                        }.buttonStyle(TellyHeroButtonStyle()).focused($bannerFocused).padding(.top, 14)
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
                        if bannerFeatures.count > 1 {
                            HStack(spacing: 10) {
                                ForEach(bannerFeatures.indices, id: \.self) { i in
                                    Capsule().fill(.white.opacity(i == index ? 1 : 0.35)).frame(width: i == index ? 36 : 12, height: 12)
                                }
                            }.padding(.top, 18).accessibilityHidden(true)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 520, alignment: .bottomLeading)
                    .transaction { $0.animation = nil }   // swap the text at once; only the artwork fades
                    .padding(.bottom, 40)
                }
                ContinueWatchingRow(catalogue: catalogue, library: library)
                MixedHomepageRows(catalogue:catalogue,library:library,focus:$focusedCard)
                if catalogue.home == nil && !catalogue.loading { Button("Retry homepage") { Task { await catalogue.refreshHome() } } }
            }.padding(.horizontal, 80).padding(.vertical, 26)
        }.scrollClipDisabled()
        .tellyBackdrop(bannerFeatures.isEmpty ? nil : bannerFeatures[min(state.banner, bannerFeatures.count - 1)].image, model: backdrop, id: backdropID)
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
        let values = values.filter { networks.isOn($0.show.provider) }
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
    @ObservedObject private var networks = NetworkSettings.shared
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
            .filter { networks.isOn($0.provider) }
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
            // tvOS-style lift: the focused card grows and casts a deep shadow; no outline.
            .background(focused ? Color.white.opacity(0.14) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .scaleEffect(pressed ? 0.98 : focused ? 1.08 : 1)
            .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 28, y: 18)
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
    @Environment(\.tellyBackdrop) private var backdrop
    @State private var backdropID = UUID()
    let show: CatalogueShow
    @EnvironmentObject private var history: WatchHistory
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
                ProviderBadge(provider: current.provider, subdued: true).padding(.top, 20)
                Text(current.title).font(.system(size: 84, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 12)
                if current.premium == true { Text(current.provider == .channel4 ? "Channel 4+ · subscription playback is not available in this build" : "ITV Premium · account playback is not supported in this build").font(.callout).foregroundStyle(.secondary) }
                Text(current.summary).font(.system(size: 29)).foregroundStyle(.white.opacity(0.86)).lineLimit(3)
                    .frame(maxWidth: 1050, alignment: .leading)
                if let error = state.error { Text(error).foregroundStyle(.orange); Button("Retry") { state.retry += 1 } }
                // Save waits for the page to load, so a second press on a programme card can't land on it.
                let canSave = state.show != nil || state.error != nil
                if canSave || orderedSeries.count > 1 {
                    HStack(spacing: 20) {
                        if canSave {
                            ProgrammeBookmarkButton(show: current, library: library)
                            if orderedSeries.count > 1 { Rectangle().fill(.white.opacity(0.2)).frame(width: 2, height: 44) }
                        }
                        if orderedSeries.count > 1 {
                            ScrollView(.horizontal) {
                                HStack(spacing: 20) {
                                    ForEach(orderedSeries) { series in
                                        Button(series.title) { selectSeries(series.id) }
                                            .tint((state.seriesID.isEmpty ? EpisodeSequence.latestSeries(orderedSeries)?.id : state.seriesID) == series.id ? Color(white: 0.75) : .gray)
                                    }
                                }.padding(.vertical, 30).padding(.leading, 24).padding(.trailing, 64)
                            }
                            // Save stays put while a long list of series scrolls, fading out beside it.
                            .mask {
                                HStack(spacing: 0) {
                                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 20)
                                    Color.black
                                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 60)
                                }
                            }
                            .padding(.leading, canSave ? -20 : -24).padding(.trailing, -60)
                        }
                        Spacer(minLength: 0)
                    }.focusSection()
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
                        Button { state.selection = episode.programme } label: { ProgrammeCard(programme: episode.programme, progress: history.progress(for: episode.id)) }.buttonStyle(ProgrammeCardStyle()).focused($focusedEpisode, equals: episode.id)
                            .accessibilityIdentifier("episode-" + episode.id)
                    }
                }
                if state.show != nil && selectedEpisodes.isEmpty { Text("No episodes are currently available.").foregroundStyle(.secondary) }
            }.padding(.horizontal, 80).padding(.vertical, 40)
        }.scrollClipDisabled()
        .tellyBackdrop(current.image, model: backdrop, id: backdropID)
        .task(id: state.retry) {
            state.error = nil
            do {
                state.show = try await catalogue.open(show)
                if state.seriesID.isEmpty {
                    let available = preferUHDSeries ? orderedSeries.filter { $0.episodes.contains { $0.programme.uhdListed == true } } : orderedSeries
                    state.seriesID = EpisodeSequence.latestSeries(available.isEmpty ? orderedSeries : available)?.id ?? ""
                }
                selectSeries(state.seriesID)
            } catch { if !Task.isCancelled { state.error = error.localizedDescription } }
        }.defaultFocus($focusedEpisode, visibleEpisodes.first?.id)
        .task(id: visibleEpisodes.first?.id) {
            guard let first = visibleEpisodes.first?.id else { return }
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            focusedEpisode = first
        }.sheet(item: $state.selection) { DetailView(programme: $0, show: current, library: library) }
    }
}
struct SavedProgrammes: View {
    @EnvironmentObject private var history: WatchHistory
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @State private var selection: SavedEpisode?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let warning = library.migrationWarning { Text(warning).foregroundStyle(.orange).font(.callout) }
                if library.saved.isEmpty && library.savedEpisodes.isEmpty { Text("Nothing saved yet. Use Save on a programme's page to follow all of its series here, or Save episode to keep just one.").foregroundStyle(.secondary) }
                if !library.savedEpisodes.isEmpty {
                    Text("Episodes").font(.title2).bold()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330))], spacing: 30) {
                        ForEach(library.savedEpisodes) { episode in
                            Button { selection = episode } label: {
                                ProgrammeCard(programme: episode.programme, progress: history.progress(for: episode.id), showTitle: episode.show?.title ?? episode.programme.showTitle ?? episode.programme.title)
                            }.buttonStyle(ProgrammeCardStyle()).accessibilityIdentifier("saved-episode-" + episode.id)
                        }
                    }.focusSection()
                }
                if !library.saved.isEmpty {
                    Text("Programmes").font(.title2).bold()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330))], spacing: 30) {
                        ForEach(library.saved) { show in
                            NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show) }.buttonStyle(ProgrammeCardStyle())
                        }
                    }.focusSection()   // a short row is still reached from any tab or column above
                }
            }.padding(60)
        }.task { await library.migrate(); await library.refreshArtwork() }
        .sheet(item: $selection) { SavedEpisodeView(saved: $0, catalogue: catalogue, library: library) }
    }
}
/// A saved episode opens at once from what was stored; its programme then loads so the latest
/// episode details and the next episode are available, as they are from the programme's own page.
private struct SavedEpisodeView: View {
    let saved: SavedEpisode
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @State private var loaded: CatalogueShow?
    private var programme: Programme { loaded?.episodes.first { $0.id == saved.id }?.programme ?? saved.programme }
    var body: some View {
        DetailView(programme: programme, show: loaded ?? saved.show, library: library)
            .task { if let show = saved.show { loaded = try? await catalogue.open(show) } }
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
    @ObservedObject private var favourites = FavouriteChannels.shared
    @ObservedObject private var networks = NetworkSettings.shared
    @AppStorage("liveMode") private var liveMode = "Channels"
    @EnvironmentObject private var history: WatchHistory
    @AppStorage("offerLiveFromStart") private var offerFromStart = false
    @State private var askFromStart: LiveChannel?
    private func play(_ channel: LiveChannel, fromStart: Bool? = nil) {
        state.selected = channel
        if channel.provider == .channel5 && !channel5Account.signedIn { state.channel5Pairing = true }
        else if channel.provider == .itv && !account.signedIn { state.pairing = true }
        else if fromStart == nil, offerFromStart, let start = channel.current?.start, Date().timeIntervalSince(start) > 60 { askFromStart = channel }
        else { playback.startLive(channel, fromStart: fromStart ?? false) { state.playing = true } }
    }
    /// Channels of the networks that are on; kids profiles always get CBBC and CBeebies and nothing else.
    private var availableChannels: [LiveChannel] {
        state.channels.filter { ProfileStore.shared.kidsMode ? ["cbbc", "cbeebies"].contains($0.id) : networks.isOn($0.provider) }
    }
    private func shows(_ network: ContentProvider) -> Bool { networks.isOn(network) || ProfileStore.shared.kidsMode }
    /// The network button chosen, unless that network has since been turned off.
    private var activeFilter: ContentProvider? { providerFilter.flatMap { shows($0) ? $0 : nil } }
    private func channels(in section: LiveChannelSection) -> [LiveChannel] {
        LiveChannelOrder.sorted(availableChannels.filter {
            (activeFilter == nil || $0.provider == activeFilter) && LiveChannelOrder.section($0.id) == section
        },id: { $0.id },title: { $0.title })
    }
    var body: some View {
        liveBody
        .confirmationDialog(askFromStart.map { $0.current?.title ?? $0.title } ?? "",
                            isPresented: Binding(get: { askFromStart != nil }, set: { if !$0 { askFromStart = nil } }), titleVisibility: .visible) {
            if let channel = askFromStart {
                Button("Watch from the start" + (channel.current?.start.map { " (" + $0.formatted(date: .omitted, time: .shortened) + ")" } ?? "")) { play(channel, fromStart: true) }
                Button("Watch live") { play(channel, fromStart: false) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    /// Every live channel in Freeview listings order, then the regional extras, with the themed channels last. The
    /// network buttons then filter the guide. BBC One/Two follow the chosen region so the listings match what plays.
    private var guideChannels: [LiveChannel] {
        let all = LiveChannelOrder.sorted(availableChannels, id: { $0.id }, title: { $0.title })
            .map { $0.provider == .bbc ? RegionalChannels.resolve($0) : $0 }
        // Favourites first, in the profile's order.
        return favourites.ordered(all.filter { favourites.contains($0.id) }) { $0.id } + all.filter { !favourites.contains($0.id) }
    }
    private var liveBody: some View {
        Group {
            if liveMode == "Guide" {
                // The guide scrolls itself, keeping its programme panel in view.
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 30) {
                        TellySegments(title: "Channels view", options: ["Channels", "Guide"], selection: $liveMode).frame(width: 460)
                        NetworkFilter(selection: $providerFilter)
                    }
                    if let error = playback.error { Text(error).foregroundStyle(.orange) }
                    ChannelGuideView(channels: guideChannels, filter: activeFilter,
                                     additionalStreams: ProfileStore.shared.kidsMode || !networks.isOn(.bbc) || (activeFilter ?? .bbc) != .bbc ? [] : AdditionalLiveStream.all,
                                     playLive: { play($0) },
                                     playStream: { stream in playback.startAdditional(stream) { state.playing = true } },
                                     playEpisode: { programme in
                                         if ProfileStore.shared.kidsMode && !(programme.guidance ?? "").isEmpty {
                                             state.bbcError = "This programme isn't available on a kids profile."; return
                                         }
                                         playback.start(programme, history: history) { state.playing = true }
                                     })
                }.padding(.horizontal, 60).padding(.top, 24)
            } else {
                channelsGrid
            }
        }
        .task(id: "\(state.retry)-\(phase)-\(state.playing)-\(state.pairing)-\(state.channel5Pairing)") {
            guard phase == .active, !state.playing, !state.pairing, !state.channel5Pairing else { return }
            await account.reload(); await channel5Account.reload()
            while !Task.isCancelled {
                // Networks that are off aren't contacted.
                async let bbc: Void? = shows(.bbc) ? state.refreshBBC() : nil
                async let itv: Void? = shows(.itv) ? state.refreshITV() : nil
                async let channel4: Void? = shows(.channel4) ? state.refreshChannel4() : nil
                async let channel5: Void? = shows(.channel5) ? state.refreshChannel5() : nil
                _ = await (bbc, itv, channel4, channel5)
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            }
        }.task(id: launch?.id) {
            guard let launch else { return }
            if ProfileStore.shared.kidsMode && !["cbbc", "cbeebies"].contains(launch.channelID) { return }
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
        .fullScreenCover(isPresented: $state.playing, onDismiss: { if !playback.pictureInPictureActive { playback.stop() } }) {
            PlaybackScreen(model: playback, liveChannels: favourites.ids.isEmpty ? guideChannels : favourites.ordered(guideChannels.filter { favourites.contains($0.id) }) { $0.id }, switchChannel: { play($0, fromStart: false) }, restoreFromPictureInPicture: { completion in
                state.playing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion(state.playing) }
            })
        }
        .modifier(LoadingBackAction(active: playback.loading) { playback.stop() })
        .onDisappear { if !state.playing && !playback.pictureInPictureActive { playback.stop() } }
    }
    /// A live channel; long-press to add it to or remove it from Favourites.
    private func channelCard(_ channel: LiveChannel) -> some View {
        Button { play(channel) } label: {
            VStack(alignment: .leading, spacing: 12) {
                LiveChannelPreview(channel: channel, active: phase == .active && !state.playing && !playback.loading && !playback.pictureInPictureActive, audioOnFocus: true)
                    .overlay(alignment: .topTrailing) {
                        if favourites.contains(channel.id) {
                            Image(systemName: "star.fill").font(.system(size: 22)).foregroundStyle(.yellow).padding(10)
                                .accessibilityLabel("Favourite")
                        }
                    }
                    .overlay(alignment: .bottomLeading) { TellyLiveBadge().padding(12) }
                HStack { Text(channel.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1); Spacer(); ProviderBadge(provider: channel.provider, subdued: true) }
                Text(channel.current?.title ?? channel.title).font(.system(size: 26, weight: .bold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let fraction = channel.current.flatMap { current in
                        current.start.map { start in min(max(context.date.timeIntervalSince(start) / max(current.end.timeIntervalSince(start), 1), 0), 1) }
                    }
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        if let fraction { GeometryReader { Capsule().fill(TellyColour.blue).frame(width: $0.size.width * fraction) } }
                    }.frame(height: 6).opacity(fraction == nil ? 0 : 1)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(ProgrammeCardStyle()).disabled(playback.loading)
        .contextMenu {
            Button(favourites.contains(channel.id) ? "Remove from Favourites" : "Add to Favourites",
                   systemImage: favourites.contains(channel.id) ? "star.slash" : "star") { favourites.toggle(channel.id) }
        }
    }
    private var channelsGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 30) {
                    TellySegments(title: "Channels view", options: ["Channels", "Guide"], selection: $liveMode).frame(width: 460)
                    NetworkFilter(selection: $providerFilter)
                }
                let errors = [(ContentProvider.bbc, state.bbcError), (.itv, state.itvError), (.channel4, state.channel4Error), (.channel5, state.channel5Error)]
                    .compactMap { network, error in shows(network) ? error : nil }
                ForEach(errors, id: \.self) { Text($0).foregroundStyle(.orange) }
                if !errors.isEmpty { Button("Retry channels") { state.retry += 1 } }
                if let error = playback.error { Text(error).foregroundStyle(.orange) }
                let favouriteRow = favourites.ordered(LiveChannelSection.allCases.flatMap { channels(in: $0) }.filter { favourites.contains($0.id) }) { $0.id }
                if !favouriteRow.isEmpty {
                    Text("Favourites").font(.title2).bold()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 34), count: 4), spacing: 34) {
                        ForEach(favouriteRow) { channel in channelCard(channel) }
                    }
                }
                ForEach(LiveChannelSection.allCases,id:\.self) { section in
                    let channels = channels(in:section)
                    if !channels.isEmpty {
                        if section == .itvThemed || section == .channel5Themed {
                            ProviderBadge(provider:section == .itvThemed ? .itv : .channel5,categoryHeading:true)
                                .accessibilityLabel(section.title).padding(.top,20)
                        } else if section == .additional {
                            Text(section.title).font(.title2).bold().padding(.top,20)
                        }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 34), count: 4), spacing: 34) {
                    ForEach(channels) { channel in channelCard(channel) }
                }
                    }
                }
            }.padding(.horizontal, 80).padding(.vertical, 40)
        }.scrollClipDisabled()
    }
}
/// Red LIVE marker: the only place Telly uses red outside its logo.
struct TellyLiveBadge: View {
    var body: some View {
        HStack(spacing: 7) { Circle().fill(.white).frame(width: 9, height: 9); Text("LIVE").font(.system(size: 18, weight: .heavy)).tracking(1) }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(TellyColour.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Live")
    }
}
/// Muted, independently owned previews leave full-screen playback and its DRM session untouched.
@MainActor private final class LivePreviewPlayer: ObservableObject {
    let player = AVPlayer()
    private var task: Task<Void, Never>?
    private var channel4: Channel4FairPlaySession?
    private var channel5: Channel5FairPlaySession?
    private var itv: ITVFairPlaySession?
    private var itvHTTP: ITVProbeHTTP?
    private var generation = UUID()

    func start(_ selected: LiveChannel) {
        stop()
        let token = generation
        player.isMuted = true
        task = Task { [weak self] in
            let channel = selected.provider == .bbc ? RegionalChannels.resolve(selected) : selected
            do {
                let source: PlaybackSource
                switch channel.provider {
                case .channel5: source = try await Channel5PlaybackAPI.shared.source(id: String(channel.id.dropFirst(3)), live: true)
                case .channel4: source = try await Channel4PlaybackAPI.shared.source(id: String(channel.id.dropFirst(3)), live: true)
                case .itv: source = try await ITVLiveAPI().playbackSource(for: channel)
                default: source = try await DiscoveryAPI().liveSource(channel)
                }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                #if targetEnvironment(simulator)
                if source.fairPlayCertificate != nil { return }
                #endif
                let asset = AVURLAsset(url: source.url)
                let report: @Sendable (String, Bool) -> Void = { [weak self] _, failed in
                    if failed { Task { @MainActor [weak self] in if self?.generation == token { self?.stop() } } }
                }
                if let config = source.channel4FairPlay, let certificate = source.fairPlayCertificate {
                    let session = Channel4FairPlaySession(config: config, certificate: certificate, report: report)
                    self.channel4 = session; session.attach(to: asset)
                } else if let config = source.channel5FairPlay, let certificate = source.fairPlayCertificate {
                    let session = Channel5FairPlaySession(config: config, certificate: certificate, report: report)
                    self.channel5 = session; session.attach(to: asset)
                } else if let certificate = source.fairPlayCertificate {
                    let http = ITVProbeHTTP()
                    let session = ITVFairPlaySession(certificate: certificate, http: http, report: report)
                    self.itvHTTP = http; self.itv = session; session.attach(to: asset)
                }
                let item = AVPlayerItem(asset: asset)
                item.preferredPeakBitRate = 1_000_000
                item.preferredMaximumResolution = CGSize(width: 640, height: 360)
                self.player.replaceCurrentItem(with: item)
                self.player.play()
            } catch { /* Keep the programme artwork when a preview is unavailable. */ }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        channel4?.stop(); channel4 = nil; channel5?.stop(); channel5 = nil
        itv?.stop(); itv = nil; itvHTTP?.cancel(); itvHTTP = nil
    }
}
private struct LivePreviewVideo: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> LivePreviewVideoView { let view = LivePreviewVideoView(); view.layerPlayer.player = player; return view }
    func updateUIView(_ view: LivePreviewVideoView, context: Context) { view.layerPlayer.player = player }
    static func dismantleUIView(_ view: LivePreviewVideoView, coordinator: ()) { view.layerPlayer.player = nil }
}
private final class LivePreviewVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var readiness: NSKeyValueObservation?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; layerPlayer.videoGravity = .resizeAspectFill
        alpha = 0
        readiness = layerPlayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            DispatchQueue.main.async { self?.alpha = layer.isReadyForDisplay ? 1 : 0 }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
struct LiveChannelPreview: View {
    let channel: LiveChannel
    let active: Bool
    var audioOnFocus = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.isFocused) private var isFocused
    @StateObject private var preview = LivePreviewPlayer()
    private var shouldPlay: Bool { active && phase == .active }
    private var shouldPlayAudio: Bool { shouldPlay && audioOnFocus && isFocused }
    private func startPreview() {
        preview.start(channel)
        updateAudio()
    }
    private func updateAudio() {
        if shouldPlayAudio {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        preview.player.isMuted = !shouldPlayAudio
    }
    var body: some View {
        LiveChannelArtwork(channel: channel)
            .overlay { LivePreviewVideo(player: preview.player).allowsHitTesting(false).clipShape(RoundedRectangle(cornerRadius: 10)) }
            .onAppear { if shouldPlay { startPreview() } }
            .onChange(of: shouldPlay) { _, value in if value { startPreview() } else { preview.stop() } }
            .onChange(of: shouldPlayAudio) { _, _ in updateAudio() }
            .onChange(of: channel.id) { _, _ in if shouldPlay { startPreview() } }
            .onDisappear { preview.stop() }
    }
}
struct SettingsView: View {
    @ObservedObject private var favourites = FavouriteChannels.shared
    @AppStorage("bbcOneRegion") private var bbcOne = "bbc_one_london"
    @AppStorage("bbcTwoRegion") private var bbcTwo = "bbc_two_england"
    @AppStorage("offerLiveFromStart") private var offerLiveFromStart = false
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject private var profileStore = ProfileStore.shared
    @AppStorage(TellySyncSettings.urlKey) private var syncURL = ""
    @AppStorage(TellySyncSettings.secretKey) private var syncSecret = ""
    @State private var syncStatus = ""
    @State private var editingProfile: String?        // nil = add a new profile
    @State private var showProfileEditor = false
    @State private var settingPIN = false
    private var startupChoices: [String] { ["last"] + profileStore.profiles.map(\.id) + ["ask"] }
    private func startupLabel(_ value: String) -> String {
        value == "last" ? "Last used" : value == "ask" ? "Ask" : profileStore.name(value)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Settings").font(.largeTitle).bold()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Profiles").font(.system(size: 32, weight: .bold))
                    Text("Each person has their own Continue Watching and Saved list.").font(.system(size: 22)).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 28) {
                            ForEach(profileStore.profiles) { profile in
                                Button { editingProfile = profile.id; showProfileEditor = true } label: {
                                    ProfileAvatar(name: profile.name, current: profile.id == profileStore.current, size: 130)
                                }.buttonStyle(ProgrammeCardStyle())
                            }
                            Button { editingProfile = nil; showProfileEditor = true } label: {
                                VStack(spacing: 12) {
                                    Image(systemName: "plus").font(.system(size: 50, weight: .semibold))
                                        .frame(width: 130, height: 130).background(Circle().fill(.white.opacity(0.12)))
                                    Text("Add").font(.system(size: 24, weight: .semibold))
                                }.padding(16)
                            }.buttonStyle(ProgrammeCardStyle())
                        }.padding(.vertical, 16).padding(.horizontal, 8)
                    }.scrollClipDisabled()
                    Text("Select a profile to rename it, switch to it, make it a kids profile or remove it.").font(.system(size: 22)).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        Button(profileStore.kidsPIN.isEmpty ? "Set kids PIN" : "Change kids PIN") { settingPIN = true }
                        if !profileStore.kidsPIN.isEmpty { Button("Remove kids PIN") { profileStore.kidsPIN = "" } }
                        Text(profileStore.kidsPIN.isEmpty ? "No PIN: anyone can switch away from a kids profile."
                                                          : "The PIN is needed to leave a kids profile. With household sync it applies on every Apple TV.")
                            .font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                    Text("On launch").font(.system(size: 24, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
                    ScrollView(.horizontal) {
                        TellySegments(title: "Profile on launch", options: startupChoices.map(startupLabel), selection: Binding(
                            get: { startupLabel(profileStore.startup) },
                            set: { label in if let value = startupChoices.first(where: { startupLabel($0) == label }) { profileStore.startup = value } }))
                            .frame(width: CGFloat(startupChoices.count) * 220)
                            .padding(.vertical, 12).padding(.horizontal, 4)
                    }.scrollClipDisabled()
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
                    .focusSection()   // Down from the menu bar lands in this section even though its first control is at the far left
                    .fullScreenCover(isPresented: $settingPIN) {
                        PINPadView(title: "Choose a 4-digit kids PIN", validate: nil) { pin in
                            if let pin { profileStore.kidsPIN = pin }
                            settingPIN = false
                        }
                    }
                    .fullScreenCover(isPresented: $showProfileEditor) {
                        ProfileEditView(profileID: editingProfile) { showProfileEditor = false }
                    }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Household sync").font(.system(size: 32, weight: .bold))
                    Text("Optional. Shares profiles, Continue Watching and Saved between your Apple TVs through a sync server you run, for example the Home Assistant AppDaemon app. Leave the URL empty to keep everything on this Apple TV.")
                        .font(.system(size: 22)).foregroundStyle(.secondary)
                    TextField("Server URL, e.g. http://homeassistant.local:5050/api/appdaemon/telly_history", text: $syncURL).frame(width: 1200)
                    SecureField("Key", text: $syncSecret).frame(width: 1200)
                    HStack(spacing: 24) {
                        Button("Test connection") { Task { syncStatus = await TellySyncClient.test() } }
                        Text(syncStatus).font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
                    .focusSection()
                    .onChange(of: syncURL) { _, _ in profileStore.scheduleSync(); NotificationCenter.default.post(name: ProfileStore.changed, object: nil) }
                    .onChange(of: syncSecret) { _, _ in profileStore.scheduleSync(); NotificationCenter.default.post(name: ProfileStore.changed, object: nil) }
                NetworkSwitches()
                Text("Playback automatically selects the best available quality, including 4K HDR when available. Live channel quality adapts to the stream each broadcaster supplies.").foregroundStyle(.secondary)
                Text("Programme listings load only when you select a category or letter. Series and episodes load when you open a programme. Saved programmes include all their series.")
                if let warning = catalogue.storageWarning { Text(warning).foregroundStyle(.orange) }
                Toggle("Offer watch from start for live TV", isOn: $offerLiveFromStart)
                Text("When on, opening a channel part-way through a programme asks whether to watch from the start or live. You can also jump back with Watch from start in the player. How far back you can go depends on the broadcaster.")
                    .font(.system(size: 22)).foregroundStyle(.secondary)
                NavigationLink {
                    FavouriteChannelsView(channels: FavouriteChannelsView.knownChannels)
                } label: {
                    RegionSettingLabel(title: "Favourite channels", value: favourites.ids.isEmpty ? "None" : "\(favourites.ids.count) chosen")
                }
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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 36), GridItem(.flexible())], spacing: 22) {
                    ForEach(choices) { choice in
                        Button {
                            selection = choice.id
                            dismiss()
                        } label: {
                            HStack {
                                Text(choice.title); Spacer()
                                Image(systemName: selection == choice.id ? "checkmark.circle.fill" : "circle").opacity(selection == choice.id ? 1 : 0.3)
                                    .symbolRenderingMode(.palette).foregroundStyle(selection == choice.id ? TellyColour.blue : Color.secondary)
                            }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 14)
                        }.buttonStyle(OutlinedActionButtonStyle())
                    }
                }.padding(.horizontal, 36).padding(.vertical, 20)
            }.scrollClipDisabled()
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

/// Settings › Favourite channels: pick favourites, then order them. Favourites lead the Live page, the guide
/// and the Top Shelf. Select a favourite to pick it up, move it with Up and Down, and select again to drop it.
struct FavouriteChannelsView: View {
    let channels: [LiveShelfChannel]
    /// The main channels of every broadcaster (streaming-only channels can be added from the Live page).
    static var knownChannels: [LiveShelfChannel] {
        LiveShelfChannel.defaults
            + (ITVLiveAPI.seed().filter { !$0.id.hasPrefix("itv:fast") } + Channel4CatalogueAPI.liveSeed + Channel5CatalogueAPI.liveSeed)
                .map { LiveShelfChannel(id: $0.id, title: $0.title) }
    }
    @ObservedObject private var favourites = FavouriteChannels.shared
    @State private var moving: String?
    @FocusState private var focused: String?
    private func title(_ id: String) -> String { channels.first { FavouriteChannels.canonical($0.id) == id }?.title ?? id }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Favourite channels").font(.largeTitle).bold()
                Text("Favourites come first on the Channels page, in the guide and on the Top Shelf. Each profile has its own, and they sync with household sync. You can also long-press a channel on the Channels page.")
                    .font(.system(size: 24)).foregroundStyle(.secondary)
                if !favourites.ids.isEmpty {
                    Text(moving == nil ? "Your order: select a channel to move it" : "Moving: use Up and Down, then select to drop")
                        .font(.system(size: 30, weight: .semibold)).padding(.top, 10)
                    ForEach(Array(favourites.ids.enumerated()), id: \.element) { index, id in
                        HStack(spacing: 18) {
                            Button {
                                moving = moving == id ? nil : id
                            } label: {
                                HStack(spacing: 18) {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                                    Text(title(id)); Spacer()
                                    Image(systemName: moving == id ? "arrow.up.arrow.down.circle.fill" : "line.3.horizontal")
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(OutlinedActionButtonStyle()).focused($focused, equals: id)
                                .disabled(moving != nil && moving != id)
                                .accessibilityHint(moving == id ? "Use Up and Down to move, then select" : "Select to move")
                            Button { favourites.remove(id) } label: { Image(systemName: "star.slash") }
                                .buttonStyle(OutlinedActionButtonStyle(square: true)).disabled(moving != nil)
                                .accessibilityLabel("Remove \(title(id)) from favourites")
                        }
                    }
                    .onMoveCommand { direction in
                        guard let id = moving, direction == .up || direction == .down else { return }
                        favourites.move(id, by: direction == .up ? -1 : 1)
                        focused = id
                    }
                }
                Text("All channels").font(.system(size: 30, weight: .semibold)).padding(.top, 10)
                ForEach(channels, id: \.id) { channel in
                    let on = favourites.contains(channel.id)
                    Button { favourites.toggle(channel.id) } label: {
                        HStack { Text(channel.title); Spacer(); Image(systemName: on ? "star.fill" : "star").foregroundStyle(on ? Color.yellow : Color.secondary) }
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(OutlinedActionButtonStyle()).disabled(moving != nil)
                        .accessibilityValue(on ? "Favourite" : "")
                }
            }.padding(.horizontal, 36).padding(.vertical, 20)
        }.scrollClipDisabled().padding(60)
        .onExitCommand(perform: moving == nil ? nil : { moving = nil })
    }
}
