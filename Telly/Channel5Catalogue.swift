// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct Channel5CatalogueAPI {
    var fetch: @Sendable (URL) async throws -> Data = { try await Channel5HTTP.shared.data($0) }
    /// A null season is the provider's standalone programme route, not a
    /// missing series to discard. Keep it alongside any numbered series.
    static func seasons(_ root: [String:Any], standalone: Bool) -> [String?] {
        let groups = root["seasons"] as? [[String:Any]] ?? []
        var result = [String?]()
        for group in groups {
            let raw = group["seasonNumber"]
            let value = (raw as? String) ?? (raw as? Int).map(String.init)
            if raw == nil || raw is NSNull || value == "" {
                if !result.contains(where: { $0 == nil }) { result.append(nil) }
            } else if let value, value.range(of:#"^[0-9]+$"#,options:.regularExpression) != nil, !result.contains(where: { $0 == value }) { result.append(value) }
        }
        if result.isEmpty && standalone { result.append(nil) }
        return result
    }
    static func episodesURL(showID: String, season: String?) throws -> URL {
        guard showID.range(of:#"^[0-9]+$"#,options:.regularExpression) != nil,
              season == nil || season!.range(of:#"^[0-9]+$"#,options:.regularExpression) != nil else { throw Channel5Error.message("Invalid Channel 5 programme series.") }
        let path = season.map { "/seasons/"+$0 } ?? ""
        return URL(string:"https://corona.channel5.com/shows/"+showID+path+"/episodes.json?platform=my5desktop&friendly=1")!
    }
    static let categories: [Genre] = [
        Genre(id:"drama",title:"Drama"), Genre(id:"films",title:"Films"), Genre(id:"entertainment",title:"Entertainment"),
        Genre(id:"documentaries",title:"Documentaries"), Genre(id:"crime",title:"Crime"), Genre(id:"history",title:"History"),
        Genre(id:"lifestyle",title:"Lifestyle"), Genre(id:"science-and-nature",title:"Science & Nature"), Genre(id:"sport",title:"Sport"),
        Genre(id:"travel",title:"Travel"), Genre(id:"news",title:"News"), Genre(id:"kids",title:"Kids")
    ]
    static func image(_ id: String, type: String, portrait: Bool = false) -> URL? {
        guard id.range(of:#"^[A-Za-z0-9-]+$"#,options:.regularExpression) != nil, ["show","episode","channel"].contains(type) else { return nil }
        return URL(string:"https://api-images.channel5.com/otis/images/\(type)/\(id)/\(portrait ? "400x600" : "640x360").jpg")
    }
    static func show(_ d: [String:Any]) -> CatalogueShow? {
        guard let id = d["id"] as? String, id.range(of:#"^[0-9]+$"#,options:.regularExpression) != nil, let title = d["title"] as? String, !title.isEmpty else { return nil }
        let genres = [d["primary_vod_genre"] as? String, d["genre"] as? String].compactMap { $0 } + (d["vod_subgenres"] as? [String] ?? [])
        var value = CatalogueShow(id:"c5:"+id,title:title,summary:d["m_desc"] as? String ?? d["s_desc"] as? String ?? "",image:image(id,type:"show"),letter:String(title.prefix(1)).lowercased(),channel:"Channel 5",categories:genres,expectedEpisodes:0,singleEpisode:d["standalone"] as? Bool == true,episodes:[])
        value.portraitImage = image(id,type:"show",portrait:true)
        if let slug = d["f_name"] as? String, slug.range(of:#"^[a-z0-9-]+$"#,options:.regularExpression) != nil { value.providerURL = URL(string:"https://www.channel5.com/show/"+slug) }
        return value
    }
    static func shows(_ data: Data) throws -> [CatalogueShow] {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any], let rows = root["shows"] as? [[String:Any]] else { throw Channel5Error.message("Channel 5's catalogue is unavailable.") }
        var seen = Set<String>()
        return rows.compactMap(show).filter { seen.insert($0.id).inserted }
    }
    static func belongs(_ show: CatalogueShow, category: String) -> Bool {
        let terms: [String:[String]] = ["drama":["drama","soaps"],"films":["movies","film"],"documentaries":["documentaries","documentary"],"entertainment":["entertainment"],"lifestyle":["lifestyle","real lives"],"crime":["crime","police"],"kids":["milkshake","children"],"news":["news","current affairs"],"science-and-nature":["science","nature"],"sport":["sport"],"travel":["travel"],"history":["history"]]
        return show.categories.contains { name in (terms[category] ?? [category]).contains { name.localizedCaseInsensitiveContains($0) } }
    }
    func all() async throws -> [CatalogueShow] {
        try Self.shows(await Channel5HTTP.shared.data(URL(string:"https://corona.channel5.com/shows/search.json?platform=my5desktop&friendly=1&limit=2000")!))
    }
    func search(_ text: String) async throws -> [CatalogueShow] {
        var u = URLComponents(string:"https://corona.channel5.com/shows/search.json")!
        u.queryItems = [URLQueryItem(name:"platform",value:"my5desktop"),URLQueryItem(name:"friendly",value:"1"),URLQueryItem(name:"query",value:String(text.prefix(160))),URLQueryItem(name:"limit",value:"120")]
        return try Self.shows(await Channel5HTTP.shared.data(u.url!))
    }
    static func episode(_ d: [String:Any], show: CatalogueShow, season: String, now: Date = Date()) -> CatalogueEpisode? {
        guard let id = d["id"] as? String, id.range(of:#"^[A-Za-z0-9-]+$"#,options:.regularExpression) != nil,
              let end = (d["vod_e"] as? NSNumber)?.doubleValue, end > now.timeIntervalSince1970,
              let start = (d["vod_s"] as? NSNumber)?.doubleValue, start <= now.timeIntervalSince1970 else { return nil }
        let title = d["title"] as? String ?? "Episode"
        let number = d["ep_num"] as? Int
        let standalone = show.singleEpisode || season.isEmpty
        let label = standalone ? show.title : number.map { "Episode \($0) · \(title)" } ?? title
        let milliseconds = (d["len"] as? NSNumber)?.doubleValue ?? 0
        let duration = milliseconds > 0 ? "\(Int((milliseconds/60000).rounded())) mins" : ""
        let guidance = [d["rat"] as? String,d["adv"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator:" · ")
        var p = Programme(id:"c5:"+id,title:show.title,summary:d["m_desc"] as? String ?? d["s_desc"] as? String ?? "",image:image(id,type:"episode") ?? show.image,version:"",guidance:guidance.isEmpty ? nil : guidance)
        p.showID = show.id; p.showTitle = show.title; p.episodeSubtitle = label; p.durationText = duration
        return CatalogueEpisode(programme:p,subtitle:label,duration:duration,sliceID:standalone ? "c5:standalone" : "c5:series:"+season,seriesTitle:standalone ? "Programme" : "Series "+season,parentPosition:number)
    }
    func details(_ original: CatalogueShow, now: Date = Date()) async throws -> CatalogueShow {
        let id = String(original.id.dropFirst(3))
        guard original.provider == .channel5, id.range(of:#"^[0-9]+$"#,options:.regularExpression) != nil else { throw Channel5Error.message("Invalid Channel 5 programme.") }
        let base = "https://corona.channel5.com/shows/"+id
        async let info = fetch(URL(string:base+".json?platform=my5desktop&friendly=1")!)
        async let series = fetch(URL(string:base+"/seasons.json?platform=my5desktop")!)
        let (a,b) = try await (info,series)
        let dict = try JSONSerialization.jsonObject(with:a) as? [String:Any] ?? [:]
        var value = Self.show(dict) ?? original
        value.singleEpisode = value.singleEpisode || original.singleEpisode
        let seasons = Self.seasons(try JSONSerialization.jsonObject(with:b) as? [String:Any] ?? [:], standalone:value.singleEpisode)
        let resolvedShow = value
        let batches = try await withThrowingTaskGroup(of:(Int,[CatalogueEpisode]).self) { group in
            for (index,season) in seasons.enumerated() {
                group.addTask {
                    let data = try await fetch(Self.episodesURL(showID:id,season:season))
                    let rows = (try JSONSerialization.jsonObject(with:data) as? [String:Any])?["episodes"] as? [[String:Any]] ?? []
                    return (index,rows.compactMap { Self.episode($0,show:resolvedShow,season:season ?? "",now:now) })
                }
            }
            var result = [(Int,[CatalogueEpisode])]()
            for try await batch in group { result.append(batch) }
            return result.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        }
        try Task.checkCancellation()
        var seen = Set<String>(); value.episodes = batches.filter { seen.insert($0.id).inserted }
        value.expectedEpisodes = value.episodes.count; value.indexedAt = Date(); return value
    }
    static var liveSeed: [LiveChannel] { [("C5","Channel 5"),("C7","5USA"),("C6","5STAR"),("C0","5ACTION"),("C8","5Drama")].map { LiveChannel(id:"c5:"+$0.0,title:$0.1,logo:image($0.0,type:"channel")) } }
    static func channels(_ data: Data) throws -> [LiveChannel] {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any], let rows = (root["filters"] as? [String:Any])?["contents"] as? [[String:Any]] else { throw Channel5Error.message("Channel 5's live listings are unavailable.") }
        var seen = Set<String>()
        return rows.compactMap { d in
            guard d["live"] as? Bool == true, let id = d["channel"] as? String, id.range(of:#"^[A-Za-z0-9-]+$"#,options:.regularExpression) != nil, seen.insert(id).inserted, let title = d["title"] as? String else { return nil }
            return LiveChannel(id:"c5:"+id,title:title,logo:image(id,type:"channel"))
        }
    }
    func live(shows: [CatalogueShow] = []) async throws -> [LiveChannel] {
        let list = try Self.channels(await Channel5HTTP.shared.data(URL(string:"https://feeds-api.channel5.com/collections/PLC_5LiveTVPageSubNav/concise.json?vod_available=my5desktop")!))
        return await withTaskGroup(of:(Int,LiveChannel).self) { group in
            for (i,original) in list.enumerated() {
                group.addTask {
                    var channel = original
                    let id = String(channel.id.dropFirst(3))
                    if let raw = try? await Channel5HTTP.shared.data(URL(string:"https://feeds-api.channel5.com/feed/now-next/\(id).json")!),
                       let root = try? JSONSerialization.jsonObject(with:raw) as? [String:Any], let schedule = root["schedule"] as? [[String:Any]] {
                        let now = Date().timeIntervalSince1970
                        let ordered = schedule.sorted { ($0["tran_s"] as? Double ?? 0) < ($1["tran_s"] as? Double ?? 0) }
                        if let index = ordered.lastIndex(where: { ($0["tran_s"] as? Double ?? .infinity) <= now }), index+1 < ordered.count,
                           let title = ordered[index]["title"] as? String, let end = ordered[index+1]["tran_s"] as? Double, end > now {
                            let art = shows.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }?.image
                            channel.current = LiveProgramme(title:title,subtitle:"",image:art,end:Date(timeIntervalSince1970:end))
                        }
                    }
                    return (i,channel)
                }
            }
            var result = [(Int,LiveChannel)](); for await x in group { result.append(x) }
            return result.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}
