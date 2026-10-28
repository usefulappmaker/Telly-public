// SPDX-License-Identifier: GPL-3.0-or-later
// Simulator-only integration entry point. Excluded from Release builds.
#if DEBUG
import SwiftUI
import AVFoundation
import CoreVideo
import Security

struct UHDValidationView: View {
    @StateObject private var playback = PlaybackModel()
    var body: some View {
        PlaybackScreen(model: playback).task {
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UHD-validation.json")
            func record(_ values: [String: Any]) {
                try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONSerialization.data(withJSONObject: values, options: .prettyPrinted) { try? data.write(to: output, options: .atomic) }
            }
            do {
                record(["status": "starting"])
                if let link = ProcessInfo.processInfo.environment["TELLY_SETUP_URL"] {
                    let payload = try await UHDProvisioningClient(link: link).retrieve()
                    try UHDIdentityVault.install(payload)
                }
                guard UHDIdentityVault.isConfigured else { throw BBCError.message("Simulator UHD identity was not persisted.") }
                record(["status": "identity-imported", "identityPersisted": true])
                var programme = Programme(id: "m002cgz3", title: "The Americas", summary: "", image: nil, version: "m002cgz2", guidance: nil)
                programme.showTitle = "The Americas"; programme.episodeSubtitle = "UHD integration validation"
                playback.start(programme, require1080: true, quality: .uhd) {}
                var passed = false
                for _ in 0..<150 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if let error = playback.error { throw BBCError.message(error) }
                    guard let item = playback.player.currentItem else { continue }
                    if item.presentationSize.height >= 2160 && playback.player.currentTime().seconds >= 90 {
                        let sought = await playback.player.seek(to: CMTime(seconds: 900, preferredTimescale: 600))
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                        guard sought && playback.player.currentTime().seconds >= 925 else { throw BBCError.message("Sustained playback after seeking failed.") }
                        record(["status": "passed", "identityPersisted": true, "width": Int(item.presentationSize.width), "height": Int(item.presentationSize.height), "time": playback.player.currentTime().seconds, "seekCompleted": true, "itemTrackCount": item.tracks.count])
                        passed = true; break
                    }
                }
                if !passed { throw BBCError.message("Timed out waiting for simulator UHD playback.") }
            } catch { record(["status": "failed", "error": error.localizedDescription]); playback.error = error.localizedDescription }
        }
    }
}

/// Exercises real AVPlayer seeks, stopping, persistence and completion using a
/// short local test asset. It does not touch the household's normal history.
struct ProgressValidationView: View {
    @StateObject private var playback = PlaybackModel(sourceResolver: { _, _ in
        PlaybackSource(url: URL(string: "http://127.0.0.1:18746/progress.m3u8")!, requested1080: true)
    })
    @Environment(\.scenePhase) private var phase
    @State private var started = false
    var body: some View {
        PlaybackScreen(model: playback).task(id: phase) {
            guard phase == .active, !started else { return }; started = true
            Task { @MainActor in await validateProgress() }
        }
    }
    @MainActor private func validateProgress() async {
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Progress-validation.json")
            func record(_ status: String, _ extra: [String: Any] = [:]) {
                var values = extra; values["status"] = status
                if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: output, options: .atomic) }
            }
            let suite = "TellyProgressValidation"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            do {
                func episode(_ id: String, _ number: Int) -> CatalogueEpisode {
                    var p = Programme(id: id, title: "Progress test", summary: "", image: nil, version: "v0000001", guidance: nil)
                    p.showID = "b0000001"; p.showTitle = "Progress test"; p.episodeSubtitle = "Series 1: \(number). Test"
                    return CatalogueEpisode(programme: p, subtitle: p.episodeSubtitle!, duration: "20 seconds", sliceID: "series1", seriesTitle: "Series 1", parentPosition: number)
                }
                let one = episode("b0000002", 1), two = episode("b0000003", 2)
                let show = CatalogueShow(id: "b0000001", title: "Progress test", summary: "", image: nil, letter: "p", channel: "BBC", categories: [], expectedEpisodes: 2, singleEpisode: false, episodes: [two, one], indexedAt: Date())
                let history = WatchHistory(defaults: defaults)
                history.update(episode: one, show: show, next: two, position: 8, duration: 20)
                record("resuming-first")
                playback.player.isMuted = true
                playback.start(one.programme, history: history, show: show) {}
                @MainActor func waitForTime(_ minimum: Double, maximum: Double = 60) async throws {
                    for _ in 0..<Int(maximum * 10) {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        if let error = playback.error { throw BBCError.message(error) }
                        if playback.player.currentTime().seconds >= minimum { return }
                    }
                    throw BBCError.message("Progress test timed out at \(minimum) seconds")
                }
                try await waitForTime(10.5)
                guard playback.player.currentItem?.presentationSize.height == 1080 else { throw BBCError.message("Test video did not decode") }
                playback.stop()
                let reopened = WatchHistory(defaults: defaults)
                let saved = reopened.resumePosition(for: one.id)
                guard saved >= 10.5, saved < 15 else { throw BBCError.message("Stop did not save the current position") }
                record("resuming-after-stop", ["savedPosition": saved])
                playback.start(one.programme, history: reopened, show: show) {}
                try await waitForTime(saved + 1)
                try await waitForTime(19.95)
                try await Task.sleep(nanoseconds: 500_000_000)
                guard reopened.records.first?.completed == true, reopened.records.first?.target?.id == two.id else { throw BBCError.message("End did not offer the next episode") }
                record("starting-next", ["savedPosition": saved])
                playback.start(two.programme, history: reopened, show: show) {}
                try await waitForTime(1)
                guard playback.player.currentTime().seconds < 5 else { throw BBCError.message("Next episode reused the previous bookmark") }
                try await waitForTime(6)
                playback.stop()
                guard reopened.records.count == 1, reopened.records.first?.episode.id == two.id, reopened.resumePosition(for: two.id) >= 6 else { throw BBCError.message("Next episode did not replace the programme entry") }
                record("passed", ["savedPosition": saved, "nextEpisodePosition": reopened.resumePosition(for: two.id), "recordCount": reopened.records.count])
            } catch { playback.stop(); record("failed", ["error": error.localizedDescription]) }
    }
}

