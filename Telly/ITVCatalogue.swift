// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ContentProvider: String, Codable { case bbc, itv, channel4, channel5, u
    var title: String { switch self { case .bbc: return "BBC"; case .itv: return "ITV"; case .channel4: return "Channel 4"; case .channel5: return "Channel 5"; case .u: return "U" } }
    var logo: String { switch self { case .bbc: return "BBCLogo"; case .itv: return "ITVLogo"; case .channel4: return "Channel4Logo"; case .channel5: return "Channel5Logo"; case .u: return "ULogo" } }
    static func of(_ id: String) -> Self { id.hasPrefix("itv:") ? .itv : id.hasPrefix("c4:") ? .channel4 : id.hasPrefix("c5:") ? .channel5 : id.hasPrefix("u:") ? .u : .bbc }
}
extension Programme { var provider: ContentProvider { .of(id) } }
extension CatalogueShow { var provider: ContentProvider { .of(id) } }
extension LiveChannel { var provider: ContentProvider { .of(id) } }
struct ITVRail: Identifiable {
    let id: String
    let title: String
    let shows: [CatalogueShow]
    var more: String? = nil
}
struct ITVCategory: Identifiable {
    let id: String
    let title: String
    let path: String
}
struct ITVCatalogueAPI {
    var fetch: (URL) async throws -> Data = { url in
        var request = URLRequest(url: url); request.timeoutInterval = 18
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == url.host, data.count < 8 * 1024 * 1024 else {
            throw BBCError.message("ITV's catalogue is unavailable. Please retry.")
        }
        return data
    }
    static func pageURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: "https://www.itv.com" + path),
              url.host == "www.itv.com", url.user == nil, url.password == nil else { throw BBCError.message("Invalid ITV programme address.") }
        return url
    }
    func page(_ path: String) async throws -> [String: Any] {
        try Self.props(await fetch(Self.pageURL(path)))
    }
    static func props(_ data: Data) throws -> [String: Any] {
        let html = String(decoding: data, as: UTF8.self)
        let pattern = #"<script\b[^>]*\bid=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let root = try JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any],
              let props = (root["props"] as? [String: Any])?["pageProps"] as? [String: Any],
              props["statusCode"] as? Int != 404 else { throw BBCError.message("ITV's page format changed or this programme is unavailable.") }
        return props
    }
    static func image(_ raw: Any?) -> URL? {
        guard var value = raw as? String else { return nil }
        let replacements = ["width":"640", "height":"360", "quality":"80", "blur":"0", "bg":"false",
            "class":"04_DesktopCTV_RailTileLandscape", "aspect_ratio":"16x9", "distributionPartner":"itv_hub",
            "treatment":"title", "fallback":"standard"]
        for (key, replacement) in replacements { value = value.replacingOccurrences(of: "{\(key)}", with: replacement) }
        guard !value.contains("{"), let url = URL(string: value), url.scheme == "https" else { return nil }
        return url
    }
    static func show(_ data: [String: Any]) -> CatalogueShow? {
        let isCollection = data["contentType"] as? String == "collection" || data["collectionId"] is String
        let encoded = (data["encodedProgrammeId"] as? [String: Any])?["letterA"] as? String
        let raw = isCollection ? (data["collectionId"] as? String ?? encoded) :
            (encoded ?? (data["programmeId"] as? String)?.replacingOccurrences(of: "/", with: "a").replacingOccurrences(of: "_", with: "a")
             ?? ((data["legacyId"] as? [String: Any])?["apiEncoded"] as? String)?.replacingOccurrences(of: "_", with: "a"))
        guard let raw, raw.count <= 128, raw.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil,
              let name = (data["title"] ?? data["programmeTitle"] ?? data["filmTitle"] ?? data["specialTitle"]) as? String else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = (data["titleSlug"] as? String) ?? title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        guard !title.isEmpty, !slug.isEmpty, slug.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        let latest = data["latestAvailableEpisode"] as? [String: Any] ?? [:]
        let genres = (data["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? data["genre"] as? [String] ?? []
        var show = CatalogueShow(id: "itv:" + raw, title: title,
            summary: (isCollection ? data["subtitle"] ?? data["description"] : data["longDescription"] ?? data["descriptionEpg"] ?? data["description"] ?? data["synopsis"]) as? String ?? "",
            image: image(data["image"] ?? data["imageTemplate"] ?? data["imageUrl"] ?? data["imageHref"] ?? latest["imageHref"]),
            letter: String(title.prefix(1)).lowercased(), channel: "ITV", categories: genres,
            expectedEpisodes: isCollection ? 0 : data["totalAvailableEpisodes"] as? Int ?? 0, singleEpisode: !isCollection && data["contentType"] as? String == "film", episodes: [])
        show.providerURL = try? pageURL("/watch/\(isCollection ? "collections/" : "")\(slug)/\(raw)")
        show.catalogueDate = CategorySorting.date(data["dateTime"] as? String)
        show.premium = data["isPaid"] as? Bool ?? ((data["tier"] as? String).map { $0 != "FREE" }) ?? (data["tier"] as? [String]).map { !$0.contains("FREE") }
        return show
    }
    /// Older saved cards used programme routes for collection IDs. Recover them
    /// without changing their identity or losing the user's saved programme.
    static func collectionPath(_ show: CatalogueShow) -> String? {
        guard show.provider == .itv, let url = show.providerURL, url.host == "www.itv.com" else { return nil }
        if url.path.hasPrefix("/watch/collections/") { return url.path }
        let id = String(show.id.dropFirst(4))
        let parts = url.path.split(separator: "/")
        guard id.count >= 16, id.count <= 128,
              id.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil,
              id.range(of: #"^[0-9]+(?:a[0-9]+)+[A-Za-z]?$"#, options: .regularExpression) == nil,
              parts.count == 3, parts[0] == "watch", String(parts[2]) == id else { return nil }
        return "/watch/collections/\(parts[1])/\(id)"
    }
    static func rails(_ props: [String: Any]) -> [ITVRail] {
        var rails = [ITVRail]()
        func append(_ id: String, _ title: String, _ items: [[String: Any]], _ more: String?) {
            var seen = Set<String>()
            let shows = items.compactMap(show).filter { seen.insert($0.id).inserted }
            if !shows.isEmpty {
                var path = more
                if let more, more.hasPrefix("/collections/") { path = "/watch" + more }
                rails.append(ITVRail(id: id, title: title, shows: shows, more: path))
            }
        }
        // A collection's own titles take precedence over any recommendation rails.
        if let collection = props["collection"] as? [String: Any], let items = collection["shows"] as? [[String: Any]] {
            append("collection", collection["headingTitle"] as? String ?? props["headingTitle"] as? String ?? "ITV collection", items, nil)
            return rails
        }
        if let heroes = props["heroContent"] as? [[String: Any]] { append("featured", "Featured on ITV", heroes, nil) }
        if let trending = props["trendingSliderContent"] as? [String: Any] {
            append("trending", "Most watched on ITV", trending["items"] as? [[String: Any]] ?? [], nil)
        }
        for (i, value) in (props["editorialSliders"] as? [[String: Any]] ?? []).enumerated() {
            let header = value["header"] as? [String: Any] ?? [:]
            append("home-\(i)", header["title"] as? String ?? "ITV programmes", value["items"] as? [[String: Any]] ?? [], header["linkHref"] as? String)
        }
        for (i, value) in (props["editorialCategories"] as? [[String: Any]] ?? []).enumerated() {
            let collection = value["collection"] as? [String: Any] ?? [:]
            append("category-\(i)", collection["headingTitle"] as? String ?? "ITV programmes", collection["shows"] as? [[String: Any]] ?? [], (collection["headingLink"] as? [String: Any])?["href"] as? String)
        }
        // Collection pages use their own container rather than editorial rails.
        if rails.isEmpty {
            func visit(_ node: Any) {
                if let list = node as? [[String: Any]], list.contains(where: { show($0) != nil }) { append("collection-\(rails.count)", "All programmes", list, nil) }
                else if let dict = node as? [String: Any] { for key in dict.keys.sorted() where !["config", "navAdServerParams"].contains(key) { visit(dict[key]!) } }
                else if let list = node as? [Any] { list.forEach(visit) }
            }
            visit(props)
        }
        return rails
    }
    static func categories(_ props: [String: Any]) -> [ITVCategory] {
        ((props["subnav"] as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let title = $0["label"] as? String, let path = $0["url"] as? String,
                  path.hasPrefix("/watch/categories/") else { return nil }
            return ITVCategory(id: id, title: title, path: path)
        }
    }
    func details(_ show: CatalogueShow) async throws -> CatalogueShow {
        guard let url = show.providerURL, url.host == "www.itv.com" else { throw BBCError.message("This ITV programme has no catalogue address.") }
        return try Self.details(await page(url.path), fallback: show)
    }
    static func details(_ props: [String: Any], fallback: CatalogueShow, now: Date = Date()) throws -> CatalogueShow {
        guard let metadata = props["programme"] as? [String: Any] else { throw BBCError.message("ITV programme details are unavailable.") }
        var result = show(metadata) ?? fallback
        result.providerURL = fallback.providerURL; result.indexedAt = now
        result.singleEpisode = fallback.singleEpisode || ((props["seriesList"] as? [[String: Any]])?.first?["seriesType"] as? String == "FILM")
        var episodes = [CatalogueEpisode](), seen = Set<String>()
        let series = props["seriesList"] as? [[String: Any]] ?? []
        for (index, group) in series.enumerated() {
            let label = group["seriesLabel"] as? String ?? "Episodes"
            let slice = "itv:series:" + (group["legacyId"] as? String ?? String(index))
            for title in group["titles"] as? [[String: Any]] ?? [] {
                guard let episode = episode(title, show: result, slice: slice, label: label, now: now), seen.insert(episode.id).inserted else { continue }
                episodes.append(episode)
            }
        }
        if episodes.isEmpty, let value = props["episode"] as? [String: Any], let e = episode(value, show: result, slice: "episodes", label: "Episodes", now: now) { episodes = [e] }
        result.episodes = episodes; result.expectedEpisodes = episodes.count
        return result
    }
    static func episode(_ data: [String: Any], show: CatalogueShow, slice: String, label: String, now: Date) -> CatalogueEpisode? {
        if let end = data["availabilityUntil"] as? String, let date = ISO8601DateFormatter().date(from: end), date <= now { return nil }
        if let start = data["availabilityFrom"] as? String, let date = ISO8601DateFormatter().date(from: start), date > now { return nil }
        guard let id = data["productionId"] as? String ?? data["episodeId"] as? String,
              let raw = data["playlistUrl"] as? String, let playlist = URL(string: raw),
              playlist.scheme == "https", playlist.host == "magni.itv.com", playlist.path.hasPrefix("/playlist/itvonline/") else { return nil }
        let name = data["episodeTitle"] as? String ?? "Episode"
        let number = data["episode"] as? Int
        let subtitle = number.map { "Episode \($0) · \(name)" } ?? name
        var p = Programme(id: "itv:" + id, title: show.title, summary: (data["longDescription"] ?? data["description"]) as? String ?? "",
            image: image(data["image"] ?? data["imageUrl"]) ?? show.image, version: "", guidance: data["guidance"] as? String)
        p.showID = show.id; p.showTitle = show.title; p.episodeSubtitle = subtitle
        p.durationText = data["duration"] as? String; p.itvPlaylistURL = playlist
        p.firstBroadcastDateTime = data["broadcastDateTime"] as? String
        if let raw = p.firstBroadcastDateTime, let date = ISO8601DateFormatter().date(from: raw) { p.firstBroadcast = date.formatted(date: .abbreviated, time: .omitted) }
        p.premium = data["premium"] as? Bool ?? (data["tier"] as? [String]).map { !$0.contains("FREE") } ?? false
        return CatalogueEpisode(programme: p, subtitle: subtitle, duration: p.durationText ?? "", sliceID: slice,
            seriesTitle: label, parentPosition: number, broadcastDate: data["broadcastDateTime"] as? String)
    }
    func search(_ query: String) async throws -> [CatalogueShow] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        var parts = URLComponents(string: "https://textsearch.prd.oasvc.itv.com/search")!
        parts.queryItems = ["broadcaster":"itv", "featureSet":"hls,fairplay,hd", "onlyFree":"false", "platform":"dotcom", "query":query].map { URLQueryItem(name:$0.key,value:$0.value) }
        let data = try await fetch(parts.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = json["results"] as? [[String: Any]] else { throw BBCError.message("ITV search returned an unexpected response.") }
        var seen = Set<String>()
        return items.compactMap { ($0["data"] as? [String: Any]).flatMap(Self.show) }.filter { seen.insert($0.id).inserted }
    }
}
