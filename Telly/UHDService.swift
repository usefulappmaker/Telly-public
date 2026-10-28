// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum PlaybackQuality { case automatic, hd, uhd }
struct UHDService {
    let fetch: (URL) async throws -> Data
    init(fetch: @escaping (URL) async throws -> Data = { try await BBCService().fetch($0) }) { self.fetch = fetch }
    static func compatible(_ variant: Variant) -> Bool {
        variant.height >= 2160 && variant.codecs?.contains("hvc1.") == true && variant.videoRange == "HLG"
    }
    func source(for programme: Programme) async throws -> PlaybackSource {
        let version: String
        if !programme.version.isEmpty { version = programme.version }
        else { version = try await BBCService().programme(programme.id).version }
        _ = try BBCService.pid(version)
        // Only normal BBC service requests. No client-certificate extraction or device impersonation.
        for set in ["iptv-uhd", "iptv-all"] {
            try Task.checkCancellation()
            do {
                let data = try await fetch(URL(string: "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/\(set)/vpid/\(version)/format/xml")!)
                let selector = MediaSelector(); let parser = XMLParser(data: data); parser.delegate = selector
                guard parser.parse(), selector.error == nil else { continue }
                for url in selector.urls {
                    try Task.checkCancellation()
                    do {
                        let master = String(decoding: try await fetch(url), as: UTF8.self)
                        for variant in BBCService.variants(master, base: url) where Self.compatible(variant) {
                            let media = String(decoding: try await fetch(variant.url), as: UTF8.self)
                            // Protected or unknown key formats need a separately supported licence path.
                            guard BBCService.validMediaPlaylist(media), !media.contains("#EXT-X-KEY:"), media.contains("#EXT-X-MAP:") else { continue }
                            return PlaybackSource(url: variant.url, requested1080: true, requestedHeight: 2160, videoRange: "HLG", versionID: version)
                        }
                    } catch { if Task.isCancelled { throw CancellationError() } }
                }
            } catch { if Task.isCancelled { throw CancellationError() } }
        }
        throw BBCError.message("BBC lists some episodes in 4K, but no compatible 4K HLG stream was returned for this app. HD playback is available separately.")
    }
}