/// Tests the actual native subtitle decoder/rendering pipeline with a BBC TTML fixture.
private final class CaptionProbe: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var seen = [String]()
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        lock.lock(); seen += strings.map(\.string); lock.unlock()
    }
}
struct ExtrasValidationView: View {
    @StateObject private var playback = PlaybackModel(sourceResolver: { _, _ in
        PlaybackSource(url: URL(string: "http://127.0.0.1:18746/progress.m3u8")!, requested1080: true, versionID: "m002cgz2")
    }, extrasAPI: PlaybackExtrasAPI(fetch: { url in
        if url.path.contains("mediaselector") {
            return Data(#"<mediaSelection><media kind="captions" type="application/ttaf+xml"><connection href="https://fixture.invalid/captions"/></media></mediaSelection>"#.utf8)
        }
        if url.host == "fixture.invalid" { return try await BBCService().fetch(URL(string: "http://127.0.0.1:18746/captions.xml")!) }
        return Data(#"{"episodes":[{"versions":[]}]}"#.utf8)
    }))
    @Environment(\.scenePhase) private var phase
    @State private var started = false
    var body: some View {
        PlaybackScreen(model: playback).task(id: phase) {
            guard phase == .active, !started else { return }; started = true
            Task { @MainActor in await validate() }
        }
    }
    @MainActor private func validate() async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Extras-validation.json")
        func record(_ values: [String: Any]) { if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: output, options: .atomic) } }
        do {
            playback.player.isMuted = true
            playback.start(Programme(id: "m002cgz3", title: "Native BBC subtitle validation", summary: "", image: nil, version: "m002cgz2", guidance: nil)) {}
            for _ in 0..<300 {
                if playback.player.currentItem?.status == .readyToPlay { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let item = playback.player.currentItem,
                  let group = try await item.asset.loadMediaSelectionGroup(for: .legible),
                  let english = group.options.first(where: { $0.extendedLanguageTag?.hasPrefix("en") == true }) else { throw BBCError.message("No native English subtitle option") }
            let probe = CaptionProbe(), legible = AVPlayerItemLegibleOutput()
            legible.suppressesPlayerRendering = false; legible.setDelegate(probe, queue: .main); item.add(legible)
            item.select(english, in: group)
            _ = await playback.player.seek(to: CMTime(seconds: 4.7, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            playback.player.play()
            for _ in 0..<100 {
                if probe.texts.contains(where: { $0.contains("Welcome to The Americas") }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard probe.texts.contains(where: { $0.contains("Welcome to The Americas") }) else { throw BBCError.message("BBC caption was not decoded by AVPlayer") }
            item.select(nil, in: group)
            guard item.currentMediaSelection.selectedMediaOption(in: group) == nil else { throw BBCError.message("Off did not deselect native subtitles") }
            item.select(english, in: group)
            _ = await playback.player.seek(to: CMTime(seconds: 8.8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            playback.player.play()
            for _ in 0..<80 {
                if probe.texts.contains(where: { $0.contains("extraordinary journey") }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard probe.texts.contains(where: { $0.contains("extraordinary journey") }) else { throw BBCError.message("Subtitles did not resume after Off and seek") }
            playback.player.pause()
            record(["status": "passed", "nativeTrackCount": group.options.count, "decodedBBCText": probe.texts, "customSubtitleButtonCount": 0])
        } catch { record(["status": "failed", "error": error.localizedDescription]) }
    }
}

/// Verifies device-only Keychain setup persistence and legacy identity recovery on Simulator.
struct IdentityValidationView: View {
    @State private var started = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Text("UHD setup persistence test").task(id: phase) {
            guard phase == .active, !started else { return }; started = true
            Task { @MainActor in await validate() }
        }
    }
    @MainActor private func validate() async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Identity-validation.json")
        func record(_ values: [String: Any]) { if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: output, options: .atomic) } }
        do {
            if ProcessInfo.processInfo.environment["TELLY_IDENTITY_VERIFY"] == "1" {
                guard UHDIdentityVault.isConfigured else { throw BBCError.message("Setup lost across restart") }
                record(["status": "restart-passed"]); return
            }
            guard let link = ProcessInfo.processInfo.environment["TELLY_SETUP_URL"] else { throw BBCError.message("Missing setup link") }
            let payload = try await UHDProvisioningClient(link: link).retrieve()
            try UHDIdentityVault.install(payload)
            guard let identity = UHDIdentityVault.identity() else { throw BBCError.message("Initial import failed") }
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw BBCError.message("No certificate") }
            // Simulate an imported certificate's label changing during an update.
            let certQuery: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate]
            let changed = SecItemUpdate(certQuery as CFDictionary, [kSecAttrLabel as String: "Telly UHD recovery validation"] as CFDictionary)
            guard changed == errSecSuccess else { throw BBCError.message("Unable to change test certificate label: \(changed)") }
            let generic: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.tellyplayer.Telly.uhd-setup", kSecAttrAccount as String: "setup-v1"]
            SecItemDelete(generic as CFDictionary)
            guard UHDIdentityVault.isConfigured else { throw BBCError.message("Legacy fingerprint lookup failed after label change") }
            try UHDIdentityVault.install(payload)
            UserDefaults.standard.removeObject(forKey: "bbcUHDIdentityFingerprint-v1")
            UserDefaults.standard.removeObject(forKey: "bbcUHDUserAgent-v1")
            guard UHDIdentityVault.isConfigured && UHDIdentityVault.userAgent == payload.userAgent else { throw BBCError.message("Setup depends on app preferences") }
            let removed = SecItemDelete(certQuery as CFDictionary)
            guard removed == errSecSuccess, UHDIdentityVault.isConfigured else { throw BBCError.message("Retained setup could not reconstruct a missing certificate") }
            record(["status": "passed", "labelRecovery": true, "preferenceLossRecovery": true, "certificateRecovery": true])
        } catch { record(["status": "failed", "error": error.localizedDescription]) }
    }
}

struct HistoryLayoutValidationView: View {
    @StateObject private var history = WatchHistory(defaults: UserDefaults(suiteName: "TellyHistoryLayoutPreview")!)
    @StateObject private var library = Library(defaults: UserDefaults(suiteName: "TellyHistoryLayoutLibrary")!)
    @StateObject private var catalogue = CatalogueStore()
    private func episode(_ showID: String, _ id: String, _ title: String, _ number: Int) -> CatalogueEpisode {
        var p = Programme(id: id, title: title, summary: "Discover the latest programmes on Telly.", image: URL(string: "http://127.0.0.1:18746/wide.png"), version: "v0000001", guidance: nil)
        p.showID = showID; p.showTitle = title; p.episodeSubtitle = "Series 1: \(number). Episode \(number)"
        return CatalogueEpisode(programme: p, subtitle: p.episodeSubtitle!, duration: "1 hour", sliceID: "s1", seriesTitle: "Series 1", parentPosition: number)
    }
    private func show(_ id: String, _ title: String) -> CatalogueShow {
        CatalogueShow(id: id, title: title, summary: "Discover the latest programmes on Telly.", image: URL(string: "http://127.0.0.1:18746/wide.png"), letter: "a", channel: "BBC", categories: [], expectedEpisodes: 3, singleEpisode: false, episodes: [], indexedAt: nil)
    }
    var body: some View {
        Group {
            if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "programme" {
                let episodes = (1...4).reversed().flatMap { season in
                    (1...3).reversed().map { number in
                        let base = episode("b0000001", "b00000\(season)\(number)", "Example programme", number)
                        return CatalogueEpisode(programme: base.programme, subtitle: "Series \(season): \(number). Episode \(number)", duration: "1 hour", sliceID: "s\(season)", seriesTitle: "Series \(season)", parentPosition: number)
                    }
                }
                let show = CatalogueShow(id: "b0000001", title: "Example programme", summary: "Series and episodes", image: nil, letter: "e", channel: "BBC", categories: [], expectedEpisodes: 12, singleEpisode: false, episodes: episodes, indexedAt: Date())
                CatalogueShowView(show: show, catalogue: catalogue, library: library)
            } else if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "detail" {
                DetailView(programme: episode("b0000001", "b0000002", "The Americas", 1).programme, show: show("b0000001", "The Americas"), library: library)
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 30) {
                    Image("TellyBoxLogo").resizable().scaledToFit().frame(width: 96, height: 36)
                    ContinueWatchingRow(catalogue: catalogue, library: library)
                }.padding(64) }
            }
        }.environmentObject(history).task {
            for record in history.records { history.remove(record.id) }
            if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "history" {
                history.update(episode: episode("b0000001", "b0000002", "The Americas", 1), show: show("b0000001", "The Americas"), next: episode("b0000001", "b0000003", "The Americas", 2), position: 900, duration: 3600)
                history.update(episode: episode("b0000004", "b0000005", "Blue Lights", 1), show: show("b0000004", "Blue Lights"), next: episode("b0000004", "b0000006", "Blue Lights", 2), position: 3600, duration: 3600, ended: true)
            }
        }
    }
}
#endif
