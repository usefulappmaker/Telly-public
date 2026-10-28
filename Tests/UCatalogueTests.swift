import Foundation

@main struct UCatalogueTests {
    static func data(_ path: String) throws -> Data { try Data(contentsOf:URL(fileURLWithPath:path)) }
    static func main() async throws {
        let directory = try UCatalogueAPI.directory(data("Telly/UCategorySeed.json"))
        let seed = try data("Telly/USeed.json")
        let shows = try UCatalogueAPI.shows(seed,directory:directory)
        precondition(shows.count == 650 && Set(shows.map(\.id)).count == 650)
        precondition(shows.allSatisfy { $0.provider == .u && $0.providerURL?.host == "u.co.uk" && !$0.categories.isEmpty })
        precondition(ContentProvider.of("u:6406235534112") == .u && ContentProvider.of("c5:123") == .channel5)
        precondition(shows.contains { $0.title == "Parks and Recreation" && UCatalogueAPI.belongs($0,genre:"comedy") })
        precondition(shows.contains { $0.title == "Miss Scarlet" && UCatalogueAPI.belongs($0,genre:"drama") })
        precondition(UCatalogueAPI.image("https://example.com/image.jpg") == nil)
        let derivative = UCatalogueAPI.image("https://uktv-res.cloudinary.com/image/private/v123/programme.jpg")!
        precondition(derivative.path.contains("/t_web_30_showcard_horizontal_l_2x_jpg/"))
        precondition(UCatalogueAPI.image(derivative.absoluteString) == derivative)
        precondition(UCatalogueAPI.image("https://uktv-res.cloudinary.com/image/private/v123/programme.jpg",portrait:true)!.path.contains("showcard_portrait"))
        precondition(!UCatalogueAPI.validSlug("../secret") && !UCatalogueAPI.validSlug("a?query=b"))
        let bbc = try JSONDecoder().decode([Genre].self,from:data("Telly/BBCGenreSeed.json"))
        let baseline = UnifiedCategory.make(bbc:bbc,itv:[])
        let merged = UnifiedCategory.make(bbc:bbc,itv:[],u:UCatalogueAPI.genres)
        let additions = Set(merged.map(\.id)).subtracting(baseline.map(\.id))
        precondition(additions == ["travel","crime"], "Only topics already supplied by Channel 5 are additional to the BBC list")
        let docs = merged.first { $0.id == "documentaries-lifestyle" }!
        precondition(Set(docs.u.map(\.id)) == ["documentaries","lifestyle","real-life"])
        precondition(merged.first { $0.id == "comedy" }!.providers == [.bbc,.u])
        precondition(merged.filter { !$0.u.isEmpty }.count == 11)
        let brand = try data("Tests/Fixtures/U/Brand.json"), series = try data("Tests/Fixtures/U/Series.json")
        let show = shows.first { $0.title == "Miss Scarlet" }!
        let api = UCatalogueAPI(fetch: { url in
            switch url.path {
            case "/vod/brand": return brand
            case "/vod/series": return series
            default: throw BBCError.message("Unexpected request")
            }
        })
        let now = Date(timeIntervalSince1970:1793100000)
        let details = try await api.details(show,now:now)
        precondition(details.episodes.count == 6 && details.series.count == 1)
        precondition(details.episodes.first?.programme.id == "u:6406235534112")
        precondition(details.episodes.first?.programme.showID == show.id)
        precondition(details.episodes.first?.seriesTitle == "Series 5")
        let episode = (try JSONSerialization.jsonObject(with:series) as! [String:Any])["episodes"] as! [[String:Any]]
        var expired = episode[0]; expired["available_end_unix"] = now.timeIntervalSince1970 - 1
        precondition(UCatalogueAPI.episode(expired,show:show,series:"Episodes",now:now) == nil)
        var future = episode[0]; future["available_start_unix"] = now.timeIntervalSince1970 + 1
        precondition(UCatalogueAPI.episode(future,show:show,series:"Episodes",now:now) == nil)
        var standalone = try JSONSerialization.jsonObject(with:brand) as! [String:Any]
        standalone["series"] = []; standalone["is_feature"] = true
        let standaloneData = try JSONSerialization.data(withJSONObject:standalone)
        let standaloneAPI = UCatalogueAPI(fetch: { _ in standaloneData })
        let special = try await standaloneAPI.details(show,now:now)
        precondition(special.episodes.count == 1, "One-off/landing episodes remain reachable")
        var duplicate = try JSONSerialization.jsonObject(with:series) as! [String:Any]
        duplicate["episodes"] = episode + episode
        let duplicateData = try JSONSerialization.data(withJSONObject:duplicate)
        let duplicateAPI = UCatalogueAPI(fetch: { $0.path == "/vod/brand" ? brand : duplicateData })
        let deduplicated = try await duplicateAPI.details(show,now:now)
        precondition(deduplicated.episodes.count == 6)
        do {
            _ = try await UCatalogueAPI(fetch: { _ in Data("{}".utf8) }).details(show)
            fatalError("Malformed metadata must fail visibly")
        } catch { }
        for genre in UCatalogueAPI.genres {
            print("\(genre.title): \(shows.filter { UCatalogueAPI.belongs($0,genre:genre.id) }.count)")
        }
        print("PASS: U provider identity, 650 programmes, category merging, series/episode metadata, standalone fallback, availability, deduplication, malformed responses and safe URLs")
        if CommandLine.arguments.contains("--network") {
            let current = try await UCatalogueAPI().all()
            precondition(!current.isEmpty)
            for title in ["Parks and Recreation", "Miss Scarlet", "Bangers & Cash: Restoring Classics"] {
                let example = current.first { $0.title == title }!
                let result = try await UCatalogueAPI().details(example)
                precondition(!result.episodes.isEmpty)
                print("LIVE catalogue: \(title), \(result.series.count) series, \(result.episodes.count) episodes")
            }
        }
    }
}
