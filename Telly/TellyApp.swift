// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main struct TellyApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TELLY_U_ACCOUNT_PREVIEW"] == "1" { UAccountView().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_FTV_BRAND_PREVIEW"] == "1" { FTVBrandValidationView().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_U_CATALOGUE_PREVIEW"] == "1" { UCatalogueValidationView().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_C4_PREVIEW"] != nil { Channel4Preview().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "card-review" { ProgrammeCardReview().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "itv-programme" || ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "itv-collection" { ITVProgrammePreview().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_PLAYER_LAYOUT"] == "1" { PlayerLayoutValidationView().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_UHD_LAYOUT"] == "1" { UHDLayoutValidationView().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_IDENTITY_VALIDATE"] == "1" { IdentityValidationView().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_EXTRAS_VALIDATE"] == "1" { ExtrasValidationView().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_PROGRESS_VALIDATE"] == "1" { ProgressValidationView().preferredColorScheme(.dark) }
            else if ["detail", "history", "programme"].contains(ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] ?? "") { HistoryLayoutValidationView().preferredColorScheme(.dark) }
            else if ProcessInfo.processInfo.environment["TELLY_UHD_VALIDATE"] == "1" { UHDValidationView().preferredColorScheme(.dark) }
            else { HomeView().preferredColorScheme(.dark) }
            #else
            HomeView().preferredColorScheme(.dark)
            #endif
        }
    }
}
struct ProgrammeCard: View {
    let programme: Programme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgrammeThumbnail(url: programme.image, uhd: programme.uhdListed == true, hdr: programme.hdrListed == true, provider: programme.provider)
            Text(programme.episodeSubtitle ?? programme.title).font(.headline).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .topLeading)
            HStack { Spacer(); ProviderBadge(provider: programme.provider, subdued: true) }.frame(minHeight: 40)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct DetailView: View {
    @StateObject private var state = DetailViewState()
    let programme: Programme
    var show: CatalogueShow? = nil
    @ObservedObject var library: Library
    @StateObject private var playback = PlaybackModel()
    @State private var channel5Pairing = false
    @State private var uPairing = false
    @EnvironmentObject private var history: WatchHistory
    @Environment(\.dismiss) private var dismiss
    private var details: Programme { state.fresh ?? programme }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text(programme.showTitle ?? programme.title).font(.largeTitle).bold()
            if let subtitle = programme.episodeSubtitle, !subtitle.isEmpty { Text(subtitle).font(.title2) }
            ProviderBadge(provider: programme.provider)
            Text(programme.summary).font(.title3)
            HStack(spacing: 18) {
                if details.uhdListed == true { UHDListedBadge(hdr: details.hdrListed == true) }
                if let duration = details.durationText, !duration.isEmpty { Text(duration).font(.callout).foregroundStyle(.secondary) }
            }
            if details.uhdListed == true && !UHDIdentityVault.isConfigured {
                Text("Connect TwinVine in Settings to enable 4K playback. Until then, this episode will play in HD.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let guidance = programme.guidance, !guidance.isEmpty { Text(guidance).foregroundStyle(.orange) }
            if history.resumePosition(for: programme.id) > 0 {
                Text("Your saved position will resume automatically.").font(.callout).foregroundStyle(.secondary)
            }
            if programme.premium == true { Text(programme.provider == .channel4 ? "Channel 4+ · subscription playback is not available in this build." : "ITV Premium · account playback is not available in this build.").font(.callout).foregroundStyle(.orange) }
            Text(playback.status).font(.callout).foregroundStyle(.secondary)
            if let error = playback.error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack(spacing: 24) {
                Button {
                    playback.start(programme, history: history, show: show) { state.playing = true }
                } label: {
                    if playback.loading { FTVLoadingBars(width:36).frame(width: 40, height: 46) }
                    else { Image(systemName: "play.fill").font(.system(size: 34)).frame(width: 40, height: 46) }
                }.accessibilityLabel(playback.loading ? "Finding the best stream" : "Play at the best available quality")
                    .disabled(playback.loading || programme.premium == true).buttonStyle(OutlinedActionButtonStyle(square: true))
                if !playback.loading, history.resumePosition(for: programme.id) > 0 {
                    Button("Start over") { playback.start(programme, history: history, show: show, restart: true) { state.playing = true } }
                }
                if playback.loading { Button("Cancel") { playback.stop() } }
                if let show {
                    ProgrammeBookmarkButton(show: show, library: library)
                }
                Button("Close") { dismiss() }
            }.buttonStyle(OutlinedActionButtonStyle())
        }.padding(70)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "detail" { return }
            #endif
            if programme.provider == .bbc { state.fresh = try? await PlaybackExtrasAPI().programme(programme.id) }
        }
        .onChange(of: playback.uSignInRequired) { _,required in if required { uPairing = true } }
        .sheet(isPresented:$uPairing,onDismiss:{
            if UAccountModel.shared.signedIn { playback.start(programme,history:history,show:show) { state.playing = true } }
        }) { UAccountView() }
        .onChange(of: playback.channel5SignInRequired) { _, required in if required { channel5Pairing = true } }
        .sheet(isPresented: $channel5Pairing, onDismiss: {
            if Channel5AccountModel.shared.signedIn { playback.start(programme, history: history, show: show) { state.playing = true } }
        }) { Channel5AccountView() }
        .fullScreenCover(isPresented: $state.playing, onDismiss: { playback.stop() }) { PlaybackScreen(model: playback) }
        .onDisappear { if !state.playing { playback.stop() } }
    }
}
@MainActor final class DetailViewState: ObservableObject {
    @Published var playing = false
    @Published var fresh: Programme?
}
struct UHDListedBadge: View {
    var hdr = false
    var body: some View {
        Text("4K").font(.system(size: 19, weight: .bold)).padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.85)).foregroundStyle(.white).cornerRadius(6)
            .accessibilityLabel("BBC lists a 4K version")
    }
}

/// Neutral action buttons use a clear surface; focus uses a stronger
/// white outline, keeping all buttons the same height even when focused.
struct OutlinedActionButtonStyle: ButtonStyle {
    var square = false
    func makeBody(configuration: Configuration) -> some View {
        OutlinedActionSurface(content: configuration.label, pressed: configuration.isPressed, square: square)
    }
}
private struct OutlinedActionSurface<Content: View>: View {
    let content: Content
    let pressed: Bool
    let square: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        content.font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, square ? 0 : 32).frame(width: square ? 84 : nil, height: 84)
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(enabled ? 1 : 0.4), lineWidth: focused ? 3 : 1.5) }
            .opacity(enabled ? (pressed ? 0.7 : 1) : 0.5)
            .animation(.easeOut(duration: 0.15), value: focused)
            .focusEffectDisabled()
    }
}

struct ProgrammeBookmarkButton: View {
    let show: CatalogueShow
    @ObservedObject var library: Library
    var body: some View {
        Button { library.toggle(show) } label: {
            Image(systemName: library.contains(show) ? "bookmark.fill" : "bookmark")
                .font(.system(size: 32, weight: .medium))
        }.buttonStyle(OutlinedActionButtonStyle(square: true))
            .accessibilityLabel(library.contains(show) ? "Remove saved programme" : "Save programme")
    }
}
