// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct Channel4Page { let shows: [CatalogueShow]; let total: Int; let offset: Int }
struct Channel4CatalogueAPI {
    static let categories: [Genre] = [
        Genre(id: "drama", title: "Drama"), Genre(id: "comedy", title: "Comedy"),
        Genre(id: "documentaries", title: "Documentaries"), Genre(id: "entertainment", title: "Entertainment"),
        Genre(id: "film", title: "Films"), Genre(id: "lifestyle", title: "Lifestyle"),
        Genre(id: "sport", title: "Sport"), Genre(id: "news-current-affairs-and-politics", title: "News & Current Affairs"),
        Genre(id: "world-drama", title: "World Drama"), Genre(id: "audio-described", title: "Audio Described")]
    static func state(_ data: Data) throws -> [String: Any] {
        let html = String(decoding: data, as: UTF8.self)
        guard let marker = html.range(of: "window.__PARAMS__"), let start = html[marker.upperBound...].firstIndex(of: "{") else { throw BBCError.message("Channel 4's catalogue format changed. Please retry.") }
        var depth = 0, quoted = false, escaped = false, normalized = "", i = start
        while i < html.endIndex {
            let c = html[i]
            if quoted {
                normalized.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
            } else {
                if html[i...].hasPrefix("undefined") { normalized += "null"; i = html.index(i, offsetBy: 9); continue }
                normalized.append(c)
                if c == "\"" { quoted = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { break } }
            }
            i = html.index(after: i)
        }
        guard depth == 0, let root = try JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any], let initial = root["initialData"] as? [String: Any] else { throw BBCError.message("Channel 4 catalogue data is unavailable.") }
        return initial
    }
    static func image(_ value: Any?) -> URL? {
        let raw = value as? String ?? (value as? [String: Any])?["src"] as? String ?? (value as? [String: Any])?["href"] as? String
        guard var raw else { return nil }
        raw = raw.replacingOccurrences(of: "{&resize}", with: "&resize=640:360").replacingOccurrences(of: "{resize}", with: "640:360").replacingOccurrences(of: "imformat=chrome", with: "imformat=jpeg").replacingOccurrences(of: "resize=120px:*", with: "resize=640:360")
        guard !raw.contains("{"), let url = URL(string: raw), url.scheme == "https", url.host?.hasSuffix(".c4assets.com") == true else { return nil }
        return url
    }
    static func show(_ data: [String: Any]) -> CatalogueShow? {
        let expanded = data["expandedTile"] as? [String: Any] ?? [:]
        guard let slug = data["websafeTitle"] as? String, slug.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil,
              let title = data["labelText"] as? String ?? data["title"] as? String else { return nil }
        let images = data["images"] as? [String: Any] ?? [:]
        let hero = images["hero"] as? [String: Any] ?? [:]
        let genres = expanded["genres"] as? [String] ?? data["genres"] as? [String] ?? []
        var show = CatalogueShow(id: "c4:" + slug, title: title, summary: expanded["summary"] as? String ?? data["summary"] as? String ?? data["overlayText"] as? String ?? data["description"] as? String ?? "", image: image(data["imageLink"] ?? data["thumbnailUrl"] ?? hero["landscape"] ?? data["image"]), letter: String(title.prefix(1)).lowercased(), channel: "Channel 4", categories: genres, expectedEpisodes: data["onDemandEpisodesCount"] as? Int ?? 0, singleEpisode: data["programmeType"] as? String == "FM", episodes: [])
        show.providerURL = URL(string: "https://www.channel4.com/programmes/" + slug)
        show.portraitImage = image(hero["portrait"])
        return show
    }
    static func page(_ initial: [String: Any]) -> Channel4Page {
        let brands = initial["brands"] as? [String: Any] ?? [:]
        let items = brands["items"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return Channel4Page(shows: items.compactMap(show).filter { seen.insert($0.id).inserted }, total: initial["noOfShows"] as? Int ?? items.count, offset: brands["offset"] as? Int ?? 0)
    }
    func category(_ id: String?, offset: Int = 0) async throws -> Channel4Page {
        guard id == nil || Self.categories.contains(where: { $0.id == id }) else { throw BBCError.message("Unknown Channel 4 category.") }
        let path = "/categories" + (id.map { "/" + $0 } ?? "") + "?json=true&offset=\(offset)&limit=60"
        let data = try await Channel4HTTP.shared.data(URL(string: "https://www.channel4.com" + path)!)
        guard let initial = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BBCError.message("Channel 4 returned an invalid catalogue page.") }
        return Self.page(initial)
    }
    static func details(_ initial: [String: Any], fallback: CatalogueShow) throws -> CatalogueShow {
        guard let brand = initial["brand"] as? [String: Any] else { throw BBCError.message("Channel 4 programme details are unavailable.") }
        var result = show(brand) ?? fallback
        result.indexedAt = Date()
        var seen = Set<String>()
        result.episodes = (brand["episodes"] as? [[String: Any]] ?? []).compactMap { e in
            guard let id = e["programmeId"] as? String, id.range(of: #"^[0-9]+-[0-9]+$"#, options: .regularExpression) != nil,
                  // Upcoming listings have a programme ID but no playable asset;
                  // Channel 4 marks their showPlayLabel as null, not false.
                  e["showPlayLabel"] as? Bool == true, e["nextOn"] as? Bool != true,
                  seen.insert(id).inserted else { return nil }
            let series = e["seriesNumber"] as? Int ?? 1
            let title = e["fullTitle"] as? String ?? e["title"] as? String ?? "Episode"
            let secondary = e["secondaryTitle"] as? String ?? ""
            let subtitle = secondary.isEmpty ? title : title + " · " + secondary
            var p = Programme(id: "c4:" + id, title: result.title, summary: e["fullDescription"] as? String ?? e["summary"] as? String ?? "", image: image(e["image"]) ?? result.image, version: "", guidance: e["guidance"] as? String)
            p.showID = result.id; p.showTitle = result.title; p.episodeSubtitle = subtitle
            p.durationText = e["durationLabel"] as? String
            p.firstBroadcastDateTime = CategorySorting.date(e["dateLabel"] as? String).map { ISO8601DateFormatter().string(from:$0) }
            p.premium = (e["upgradeToPlay"] as? [String: Any])?["active"] as? Bool ?? false
            return CatalogueEpisode(programme: p, subtitle: subtitle, duration: p.durationText ?? "", sliceID: "c4:series:\(series)", seriesTitle: "Series \(series)", parentPosition: e["episodeNumber"] as? Int)
        }
        result.expectedEpisodes = result.episodes.count
        return result
    }
    func details(_ show: CatalogueShow) async throws -> CatalogueShow {
        guard show.provider == .channel4, let url = show.providerURL, url.host == "www.channel4.com", url.path.hasPrefix("/programmes/") else { throw BBCError.message("Invalid Channel 4 programme address.") }
        return try Self.details(Self.state(await Channel4HTTP.shared.data(url)), fallback: show)
    }
    static func date(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return plain.date(from: raw) ?? fractional.date(from: raw)
    }
    func search(_ query: String) async throws -> [CatalogueShow] {
        var parts = URLComponents(string: "https://all4nav.channel4.com/v1/api/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        let data = try await Channel4HTTP.shared.data(parts.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = root["results"] as? [[String: Any]] else { throw BBCError.message("Channel 4 search is unavailable.") }
        var seen = Set<String>()
        return rows.compactMap { ($0["brand"] as? [String: Any]).flatMap(Self.show) }.filter { seen.insert($0.id).inserted }
    }
    static func live(_ data: Data, now: Date = Date()) throws -> [LiveChannel] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let slots = (root?["slots"] as? [String: Any])?["now"] as? [[String: Any]] ?? []
        return liveSeed.map { channel in
            var channel = channel
            let code = String(channel.id.dropFirst(3))
            if let slot = slots.first(where: { $0["channel"] as? String == code }), let endRaw = slot["end"] as? String, let end = date(endRaw), end > now, let startRaw = slot["start"] as? String, let start = date(startRaw), start <= now, slot["offair"] as? Bool != true {
                channel.current = LiveProgramme(title: slot["title"] as? String ?? channel.title, subtitle: slot["summary"] as? String ?? "", image: image(slot["image"]), end: end)
            }
            return channel
        }
    }
    static var liveSeed: [LiveChannel] { [("C4","Channel 4"),("E4","E4"),("M4","More4"),("F4","Film4"),("4S","4seven")].map { LiveChannel(id:"c4:"+$0.0,title:$0.1) } }
    func live() async throws -> [LiveChannel] { try Self.live(await Channel4HTTP.shared.data(URL(string: "https://www.channel4.com/api/now-next")!)) }
}
