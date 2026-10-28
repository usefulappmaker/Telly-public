// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct SkipMarker: Equatable {
    let title: String
    let start: Double
    let end: Double
    func contains(_ seconds: Double) -> Bool { seconds.isFinite && seconds >= start && seconds < end }
    static func parse(_ version: [String: Any]) -> [SkipMarker] {
        (version["interactions"] as? [[String: Any]] ?? []).compactMap { interaction in
            guard interaction["type"] as? String == "skip",
                  let subtype = interaction["subtype"] as? String, ["intro", "recap"].contains(subtype),
                  let points = interaction["interaction_points"] as? [String: Any],
                  let start = points["show_from"] as? Double, let end = points["skip_to"] as? Double,
                  start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return SkipMarker(title: subtype == "intro" ? "Skip intro" : "Skip recap", start: start, end: end)
        }.sorted { $0.start < $1.start }
    }
}
struct PlaybackExtrasAPI {
    let fetch: (URL) async throws -> Data
    init(fetch: @escaping (URL) async throws -> Data = { try await BBCService().fetch($0) }) { self.fetch = fetch }
    func episode(_ id: String) async throws -> [String: Any] {
        let data = try await fetch(URL(string: "https://ibl.api.bbc.co.uk/ibl/v1/episodes/\(try BBCService.pid(id))")!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let episode = (root["episodes"] as? [[String: Any]])?.first else { throw BBCError.message("Episode details are unavailable.") }
        return episode
    }
    func programme(_ id: String) async throws -> Programme { try CatalogueAPI.episode(await episode(id)).programme }
    func markers(episodeID: String, versionID: String) async throws -> [SkipMarker] {
        let episode = try await episode(episodeID)
        // Timings from an edited, signed or described version must never be applied to another version.
        guard let version = (episode["versions"] as? [[String: Any]])?.first(where: { $0["id"] as? String == versionID }) else { return [] }
        return SkipMarker.parse(version)
    }
    func subtitles(versionID: String) async throws -> [SubtitleCue] {
        let id = try BBCService.pid(versionID)
        let data = try await fetch(URL(string: "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/iptv-all/vpid/\(id)/format/xml")!)
        let selector = CaptionSelector(); let parser = XMLParser(data: data); parser.delegate = selector
        guard parser.parse() else { throw BBCError.message("Subtitle listing could not be read.") }
        for url in selector.urls {
            try Task.checkCancellation()
            if let data = try? await fetch(url), let cues = try? TTMLSubtitles.parse(data), !cues.isEmpty { return cues }
        }
        return []
    }
}
private final class CaptionSelector: NSObject, XMLParserDelegate {
    var urls = [URL]()
    private var captions = false
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if element == "media" { captions = attributes["kind"] == "captions" && ["application/ttaf+xml", "application/ttml+xml"].contains(attributes["type"] ?? "") }
        if captions, element == "connection", let href = attributes["href"], let url = URL(string: href), url.scheme == "https", !urls.contains(url) { urls.append(url) }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) { if element == "media" { captions = false } }
}
struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
    static func text(at time: Double, in cues: [SubtitleCue]) -> String? {
        guard time.isFinite else { return nil }
        // Re-evaluate against the media clock so seeks and simultaneous cues stay correct.
        // BBC files are small (typically hundreds of cues); no mutable playback cursor to go stale after a seek.
        let text = cues.filter { $0.start <= time && time < $0.end }.map(\.text).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
/// BBC EBU-TT-D / TTML text, including nested spans and explicit line breaks.
/// Presentation uses an accessible, high contrast player overlay; timing is on the media clock.
final class TTMLSubtitles: NSObject, XMLParserDelegate {
    private var cues = [SubtitleCue]()
    private var text = ""
    private var paragraph: (Double, Double)?
    private var stack = [(start: Double, end: Double)]()
    private var frameRate = 30.0
    private var tickRate = 1.0
    static func parse(_ data: Data) throws -> [SubtitleCue] {
        guard data.count <= 8_000_000 else { throw BBCError.message("Subtitle file is too large.") }
        let delegate = TTMLSubtitles(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw BBCError.message("Subtitle file could not be read.") }
        return delegate.cues.sorted { $0.start < $1.start }
    }
    func time(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        if parts.count == 4 { return parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / frameRate }
        for (suffix, scale) in [("ms", 0.001), ("h", 3600.0), ("m", 60.0), ("s", 1.0), ("f", 1 / frameRate), ("t", 1 / tickRate)] {
            if raw.hasSuffix(suffix), let number = Double(raw.dropLast(suffix.count)), number.isFinite { return number * scale }
        }
        return nil
    }
    func parser(_ parser: XMLParser, didStartElement raw: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let name = raw.split(separator: ":").last.map(String.init) ?? raw
        if name == "tt" {
            frameRate = max(1, Double(a["ttp:frameRate"] ?? "30") ?? 30)
            if let multiplier = a["ttp:frameRateMultiplier"]?.split(separator: " ").compactMap({ Double($0) }), multiplier.count == 2, multiplier[1] > 0 { frameRate *= multiplier[0] / multiplier[1] }
            tickRate = max(1, Double(a["ttp:tickRate"] ?? "1") ?? 1)
        }
        let parent = stack.last ?? (start: 0.0, end: Double.infinity)
        let start = parent.start + (time(a["begin"]) ?? 0)
        let end = min(parent.end, time(a["end"]).map { parent.start + $0 } ?? time(a["dur"]).map { start + $0 } ?? parent.end)
        stack.append((start, end))
        if name == "p" { paragraph = (start, end); text = "" }
        else if name == "br", paragraph != nil { text += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if paragraph != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement raw: String, namespaceURI: String?, qualifiedName: String?) {
        if raw.split(separator: ":").last == "p", let (start, end) = paragraph {
            let normalized = text.components(separatedBy: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if start.isFinite, end.isFinite, start >= 0, end > start, !normalized.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: normalized)) }
            paragraph = nil
        }
        if !stack.isEmpty { stack.removeLast() }
    }
}

