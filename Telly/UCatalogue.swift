// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct UCatalogueAPI {
    var fetch: @Sendable (URL) async throws -> Data = { url in
        guard url.scheme == "https", url.host == "cfschedules.uktv.co.uk", url.path.hasPrefix("/vod/") else {
            throw BBCError.message("Invalid U catalogue address.")
        }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("apple", forHTTPHeaderField: "Platform-Type")
        request.setValue("appletv", forHTTPHeaderField: "Platform-Name")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == url.host, data.count < 8_000_000 else {
            throw BBCError.message("U’s catalogue could not be loaded. Please retry.")
        }
        return data
    }
    static let genres: [Genre] = [
        Genre(id:"comedy",title:"Comedy"), Genre(id:"drama",title:"Drama"),
        Genre(id:"documentaries",title:"Documentaries"), Genre(id:"lifestyle",title:"Lifestyle"),
        Genre(id:"real-life",title:"Real Life"), Genre(id:"entertainment",title:"Entertainment"),
        Genre(id:"films",title:"Films"), Genre(id:"music",title:"Music"), Genre(id:"food",title:"Food"),
        Genre(id:"history",title:"History"), Genre(id:"science-and-nature",title:"Science & Nature"),
        Genre(id:"travel",title:"Travel"), Genre(id:"crime",title:"Crime")
    ]
    static func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var url = URLComponents(string:"https://cfschedules.uktv.co.uk/vod/" + path + "/")!
        url.queryItems = query.isEmpty ? nil : query
        return url.url!
    }
    static func validSlug(_ value: String) -> Bool {
        value.range(of:#"^[a-z0-9]+(?:-[a-z0-9]+)*$"#,options:.regularExpression) != nil
    }
    static func stringID(_ value: Any?) -> String? {
        let s = (value as? String) ?? (value as? NSNumber)?.stringValue
        return s.flatMap { $0.range(of:#"^[0-9]{1,20}$"#,options:.regularExpression) != nil ? $0 : nil }
    }
    static func image(_ raw: Any?, portrait: Bool = false) -> URL? {
        guard let s = raw as? String, let url = URL(string:s), url.scheme == "https", url.host == "uktv-res.cloudinary.com" else { return nil }
        // U's private originals often return 404. Use the same published named
        // derivatives as its website, which also keep card downloads small.
        if url.path.contains("/t_") { return url }
        let name = portrait ? "t_web_30_showcard_portrait_l_2x_jpg" : "t_web_30_showcard_horizontal_l_2x_jpg"
        guard url.path.hasPrefix("/image/private/") || url.path.hasPrefix("/image/upload/") else { return nil }
        let delivery = url.path.hasPrefix("/image/private/") ? "private" : "upload"
        return URL(string:s.replacingOccurrences(of:"/image/\(delivery)/",with:"/image/\(delivery)/\(name)/"))
    }
    static func directory(_ data: Data) throws -> [Int:[String]] {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any], let rows = root["categories"] as? [[String:Any]], !rows.isEmpty else {
            throw BBCError.message("U’s category list has changed. Showing the saved catalogue.")
        }
        var map = [Int:[String]]()
        for row in rows {
            guard let parent = row["slug"] as? String else { continue }
            for sub in row["subcategories"] as? [[String:Any]] ?? [] {
                if let id = sub["id"] as? Int, let slug = sub["slug"] as? String {
                    map[id,default:[]] += ["category:" + parent, "topic:" + slug.lowercased()]
                }
            }
        }
        return map
    }
    static func show(_ row: [String:Any], directory: [Int:[String]]) -> CatalogueShow? {
        guard let id = stringID(row["id"]), let title = row["name"] as? String, !title.isEmpty,
              let slug = row["slug"] as? String, validSlug(slug) else { return nil }
        var tags = (row["subcategories"] as? [Int] ?? []).flatMap { directory[$0] ?? [] }
        if let parent = row["primary_category"] as? String { tags.append("category:" + parent.lowercased().replacingOccurrences(of:" ",with:"-")) }
        if row["has_audio_description"] as? Bool == true { tags.append("audio-described") }
        var value = CatalogueShow(id:"u:" + id,title:title,
            summary:row["synopsis_long"] as? String ?? "",image:image(row["image"]),
            letter:String(title.prefix(1)).lowercased(),channel:"U",categories:Array(Set(tags)).sorted(),
            expectedEpisodes:row["available_episodes"] as? Int ?? 0,singleEpisode:row["is_feature"] as? Bool == true,episodes:[])
        if value.summary.isEmpty { value.summary = row["medium_description"] as? String ?? row["description"] as? String ?? "" }
        value.portraitImage = image(row["portrait_image"],portrait:true)
        value.providerURL = URL(string:"https://u.co.uk/shows/" + slug + "/watch-online")
        return value
    }
    static func shows(_ data: Data, directory: [Int:[String]]) throws -> [CatalogueShow] {
        guard let rows = try JSONSerialization.jsonObject(with:data) as? [[String:Any]], !rows.isEmpty else {
            throw BBCError.message("U’s programme list has changed. Showing the saved catalogue.")
        }
        var seen = Set<String>()
        return rows.compactMap { show($0,directory:directory) }.filter { $0.expectedEpisodes > 0 && seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    static func belongs(_ show: CatalogueShow, genre: String) -> Bool {
        let tags: [String]
        switch genre {
        case "films": tags = ["topic:movies"]
        case "music", "food", "travel": tags = ["topic:" + genre]
        case "history": tags = ["topic:history", "topic:military-war"]
        case "science-and-nature": tags = ["topic:natural-history", "topic:engineering"]
        case "crime": tags = ["topic:true-crime", "topic:crime-drama"]
        case "audio-described": tags = ["audio-described"]
        default: tags = ["category:" + genre]
        }
        return show.categories.contains { tags.contains($0) }
    }
    func all() async throws -> [CatalogueShow] {
        async let categories = fetch(Self.url("categories"))
        async let brands = fetch(Self.url("brand_list"))
        let (categoryData,brandData) = try await (categories,brands)
        let result = try Self.shows(brandData,directory:Self.directory(categoryData))
        guard !result.isEmpty else { throw BBCError.message("U returned no programme listings.") }
        return result
    }
    static func episode(_ row: [String:Any], show: CatalogueShow, series: String, now: Date) -> CatalogueEpisode? {
        guard let id = stringID(row["video_id"]) else { return nil }
        let epoch = now.timeIntervalSince1970
        if let start = row["available_start_unix"] as? Double, start > epoch { return nil }
        if let end = row["available_end_unix"] as? Double, end <= epoch { return nil }
        let number = (row["episode_number"] as? Int).map { "Episode \($0)" } ?? "Episode"
        let title = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (show.singleEpisode ? show.title : number)
        let minutes = (row["content_duration"] as? Int ?? 0) / 60
        var programme = Programme(id:"u:" + id,title:show.title + " — " + title,
            summary:row["synopsis"] as? String ?? "",image:image(row["image"]) ?? show.image,
            version:id,guidance:row["guidance_text"] as? String)
        programme.showID = show.id; programme.showTitle = show.title; programme.episodeSubtitle = title
        programme.durationText = minutes > 0 ? "\(minutes) min" : ""
        return CatalogueEpisode(programme:programme,subtitle:title,duration:programme.durationText ?? "",
            sliceID:stringID(row["series_id"]) ?? "episodes",seriesTitle:series,
            parentPosition:row["episode_number"] as? Int,broadcastDate:row["available_start"] as? String)
    }
    func details(_ original: CatalogueShow, now: Date = Date()) async throws -> CatalogueShow {
        guard original.provider == .u, let url = original.providerURL, url.scheme == "https", url.host == "u.co.uk",
              url.pathComponents.count == 4, Self.validSlug(url.pathComponents[2]) else { throw BBCError.message("Invalid U programme.") }
        let data = try await fetch(Self.url("brand",[URLQueryItem(name:"slug",value:url.pathComponents[2])]))
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Self.stringID(root["id"]).map({ "u:" + $0 }) == original.id else { throw BBCError.message("U returned an unexpected programme.") }
        let groups = root["series"] as? [[String:Any]] ?? []
        var updated = original
        let description = root["synopsis_long"] as? String ?? ""
        if !description.isEmpty { updated.summary = description }
        let batches = try await withThrowingTaskGroup(of:[CatalogueEpisode].self) { group in
            var next = 0, result = [CatalogueEpisode]()
            func enqueue(_ item: [String:Any]) {
                group.addTask {
                    guard let id = Self.stringID(item["id"]) else { throw BBCError.message("U returned an invalid series.") }
                    let raw = try await fetch(Self.url("series",[URLQueryItem(name:"id",value:id)]))
                    guard let series = try JSONSerialization.jsonObject(with:raw) as? [String:Any], Self.stringID(series["id"]) == id,
                          let parent = series["brand"] as? [String:Any], Self.stringID(parent["id"]).map({ "u:" + $0 }) == original.id,
                          let rows = series["episodes"] as? [[String:Any]] else { throw BBCError.message("U’s episode list could not be loaded.") }
                    let number = (item["number"] as? String) ?? (item["number"] as? Int).map(String.init) ?? ""
                    let label = number.isEmpty || number == "0" ? "Episodes" : "Series " + number
                    return rows.compactMap { Self.episode($0,show:original,series:label,now:now) }
                }
            }
            while next < min(4,groups.count) { enqueue(groups[next]); next += 1 }
            while let episodes = try await group.next() {
                result += episodes
                if next < groups.count { enqueue(groups[next]); next += 1 }
            }
            return result
        }
        var seen = Set<String>()
        updated.episodes = batches.filter { seen.insert($0.id).inserted }.sorted {
            if $0.sliceID != $1.sliceID { return $0.sliceID.localizedStandardCompare($1.sliceID) == .orderedAscending }
            return ($0.parentPosition ?? 0) < ($1.parentPosition ?? 0)
        }
        // Some films/specials only have a landing episode, without a series.
        if groups.isEmpty, let row = root["landing_episode"] as? [String:Any], let episode = Self.episode(row,show:updated,series:"Episodes",now:now) { updated.episodes = [episode] }
        updated.expectedEpisodes = updated.episodes.count; updated.indexedAt = now
        return updated
    }
}

/// Catalogue decoding and episode assembly stay off the UI executor.
actor UCatalogueClient {
    private let api = UCatalogueAPI()
    func all() async throws -> [CatalogueShow] { try await api.all() }
    func details(_ show: CatalogueShow) async throws -> CatalogueShow { try await api.details(show) }
}
