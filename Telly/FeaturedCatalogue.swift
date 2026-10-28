// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Editorial selections retain their broadcaster's order; no cross-network ratings are inferred.
struct FeaturedCatalogue {
    static let providers: [ContentProvider] = [.bbc,.itv,.channel4,.channel5,.u]
    static func feature(_ show: CatalogueShow, image: URL? = nil, synopsis: String? = nil) -> HomeFeature {
        HomeFeature(show:show,headline:show.title,synopsis:synopsis ?? show.summary,image:image ?? show.image)
    }
    static func mix(_ sources: [ContentProvider:[HomeFeature]]) -> [HomeFeature] {
        var result = [HomeFeature](), seen = Set<String>()
        let lists = providers.map { provider in
            (sources[provider] ?? []).filter {
                $0.show.provider == provider && $0.image?.scheme == "https" && $0.show.premium != true &&
                $0.show.providerURL?.path.contains("/collections/") != true
            }.filter { seen.insert($0.id).inserted }.prefix(2)
        }
        for position in 0..<2 { for list in lists where position < list.count { result.append(Array(list)[position]) } }
        return result
    }
    /// Decode Next flight frames as data, never execute a site's JavaScript.
    static func uRails(_ data: Data) -> [[String:Any]] {
        let html = String(decoding:data,as:UTF8.self)
        guard let regex = try? NSRegularExpression(pattern:#"self\.__next_f\.push\((\[.*?\])\)</script>"#,options:.dotMatchesLineSeparators) else { return [] }
        var stream = ""
        for match in regex.matches(in:html,range:NSRange(html.startIndex...,in:html)) {
            guard let range = Range(match.range(at:1),in:html), let raw = html[range].data(using:.utf8),
                  let values = try? JSONSerialization.jsonObject(with:raw) as? [Any], values.first as? Int == 1,
                  let fragment = values.last as? String else { continue }
            stream += fragment
        }
        var rails = [[String:Any]]()
        func visit(_ node: Any) {
            if let d = node as? [String:Any] {
                if d["header"] is String, d["items"] is [[String:Any]] { rails.append(d) }
                for key in d.keys.sorted() { visit(d[key]!) }
            } else if let a = node as? [Any] { a.forEach(visit) }
        }
        for line in stream.split(separator:"\n") {
            guard let colon = line.firstIndex(of:":"), let raw = String(line[line.index(after:colon)...]).data(using:.utf8),
                  let root = try? JSONSerialization.jsonObject(with:raw,options:.fragmentsAllowed) else { continue }
            visit(root)
        }
        return rails
    }
    static func uFeatures(_ data: Data, known: [CatalogueShow]) -> [HomeFeature] {
        let rails = uRails(data)
        let rows = rails.first { ($0["header"] as? String)?.hasPrefix("Top Series to Stream") == true }?["items"] as? [[String:Any]] ??
            rails.first { $0["header"] as? String == "Top 10 This Week" }?["items"] as? [[String:Any]] ?? []
        return rows.compactMap { row in
            let brand = row["linked_brand"] as? [String:Any] ?? row
            guard let id = UCatalogueAPI.stringID(brand["id"]) else { return nil }
            let show = known.first { $0.id == "u:" + id } ?? UCatalogueAPI.show(brand,directory:[:])
            guard let show, show.expectedEpisodes > 0 else { return nil }
            return feature(show,image:UCatalogueAPI.image(row["hero_image_4k"] ?? row["image"] ?? brand["hero_image_4k"]),synopsis:row["subtitle"] as? String)
        }
    }
    static func channel5IDs(_ data: Data) throws -> [String] {
        let root = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
        let filters = root["filters"] as? [String:Any] ?? [:]
        return Array((filters["ids"] as? [String] ?? []).filter { $0.range(of:#"^[A-Za-z0-9-]+$"#,options:.regularExpression) != nil }.prefix(12))
    }
    static func channel5Features(_ data: Data, order: [String], known: [CatalogueShow], now: Date = Date()) throws -> [HomeFeature] {
        let root = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
        let rows = root["watchables"] as? [[String:Any]] ?? []
        return order.compactMap { id in
            guard let row = rows.first(where: { $0["id"] as? String == id }),
                  let start = row["vod_s"] as? Double, let end = row["vod_e"] as? Double,
                  start <= now.timeIntervalSince1970, end > now.timeIntervalSince1970,
                  let showID = row["sh_id"] as? String, let title = row["sh_title"] as? String else { return nil }
            var metadata: [String:Any] = ["id":showID,"title":title,"s_desc":row["s_desc"] as? String ?? ""]
            metadata["f_name"] = row["sh_f_name"]
            guard let show = known.first(where: { $0.id == "c5:" + showID }) ?? Channel5CatalogueAPI.show(metadata) else { return nil }
            return feature(show,image:Channel5CatalogueAPI.image(id,type:"episode"))
        }
    }
}

/// All fetching and parsing happens off the UI executor; only public catalogue metadata is used.
actor FeaturedCatalogueClient {
    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https", ["u.co.uk","feeds-api.channel5.com","corona.channel5.com","www.channel4.com"].contains(url.host ?? "") else { throw URLError(.badURL) }
        var request = URLRequest(url:url); request.timeoutInterval = 15
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == url.host, data.count < 8_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
    func u(_ known: [CatalogueShow]) async throws -> [HomeFeature] {
        FeaturedCatalogue.uFeatures(try await fetch(URL(string:"https://u.co.uk/")!),known:known)
    }
    func channel5(_ known: [CatalogueShow]) async throws -> [HomeFeature] {
        let data = try await fetch(URL(string:"https://feeds-api.channel5.com/collections/PLC_My5AppleTVFeaturedRail/concise.json?vod_available=appletv")!)
        let ids = try FeaturedCatalogue.channel5IDs(data)
        guard !ids.isEmpty else { return [] }
        var url = URLComponents(string:"https://corona.channel5.com/watchables/search.json")!
        url.queryItems = [URLQueryItem(name:"platform",value:"appletv"),URLQueryItem(name:"friendly",value:"1")] + ids.map { URLQueryItem(name:"ids[]",value:$0) }
        return try FeaturedCatalogue.channel5Features(await fetch(url.url!),order:ids,known:known)
    }
}

struct HomepageRail: Identifiable {
    let id: String
    let provider: ContentProvider
    let title: String
    let shows: [CatalogueShow]
    var posters = false
    var more: String? = nil
}
/// Show each available network once before taking its next row. Preserve each
/// network's own order, and never repeat rows merely to fill an empty slot.
enum HomepageRows {
    static func interleave(_ groups: [ContentProvider:[HomepageRail]]) -> [HomepageRail] {
        let lists = FeaturedCatalogue.providers.map { (groups[$0] ?? []).filter { !$0.shows.isEmpty } }
        var result = [HomepageRail]()
        for position in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where position < list.count { result.append(list[position]) }
        }
        return result
    }
    static func make(bbc: [HomeRow], itv: [ITVRail], channel4: [CatalogueShow], channel4All: [CatalogueShow],
                     channel5: [CatalogueShow], channel5All: [CatalogueShow], u: [CatalogueShow], uAll: [CatalogueShow]) -> [HomepageRail] {
        func rail(_ provider: ContentProvider,_ id: String,_ title: String,_ shows: [CatalogueShow]) -> HomepageRail {
            var seen = Set<String>()
            return HomepageRail(id:provider.rawValue + ":" + id,provider:provider,title:title,
                shows:Array(shows.filter { seen.insert($0.id).inserted }.prefix(20)))
        }
        let bbcRows = bbc.enumerated().map { index,row in
            HomepageRail(id:"bbc:" + row.id,provider:.bbc,title:index == 0 ? "Discover BBC" : row.title,
                shows:row.shows,posters:row.usesPosters)
        }
        let itvRows = itv.prefix(4).enumerated().map { index,row in
            HomepageRail(id:"itv:" + row.id,provider:.itv,title:index == 0 ? "Discover ITV" : row.title,shows:row.shows,more:row.more)
        }
        let c4Rows = [rail(.channel4,"discover","Discover Channel 4",channel4)] +
            [("comedy","Comedy on Channel 4"),("drama","Drama on Channel 4")].map { genre,title in
                rail(.channel4,genre,title,channel4All.filter { show in show.categories.contains { $0.localizedCaseInsensitiveContains(genre) } })
            }
        let c5Rows = [rail(.channel5,"discover","Explore Channel 5",channel5)] +
            [("drama","Drama on Channel 5"),("documentaries","Documentaries on Channel 5"),("films","Films on Channel 5")].map { genre,title in
                rail(.channel5,genre,title,channel5All.filter { Channel5CatalogueAPI.belongs($0,category:genre) })
            }
        let uRows = [rail(.u,"comedy","Comedy on U",u)] +
            [("drama","Drama on U"),("documentaries","Documentaries on U")].map { genre,title in
                rail(.u,genre,title,uAll.filter { UCatalogueAPI.belongs($0,genre:genre) })
            }
        return interleave([.bbc:bbcRows,.itv:itvRows,.channel4:c4Rows,.channel5:c5Rows,.u:uRows])
    }
}
