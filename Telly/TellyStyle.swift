// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Straight colour bars, drawn as vectors so each glow keeps its own colour.
struct FTVLoadingBars: View {
    var width: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let colours = [Color(red:29/255,green:148/255,blue:250/255),
                           Color(red:248/255,green:55/255,blue:44/255),
                           Color(red:23/255,green:185/255,blue:90/255)]
    var body: some View {
        TimelineView(.animation(minimumInterval:1/30,paused:reduceMotion || scenePhase != .active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.8
            HStack(spacing:0) {
                ForEach(0..<3) { index in
                    let pulse = reduceMotion ? 0.5 : pow((sin(phase - Double(index) * 0.8) + 1)/2, 1.5)
                    let colour = colours[index]
                    Rectangle().fill(colour.opacity(0.12 + 0.88 * pulse))
                        .overlay { Rectangle().fill(.white.opacity(reduceMotion ? 0 : pulse * 0.65)) }
                        .shadow(color:colour.opacity(pulse),radius:width * 0.022)
                        .shadow(color:colour.opacity(pulse * 0.95),radius:width * 0.065)
                        .frame(width:width / 3,height:width * 20/438)
                }
            }
        }.frame(width:width,height:max(24,width * 0.15))
            .accessibilityElement(children:.ignore).accessibilityLabel("Loading")
            .allowsHitTesting(false)
    }
}
/// The loading glow sits directly over the three colour segments in the wordmark.
struct TellyHeaderLogo: View {
    let loading: Bool
    var body: some View {
        Image("TellyBoxLogo").renderingMode(.original).resizable().scaledToFit()
            .frame(width:144,height:68)
            .overlay {
                if loading {
                    Rectangle().fill(Color(red:16/255,green:22/255,blue:30/255))
                        .frame(width:79.5,height:4.2).position(x:72,y:64.5)
                    FTVLoadingBars(width:79.3)
                        .position(x:72,y:64.5)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(loading ? "Telly, loading" : "Telly")
            .accessibilityIdentifier("header-telly-logo")
    }
}

struct FTVProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if let value = configuration.fractionCompleted {
            ProgressView(value:value) { configuration.label }.progressViewStyle(.linear)
        } else {
            HStack(spacing:16) {
                FTVLoadingBars()
                configuration.label
            }
        }
    }
}

#if DEBUG
/// Isolated native preview for checking transparency and the loading animation.
struct FTVBrandValidationView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FTVLoadingBars(width:220)
        }.overlay(alignment:.topTrailing) {
            Image("TellyBoxLogo").resizable().scaledToFit().frame(width:128,height:46)
                .padding(.trailing,64).padding(.top,18)
        }
    }
}
#endif

/// Home sections share the same network mark sizing as Browse category pages.
struct HomepageNetworkHeading: View {
    let provider: ContentProvider
    let title: String
    var body: some View {
        HStack(spacing:22) {
            ProviderBadge(provider:provider,categoryHeading:true)
            Text(title).font(.title2).bold()
        }.accessibilityAddTraits(.isHeader)
    }
}