/// Native AVKit subtitle rendition. Video/audio URLs and encoded media stay unchanged.
enum HLSSubtitles {
    static func resolve(_ reference: String, base: URL) -> URL? {
        if base.scheme == "https" { return BBCService.resolve(reference, base: base) }
        guard base.host == "127.0.0.1", let url = URL(string: reference, relativeTo: base)?.absoluteURL,
              url.scheme == "http", url.host == base.host else { return nil }
        return url
    }
    static func duration(_ text: String) -> Double {
        text.components(separatedBy: .newlines).filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { $0.dropFirst(8).split(separator: ",").first.flatMap { Double($0) } }.reduce(0, +)
    }
    static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    /// Read the first video PES presentation timestamp from an MPEG-2 transport stream.
    /// HD BBC transport streams can start on a nonzero clock; WebVTT must share that origin.
    static func firstVideoPTS(_ data: Data) -> UInt64? {
        let bytes = Array(data)
        guard bytes.count >= 188 else { return nil }
        for packet in stride(from: 0, through: bytes.count - 188, by: 188) {
            guard bytes[packet] == 0x47, bytes[packet + 1] & 0x40 != 0 else { continue }
            let control = (bytes[packet + 3] >> 4) & 3
            guard control == 1 || control == 3 else { continue }
            let p = packet + 4 + (control == 3 ? 1 + Int(bytes[packet + 4]) : 0)
            guard p + 14 <= packet + 188, bytes[p] == 0, bytes[p+1] == 0, bytes[p+2] == 1,
                  (0xe0...0xef).contains(bytes[p+3]), bytes[p+7] & 0x80 != 0 else { continue }
            let t = p + 9
            return (UInt64((bytes[t] >> 1) & 7) << 30) | (UInt64(bytes[t+1]) << 22) |
                (UInt64(bytes[t+2] >> 1) << 15) | (UInt64(bytes[t+3]) << 7) | UInt64(bytes[t+4] >> 1)
        }
        return nil
    }
    static func assets(cues: [SubtitleCue], duration: Double, master: String, base: URL, mpegTimestamp: UInt64 = 0) throws -> [String: Data] {
        guard duration.isFinite, duration > 0, duration <= 86400 else { throw BBCError.message("Invalid subtitle timeline.") }
        var files = [String: Data](), playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<Int(ceil(duration / 6)) {
            let start = Double(index) * 6, end = min(duration, start + 6)
            var vtt = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:\(mpegTimestamp)\n\n"
            for cue in cues where cue.start < end && cue.end > start {
                let text = cue.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                vtt += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(text)\n\n"
            }
            files["/subtitles/\(index).vtt"] = Data(vtt.utf8)
            playlist += String(format: "#EXTINF:%.6f,\n", locale: Locale(identifier: "en_US_POSIX"), end - start) + "\(index).vtt\n"
        }
        files["/subtitles/english.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        let entry = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"bbc-subtitles\",NAME=\"English (BBC)\",LANGUAGE=\"en-GB\",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,CHARACTERISTICS=\"public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound\",URI=\"subtitles/english.m3u8\"\n"
        var output = "#EXTM3U\n#EXT-X-VERSION:7\n" + entry
        if master.contains("#EXT-X-STREAM-INF:") {
            let regex = try NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
            for raw in master.components(separatedBy: .newlines) {
                var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line == "#EXTM3U" || line.hasPrefix("#EXT-X-VERSION:") { continue }
                for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    if let range = Range(match.range(at: 1), in: line), let url = resolve(String(line[range]), base: base) { line.replaceSubrange(range, with: url.absoluteString) }
                }
                if line.hasPrefix("#EXT-X-STREAM-INF:") { line += ",SUBTITLES=\"bbc-subtitles\"" }
                else if !line.hasPrefix("#"), let url = resolve(line, base: base) { line = url.absoluteString }
                output += line + "\n"
            }
        } else {
            output += "#EXT-X-STREAM-INF:BANDWIDTH=12000000,SUBTITLES=\"bbc-subtitles\"\n\(base.absoluteString)\n"
        }
        files["/master.m3u8"] = Data(output.utf8)
        return files
    }
}

