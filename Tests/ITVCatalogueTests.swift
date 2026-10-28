import Foundation
func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
@main struct ITVCatalogueTests {
    static func main() async throws {
        let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: [String: Any]]
        let home = ITVCatalogueAPI.rails(seed["/"]!)
        check(home.count > 5, "Homepage contains editorial rails")
        let shows = home.flatMap(\.shows)
        check(shows.allSatisfy { $0.provider == .itv && $0.providerURL?.host == "www.itv.com" }, "ITV identities and detail URLs are provider-specific")
        check(shows.allSatisfy { !($0.image?.absoluteString.contains("{") ?? false) }, "Image templates are fully resolved")
        let page = seed["/watch/the-way-home/10a8290"]!
        let now = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
        let summary = ITVCatalogueAPI.show(page["programme"] as! [String: Any])!
        let show = try ITVCatalogueAPI.details(page, fallback: summary, now: now)
        check(show.episodes.count == 40 && show.series.count == 4, "All four series and forty episodes are retained")
        let first = show.episodes[0]
        check(first.programme.itvPlaylistURL?.lastPathComponent == "10_8290_0001.001", "Each episode retains its actual playlist endpoint")
        check(first.programme.showID == show.id && first.programme.provider == .itv, "Episode retains provider and programme relationship")
        check(first.programme.episodeSubtitle?.contains("Mothers and Daughters") == true, "Episode name is retained")
        check(EpisodeSequence.next(after: first, in: show)?.id == show.episodes[1].id, "Up next follows episode order")
        let expired = try ITVCatalogueAPI.details(page, fallback: summary, now: now.addingTimeInterval(2*365*86400))
        check(expired.episodes.isEmpty, "Expired episode metadata cannot create playable episode rows")
        let html = "<html><script nonce='test' type='application/json' id='__NEXT_DATA__'>" + String(decoding: try JSONSerialization.data(withJSONObject: ["props":["pageProps":page]]), as: UTF8.self) + "</script></html>"
        let parsed = try ITVCatalogueAPI.props(Data(html.utf8))
        check(parsed["programme"] != nil, "Page metadata extraction handles arbitrary script attribute order")
        for raw in ["<html>No metadata</html>", "<script id='__NEXT_DATA__'>{broken}</script>"] {
            do { _ = try ITVCatalogueAPI.props(Data(raw.utf8)); preconditionFailure("Malformed page accepted") } catch {}
        }
        for path in ["https://evil.example/x", "//evil.example/x"] {
            do { _ = try ITVCatalogueAPI.pageURL(path); preconditionFailure("Unsafe path accepted") } catch {}
        }
        let filmCategory = seed["/watch/categories/films"]!
        let twilight = ITVCatalogueAPI.rails(filmCategory).flatMap(\.shows).first { $0.id == "itv:7s8VA28o6BGW0fkkddmaWQ" }!
        let collectionPath = "/watch/collections/the-twilight-saga/7s8VA28o6BGW0fkkddmaWQ"
        check(twilight.title == "The Twilight Saga" && !twilight.singleEpisode, "Collection cards retain clean titles and are not films")
        check(ITVCatalogueAPI.collectionPath(twilight) == collectionPath, "Twilight opens the collection address")
        var oldTwilight = twilight
        oldTwilight.providerURL = URL(string: "https://www.itv.com/watch/the-twilight-saga/7s8VA28o6BGW0fkkddmaWQ")
        check(ITVCatalogueAPI.collectionPath(oldTwilight) == collectionPath && oldTwilight.id == twilight.id, "Previously saved collection routes are repaired without changing identity")
        var collectionCard: [String: Any] = ["contentType": "collection", "collectionId": "XYZ12345678901234567", "title": "Another collection", "titleSlug": "another-collection"]
        check(ITVCatalogueAPI.show(collectionCard)?.providerURL?.path == "/watch/collections/another-collection/XYZ12345678901234567", "Collection IDs need no programme ID or letter a")
        collectionCard["collectionId"] = "../bad"
        check(ITVCatalogueAPI.show(collectionCard) == nil, "Invalid collection IDs cannot create a route")
        var collection = seed[collectionPath]!
        let members = ITVCatalogueAPI.rails(collection).flatMap(\.shows)
        check(members.count == 54, "All available titles in ITV's actual Twilight collection are retained")
        check(members.prefix(5).map(\.title) == ["Twilight", "The Twilight Saga: New Moon", "The Twilight Saga: Eclipse", "Twilight Saga: Breaking Dawn Part 1", "Twilight Saga: Breaking Dawn Part 2"], "All five Twilight films retain ITV's order")
        check(members.prefix(5).allSatisfy { $0.singleEpisode && ITVCatalogueAPI.collectionPath($0) == nil }, "Collection children open film details, not another collection")
        collection["editorialSliders"] = [["header": ["title": "Recommendations"], "items": [page["programme"]!]]]
        check(ITVCatalogueAPI.rails(collection).flatMap(\.shows).map(\.id) == members.map(\.id), "Recommendation rails cannot replace or mix into collection contents")
        let film = try ITVCatalogueAPI.details(seed["/watch/twilight/10a6602a0001B"]!, fallback: members[0], now: now)
        check(film.singleEpisode && film.episodes.count == 1 && film.episodes[0].programme.itvPlaylistURL != nil, "Twilight film opens its playable film entry")
        check(ITVCatalogueAPI.collectionPath(summary) == nil, "Normal programme routing is unchanged")
        var emptyCollection = collection["collection"] as! [String: Any]
        emptyCollection["shows"] = [[String: Any]](); collection["collection"] = emptyCollection
        check(ITVCatalogueAPI.rails(collection).isEmpty, "Empty collection does not silently show recommendations")
        let categories = ITVCatalogueAPI.categories(seed["/watch/categories/drama-soaps"]!)
        check(categories.contains { $0.id == "films" } && categories.contains { $0.id == "comedy" }, "Categories come from ITV navigation")
        var badPage = page
        var series = badPage["seriesList"] as! [[String: Any]]
        var titles = series[0]["titles"] as! [[String: Any]]
        titles[0]["playlistUrl"] = "https://evil.example/playlist"
        series[0]["titles"] = titles; badPage["seriesList"] = series
        let filtered = try ITVCatalogueAPI.details(badPage, fallback: summary, now: now)
        check(filtered.episodes.count == 39, "Unexpected playlist hosts are rejected")
        let defaults = UserDefaults(suiteName: "TellyITVCatalogueFixture")!; defaults.removePersistentDomain(forName: "TellyITVCatalogueFixture")
        let history = WatchHistory(defaults: defaults)
        history.update(episode: first, show: show, next: show.episodes[1], position: 120, duration: 2414)
        let savedPosition = history.resumePosition(for: first.id)
        check(savedPosition == 120, "ITV resume uses the namespaced episode ID")
        let library = Library(defaults: defaults); library.save(show)
        let saved = library.saved
        check(saved.first?.providerURL == show.providerURL && saved.first?.id == "itv:10a8290", "Saved retains the ITV programme route")
        let original = Programme(id: "b0000001", title: "BBC fixture", summary: "", image: nil, version: "v0000001", guidance: nil)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "premium"); legacy.removeValue(forKey: "itvPlaylistURL")
        let decoded = try JSONDecoder().decode(Programme.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.provider == .bbc && decoded.itvPlaylistURL == nil, "Old BBC records decode and remain BBC")
        let searchData = try JSONSerialization.data(withJSONObject: ["results": [["data": ["programmeTitle":"The Way Home", "legacyId":["apiEncoded":"10_8290"], "tier":"FREE"]]]])
        let api = ITVCatalogueAPI(fetch: { url in
            check(url.host == "textsearch.prd.oasvc.itv.com", "Search uses the ITV search endpoint")
            check(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "query"})?.value == "The Way Home", "Search query is correctly encoded")
            return searchData
        })
        let matches = try await api.search("The Way Home")
        check(matches.count == 1 && matches[0].id == "itv:10a8290", "Search returns the shared ITV programme model")
        defaults.removePersistentDomain(forName: "TellyITVCatalogueFixture")
        print("ITV catalogue fixtures passed: collection routes, saved-route migration, 54 collection members, five Twilight films, film details, rails, four-series episodes, metadata parsing, host checks, expiry, search, saved, resume and legacy BBC records.")
    }
}