struct NetworkFilter: View {
    @Binding var selection: ContentProvider?
    var body: some View {
        HStack(spacing: 22) {
            Button { selection = nil } label: { Text("All").frame(width: 60, height: 30) }
                .buttonStyle(NeutralPillStyle(selected: selection == nil)).accessibilityIdentifier("live-filter-all")
            ForEach([ContentProvider.bbc, .itv, .channel4, .channel5], id: \.self) { provider in
                Button { selection = provider } label: {
                    Image(provider.logo).renderingMode(.template).resizable().scaledToFit().frame(width: 60, height: 30)
                }.buttonStyle(NeutralPillStyle(selected: selection == provider))
                    .accessibilityLabel(provider.title).accessibilityIdentifier("live-filter-" + provider.rawValue)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("live-network-filter")
    }
}
struct NeutralPillStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View { NeutralPillSurface(content: configuration.label, selected: selected, pressed: configuration.isPressed) }
}
private struct NeutralPillSurface<Content: View>: View {
    let content: Content
    let selected: Bool
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        content.font(.system(size: 25, weight: .semibold)).foregroundStyle(.white.opacity(selected || focused ? 1 : 0.72))
            .padding(.horizontal, 28).padding(.vertical, 15)
            .background(.white.opacity(focused ? 0.22 : selected ? 0.14 : 0.065), in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(focused ? 0.8 : 0), lineWidth: 2) }
            .scaleEffect(pressed ? 0.98 : focused ? 1.035 : 1).focusEffectDisabled()
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct CategoryTile: View {
    let title: String
    var icon: String = "play.rectangle"
    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: icon).font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.72)).frame(width: 52)
            Text(title).font(.system(size: 34, weight: .semibold)).lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
        }.padding(.horizontal, 26).frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
    }
    static func icon(_ id: String) -> String {
        let key = id.lowercased()
        let icons: [(String, String)] = [
            ("crime", "touchid"), ("audio", "speaker.wave.2"), ("travel", "airplane"),
            ("drama", "theatermasks"), ("soap", "theatermasks"), ("film", "film"),
            ("comedy", "face.smiling"), ("documentar", "doc.text.image"), ("sport", "sportscourt"),
            ("news", "newspaper"), ("entertainment", "sparkles.tv"), ("reality", "sparkles.tv"),
            ("music", "music.note"), ("food", "fork.knife"), ("lifestyle", "house"),
            ("history", "clock.arrow.circlepath"), ("science", "leaf"), ("nature", "leaf"),
            ("factual", "doc.text.image"), ("arts", "paintpalette"), ("archive", "archivebox"),
            ("kids", "figure.child"), ("children", "figure.child"), ("signed", "hands.sparkles")
        ]
        return icons.first { key.contains($0.0) }?.1 ?? "play.rectangle"
    }
}
#if DEBUG
/// Uses the production card and bundled public catalogue metadata for visual review.
struct ProgrammeCardReview: View {
    private var shows: [CatalogueShow] {
        var result = [CatalogueShow]()
        if let url = Bundle.main.url(forResource: "CatalogueSeed", withExtension: "plist"),
           let data = try? Data(contentsOf: url), let index = try? PropertyListDecoder().decode(CatalogueIndexSnapshot.self, from: data),
           let show = index.catalogue.first(where: { $0.title == "Blue Lights" }) { result.append(show) }
        if let url = Bundle.main.url(forResource: "ITVCatalogueSeed", withExtension: "json"), let data = try? Data(contentsOf: url),
           let pages = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
           let metadata = pages["/watch/the-way-home/10a8290"]?["programme"] as? [String: Any],
           let show = ITVCatalogueAPI.show(metadata) { result.append(show) }
        return result
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 40) {
                Text("Programme cards").font(.system(size: 40, weight: .bold))
                HStack(alignment: .top, spacing: 44) {
                    ForEach(shows) { show in
                        Button {} label: { ShowCard(show: show).frame(width: 480) }.buttonStyle(ProgrammeCardStyle())
                    }
                }
            }
        }
    }
}
#endif

/// Keep Back cancellation during live-source discovery without intercepting
/// normal navigation once the request has finished.
struct LoadingBackAction: ViewModifier {
    let active: Bool
    let cancel: () -> Void
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    FTVLoadingBars(width:220)
                }.allowsHitTesting(false)
            }
        }.onExitCommand(perform: active ? cancel : nil)
    }
}

/// Multiple programme loads can overlap without one clearing another's feedback.
struct ProgrammeLoadingFeedback: ViewModifier {
    let active: Bool
    @ObservedObject var catalogue: CatalogueStore
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content.onChange(of:active,initial:true) { _,value in
            if value { catalogue.beginProgrammeLoading(token) } else { catalogue.endProgrammeLoading(token) }
        }.onAppear { if active { catalogue.beginProgrammeLoading(token) } }
         .onDisappear { catalogue.endProgrammeLoading(token) }
    }
}

struct CategorySortToggle: View {
    @AppStorage(CategorySortOrder.preferenceKey) private var rawOrder = CategorySortOrder.alphabetical.rawValue
    var body: some View {
        HStack(spacing:18) {
            ForEach(CategorySortOrder.allCases,id:\.self) { order in
                Button(order.rawValue) { rawOrder = order.rawValue }
                    .buttonStyle(NeutralPillStyle(selected:rawOrder == order.rawValue))
                    .accessibilityIdentifier(order == .date ? "category-sort-date" : "category-sort-az")
            }
        }.accessibilityIdentifier("category-sort-controls")
    }
}