#if canImport(AVFoundation)
import AVFoundation

/// Metadata used directly by AVKit’s native Info panel.
enum PlaybackInfoMetadata {
    static func synopsis(_ programme: Programme?) -> String {
        guard let programme else { return "" }
        return [programme.summary, programme.guidance ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    static func items(title: String, subtitle: String, programme: Programme? = nil, artwork: Data? = nil) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ text: String) -> AVMetadataItem {
            let value = AVMutableMetadataItem(); value.identifier = identifier; value.value = text as NSString; value.extendedLanguageTag = "en-GB"; return value
        }
        var result = [item(.commonIdentifierTitle, title)]
        if !subtitle.isEmpty { result.append(item(.iTunesMetadataTrackSubTitle, subtitle)) }
        if let programme {
            let description = synopsis(programme)
            if !description.isEmpty { result.append(item(.commonIdentifierDescription, description)) }
            if let date = programme.firstBroadcastDateTime, !date.isEmpty { result.append(item(.iTunesMetadataReleaseDate, date)) }
        }
        if let artwork {
            let value = AVMutableMetadataItem(); value.identifier = .commonIdentifierArtwork
            value.value = artwork as NSData; value.dataType = "public.jpeg"
            result.append(value)
        }
        return result
    }
}
#endif

#if canImport(ImageIO)
import ImageIO

/// Decode and resize once before AVKit sees the artwork. Called off the main actor.
enum PlaybackInfoArtwork {
    static func jpeg(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 8_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 960,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
#endif
