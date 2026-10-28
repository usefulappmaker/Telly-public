import Foundation
import AVFoundation
import ImageIO
func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
@main struct PlaybackExtrasTests {
    static func main() async throws {
        let raw: [String: Any] = ["id": "m00304fh", "title": "Example", "subtitle": "Series 1: Episode 1", "versions": [
            ["id": "m00304fj", "kind": "original", "uhd": true, "hdr": false, "duration": ["text": "59 mins"], "interactions": [
                ["type": "skip", "subtype": "recap", "interaction_points": ["show_from": 1, "skip_to": 85]],
                ["type": "skip", "subtype": "intro", "interaction_points": ["show_from": 100, "skip_to": 120]],
                ["type": "skip", "subtype": "intro", "interaction_points": ["show_from": -1, "skip_to": 0]],
                ["type": "skip", "subtype": "intro", "interaction_points": ["show_from": 10, "skip_to": 9]]
            ]], ["id": "m00304fk", "kind": "audio-described", "hdr": true]
        ]]
        let fixture = try JSONSerialization.data(withJSONObject: ["episodes": [raw]])
        let api = PlaybackExtrasAPI(fetch: { _ in fixture })
        let programme = try await api.programme("m00304fh")
        check(programme.uhdListed == true && programme.hdrListed == false && programme.durationText == "59 mins", "Original version's explicit HDR false and duration retained")
        let markers = try await api.markers(episodeID: programme.id, versionID: "m00304fj")
        check(markers.count == 2 && markers[0].title == "Skip recap" && markers[1].title == "Skip intro", "Valid recap and intro markers")
        check(!markers[0].contains(0.99) && markers[0].contains(1) && markers[0].contains(84.99) && !markers[0].contains(85), "Exact visibility boundaries")
        let unmatched = try await api.markers(episodeID: programme.id, versionID: "m00304fz")
        check(unmatched.isEmpty, "Never borrow timestamps from another version")
        var info = Programme(id: "p0000001", title: "A film", summary: "Full episode synopsis.", image: nil, version: "", guidance: "Contains strong language.")
        info.durationText = "58 mins"; info.firstBroadcast = "1 Mar 2022"; info.firstBroadcastDateTime = "2022-03-01T00:00:00.000Z"
        let artwork = Data([1, 2, 3])
        let metadata = PlaybackInfoMetadata.items(title: "A film", subtitle: "Episode 1", programme: info, artwork: artwork)
        let description = try await metadata.first { $0.identifier == .commonIdentifierDescription }?.load(.stringValue) ?? ""
        check(description == "Full episode synopsis.\n\nContains strong language.", "Native Info synopsis excludes duplicated runtime/date while retaining guidance")
        let artworkValue = try await metadata.first { $0.identifier == .commonIdentifierArtwork }?.load(.dataValue)
        check(artworkValue == artwork, "Native artwork metadata retains thumbnail bytes")
        let releaseValue = try await metadata.first { $0.identifier == .iTunesMetadataReleaseDate }?.load(.stringValue)
        check(releaseValue == info.firstBroadcastDateTime, "Native release metadata uses BBC first broadcast date")
        let png = try Data(contentsOf: URL(fileURLWithPath: "Telly/Assets.xcassets/BrandLogo.imageset/logo.png"))
        let resized = PlaybackInfoArtwork.jpeg(from: png)
        check(resized != nil && PlaybackInfoArtwork.jpeg(from: Data("not an image".utf8)) == nil, "Info artwork safely decodes PNG and rejects invalid input")
        let imageSource = CGImageSourceCreateWithData(resized! as CFData, nil)!
        let dimensions = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        check((dimensions?[kCGImagePropertyPixelWidth] as? Int ?? 9999) <= 960 && (dimensions?[kCGImagePropertyPixelHeight] as? Int ?? 9999) <= 960, "Info artwork is bounded before native rendering")
        let emptyInfo = PlaybackInfoMetadata.items(title: "Live", subtitle: "BBC Two")
        check(emptyInfo.count == 2, "Missing optional metadata produces no empty or fabricated Info fields")
        let rawInfo: [String: Any] = ["id": "p0000001", "title": "Example", "synopses": ["small": "Short", "large": "Full synopsis"], "release_date_time": "2026-10-18T00:00:00Z", "versions": [["id": "b0000001", "kind": "original", "first_broadcast": "1 Mar 2022", "first_broadcast_date_time": "2022-03-01T00:00:00.000Z"]]]
        let parsedInfo = try CatalogueAPI.episode(rawInfo).programme
        check(parsedInfo.summary == "Full synopsis" && parsedInfo.firstBroadcast == "1 Mar 2022", "Episode parsing prefers full synopsis and original broadcast over catalogue re-release date")
        let legacyInfo = Data(#"{"id":"p0000001","title":"Legacy","summary":"Old","version":"","image":null,"guidance":null}"#.utf8)
        let legacyProgramme = try JSONDecoder().decode(Programme.self, from: legacyInfo)
        check(legacyProgramme.firstBroadcast == nil, "Legacy cached programmes remain decodable without original-date fields")
        let ttml = Data("""
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttp="http://www.w3.org/ns/ttml#parameter" ttp:frameRate="25"><head><metadata>Do not show this</metadata></head><body><div begin="2s"><p begin="00:00:01.500" end="00:00:03"><span>Hello &amp; welcome</span><br/><span>Second line</span></p><p begin="4s" dur="2s">Next</p><p begin="10s" end="9s">Invalid</p><p begin="00:00:08:12" dur="25f">Frames</p></div></body></tt>
        """.utf8)
        let cues = try TTMLSubtitles.parse(ttml)
        check(cues.count == 3 && cues[0].start == 3.5 && cues[0].end == 5, "Parent timing, invalid interval rejection")
        check(SubtitleCue.text(at: 3.5, in: cues) == "Hello & welcome\nSecond line", "Entities, nested spans and line breaks")
        check(SubtitleCue.text(at: 5, in: cues) == nil && SubtitleCue.text(at: 6, in: cues) == "Next", "Subtitle end and next boundaries")
        check(SubtitleCue.text(at: 3.5, in: cues)?.hasPrefix("Hello") == true, "Backward seek restores earlier subtitles")
        check(abs(cues[2].start - 10.48) < 0.0001 && abs(cues[2].end - 11.48) < 0.0001, "Frame clock and frame offsets")
        let selector = Data("""
        <mediaSelection><media kind="captions" type="application/ttaf+xml"><connection href="http://example.org/a"/><connection href="https://example.org/subtitles"/></media></mediaSelection>
        """.utf8)
        let captions = try await PlaybackExtrasAPI(fetch: { url in url.path == "/subtitles" ? ttml : selector }).subtitles(versionID: "m00304fj")
        check(captions == cues, "Sidecar caption discovery ignores insecure resources")
        let schedule = try JSONSerialization.data(withJSONObject: ["broadcasts": ["elements": [
            ["scheduled_start": "2026-10-15T14:00:00.000Z", "scheduled_end": "2026-10-15T14:45:00.000Z", "episode": ["title": "Current show", "images": ["standard": "https://example.org/{recipe}/image.jpg"]]],
            ["scheduled_start": "2026-10-15T14:45:00Z", "scheduled_end": "2026-10-15T15:00:00Z", "episode": ["title": "Next show"]]
        ]]])
        let date = ISO8601DateFormatter().date(from: "2026-10-15T14:44:59Z")!
        let current = try DiscoveryAPI.currentBroadcast(schedule, now: date)
        check(current?.title == "Current show" && current?.image?.absoluteString.contains("640x360") == true, "Current broadcast artwork and title")
        let next = try DiscoveryAPI.currentBroadcast(schedule, now: date.addingTimeInterval(1))
        check(next?.title == "Next show", "Schedule rollover uses exact end boundary")
        let base = URL(string: "https://example.org/path/master.m3u8?token=test")!
        let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=24000000,RESOLUTION=3840x2160,VIDEO-RANGE=HLG\nvideo.m3u8\n"
        let assets = try HLSSubtitles.assets(cues: cues, duration: 20, master: master, base: base)
        let wrapped = String(decoding: assets["/master.m3u8"]!, as: UTF8.self)
        check(wrapped.contains("RESOLUTION=3840x2160,VIDEO-RANGE=HLG") && wrapped.contains("SUBTITLES=\"bbc-subtitles\"") && wrapped.contains("video.m3u8?token=test"), "Native subtitle track preserves UHD/HLG and signed video URL")
        check(wrapped.contains("https://example.org/path/audio.m3u8?token=test"), "Native audio URI remains valid after wrapping")
        let segment = String(decoding: assets["/subtitles/0.vtt"]!, as: UTF8.self)
        check(segment.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP=") && segment.contains("Hello &amp; welcome"), "Timed native WebVTT segment with escaped caption text")
        let last = String(decoding: assets["/subtitles/english.m3u8"]!, as: UTF8.self)
        check(last.contains("#EXTINF:2.000000") && last.contains("#EXT-X-ENDLIST"), "Subtitle duration matches video, including final partial segment")
        let pts: UInt64 = 900000
        var packet = [UInt8](repeating: 0xff, count: 188)
        packet.replaceSubrange(0..<4, with: [0x47,0x41,0,0x10])
        packet.replaceSubrange(4..<13, with: [0,0,1,0xe0,0,0,0x80,0x80,5])
        packet.replaceSubrange(13..<18, with: [UInt8(0x21 | ((pts >> 30) & 7) << 1), UInt8((pts >> 22) & 255), UInt8(((pts >> 15) & 127) << 1 | 1), UInt8((pts >> 7) & 255), UInt8((pts & 127) << 1 | 1)])
        check(HLSSubtitles.firstVideoPTS(Data(packet)) == pts && HLSSubtitles.firstVideoPTS(Data()) == nil, "MPEG-TS video presentation clock and malformed input")
        let tsAssets = try HLSSubtitles.assets(cues: cues, duration: 20, master: master, base: base, mpegTimestamp: pts)
        check(String(decoding: tsAssets["/subtitles/0.vtt"]!, as: UTF8.self).contains("MPEGTS:900000"), "HD WebVTT adopts nonzero transport-stream clock")
        let logo = CatalogueAPI.programmeImage(["standard": "https://example.org/plain.jpg", "promotional_with_logo": "https://example.org/{recipe}/logo.jpg"])
        check(logo?.lastPathComponent == "logo.jpg", "Catalogue chooses programme logo artwork")
        check(CatalogueAPI.programmeImage(["standard": "https://example.org/plain.jpg", "promotional_with_logo": ""])?.lastPathComponent == "plain.jpg", "Missing logo artwork falls back to standard")
        if CommandLine.arguments.count > 1 {
            let real = try TTMLSubtitles.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            check(real.count > 100 && real[0].start == 5 && real[0].text == "Welcome to The Americas...", "Real BBC caption file")
            print("Real BBC TTML: \(real.count) cues parsed")
        }
        print("PASS: native Info metadata/artwork/original date, legacy decoding, version-specific skip markers, HDR/duration, TTML timing and seeking, caption discovery, live schedule boundaries")
    }
}
