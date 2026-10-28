import Foundation
func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
actor IndexRequests {
    var urls = [URL]()
    func record(_ url: URL) { urls.append(url) }
    func count() -> Int { urls.count }
}
@main struct CatalogueIndexTests {
    static func episode(_ id: String, uhd: Bool) -> [String: Any] {
        ["id": id, "title": "Example", "subtitle": "Series 1: Episode 1", "status": "available", "versions": [["id": "v0000001", "kind": "technical-replacement", "uhd": uhd, "hdr": false]]]
    }
    static func response(_ rows: [[String: Any]], page: Int = 1, total: Int? = nil, perPage: Int = 200) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["programme_episodes": ["page": page, "per_page": perPage, "count": total ?? rows.count, "elements": rows]])
    }
    static func show(_ id: String, title: String = "Example") throws -> CatalogueShow {
        try CatalogueAPI.show(["id": id, "title": title, "count": 1, "tleo_type": "brand"])
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let seed = try PropertyListDecoder().decode(CatalogueIndexSnapshot.self, from: data)
            expect(seed.catalogue.count > 3000 && seed.uhd.count >= 90 && seed.search("Vigil").count > 0, "Bundled seed decodes and supports complete offline programme search")
            print("Seed: \(seed.catalogue.count) programmes, \(seed.uhd.count) UHD groups")
        }
        var raw = episode("p0000001", uhd: true)
        raw["versions"] = [["id": "v0000000", "kind": "original", "uhd": false], ["id": "v0000001", "kind": "technical-replacement", "uhd": true, "hdr": false]]
        let replacement = try CatalogueAPI.episode(raw)
        expect(replacement.programme.uhdListed == true && replacement.programme.version == "v0000001", "Replacement UHD rendition is selected even alongside an HD original")
        expect(replacement.programme.hdrListed == false, "False HDR metadata must not remove UHD availability")
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        for version in [["kind": "signed", "uhd": true], ["kind": "audio-described", "uhd": true], ["kind": "original", "uhd": true, "availability": ["end": past]], ["kind": "original", "uhd": true, "availability": ["start": future]]] as [[String: Any]] {
            raw["versions"] = [version]
            let unavailable = try CatalogueAPI.episode(raw)
            expect(unavailable.programme.uhdListed == false, "Unavailable/accessibility-only versions cannot advertise ordinary UHD playback")
        }
        let log = IndexRequests()
        let full = CatalogueIndexAPI(fetch: { url in
            await log.record(url)
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let page = Int(c.queryItems!.first { $0.name == "page" }!.value!)!
            let a = url.path.contains("/atoz/a/")
            let rows: [[String: Any]] = a ? [["id": page == 1 ? "b0000001" : "b0000002", "title": page == 1 ? "Époque" : "Vigil", "count": 1, "tleo_type": "brand"]] : []
            return try JSONSerialization.data(withJSONObject: ["atoz_programmes": ["count": a ? 2 : 0, "page": page, "per_page": a ? 1 : 200, "elements": rows]])
        })
        let all = try await full.allShows()
        let calls = await log.count()
        expect(all.count == 2 && calls == 28, "Enumerate all A–Z buckets and every page")
        var snapshot = CatalogueIndexSnapshot(); snapshot.catalogue = all
        expect(snapshot.search(" EPOQUE ").first?.title == "Époque", "Accent/case insensitive full-catalogue search")
        expect(snapshot.search("vigil").count == 1 && snapshot.search(" ").isEmpty, "Search titles never restricted to browsed or UHD programmes")
        let page = Data(#"<html><a href="/iplayer/episodes/b9999999/outside">Outside</a><article><a href="https://www.bbc.co.uk/iplayer/episodes/b0000001/example?seriesId=one"><strong>A &amp; B</strong></a><a href='/iplayer/episodes/b0000001/example?seriesId=two'>Duplicate</a><a href="/iplayer/episode/p0000002/episode">New &#x55;HD &rsquo;film&rsquo;</a><a href="https://evil.invalid/iplayer/episodes/b0000003/no">Ignore</a></article></html>"#.utf8)
        let entries = try CatalogueIndexAPI.parseUHDPage(page)
        expect(entries.count == 2 && entries[0].title == "A & B" && entries[1].title == "New UHD ’film’" && entries[1].singleEpisode, "Article scope, markup/entities, series deduplication, episode URLs and host validation")
        for bad in ["<html>Blocked</html>", "<article>No programme links</article>"] {
            do { _ = try CatalogueIndexAPI.parseUHDPage(Data(bad.utf8)); fatalError("Invalid BBC page accepted") } catch {}
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--page-fixture"), flag + 1 < CommandLine.arguments.count {
            let liveEntries = try CatalogueIndexAPI.parseUHDPage(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[flag + 1])))
            expect(liveEntries.count > 50 && liveEntries.contains { $0.id == "p09pm77q" }, "Actual BBC article parses and contains Vigil")
            print("BBC page fixture: \(liveEntries.count) distinct links")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiscoveryCache(folder: folder)
        let a = try show("b0000001"), b = try show("b0000002")
        snapshot.catalogue = [a, b]; snapshot.uhd = [b]; snapshot.uhd[0].uhdListed = true
        snapshot.catalogueUpdatedAt = Date()
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        legacy["pendingIDs"] = [a.id, b.id]; legacy["scanTotal"] = 3643; legacy["completedAt"] = Date().timeIntervalSinceReferenceDate
        let migrated = try JSONDecoder().decode(CatalogueIndexSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        try await cache.write(migrated, key: "catalogue-index-v1")
        let requests = IndexRequests()
        let store = CatalogueIndexStore(api: CatalogueIndexAPI(fetch: { url in
            await requests.record(url)
            expect(url == CatalogueIndexAPI.uhdPageURL, "UHD refresh must not request programme/episode lists")
            return page
        }), cache: cache)
        await store.refresh()
        let pageCalls = await requests.count()
        expect(pageCalls == 1 && store.snapshot.uhdPageUpdatedAt != nil, "One webpage request replaces legacy full scan")
        expect(Set(store.uhd.map(\.id)) == Set([a.id, b.id, "p0000002"]), "Preserve discoveries and add new page entries")
        expect(store.uhd.first { $0.id == "p0000002" }?.discoveryEpisodeID == "p0000002", "Unknown episode link resolves only when opened")
        await store.refresh()
        let cachedCalls = await requests.count(); expect(cachedCalls == 1, "Fresh daily cache avoids network")
        await store.refresh(force: true)
        let forcedCalls = await requests.count(); expect(forcedCalls == 2, "Manual update requests only webpage when Search is fresh")
        var positive = a
        positive.episodes = [try CatalogueAPI.episode(episode("p0000002", uhd: true))]; positive.indexedAt = Date()
        await store.record(positive, replacingID: "p0000002")
        expect(store.snapshot.episodeParents?["p0000002"] == a.id && !store.uhd.contains { $0.id == "p0000002" }, "On-open discovery learns parent and deduplicates")
        await store.refresh(force: true)
        expect(!store.uhd.contains { $0.id == "p0000002" }, "Page updates reuse learned aliases")
        var saved = await cache.read(CatalogueIndexSnapshot.self, key: "catalogue-index-v1")!
        saved.uhdPageUpdatedAt = nil; try await cache.write(saved, key: "catalogue-index-v1")
        let offlineLog = IndexRequests()
        let offline = CatalogueIndexStore(api: CatalogueIndexAPI(fetch: { url in await offlineLog.record(url); throw BBCError.message("Offline") }), cache: cache)
        await offline.refresh()
        expect(offline.snapshot.uhdPageUpdatedAt == nil && offline.snapshot.uhdRetryAfter != nil && !offline.uhd.isEmpty, "Failure retains cache and sets backoff without claiming freshness")
        await offline.refresh()
        let failedCalls = await offlineLog.count(); expect(failedCalls == 1, "Backoff prevents repeated failure")
        saved.uhdRetryAfter = nil; try await cache.write(saved, key: "catalogue-index-v1")
        let cancelled = CatalogueIndexStore(api: CatalogueIndexAPI(fetch: { _ in throw CancellationError() }), cache: cache)
        await cancelled.refresh()
        expect(cancelled.snapshot.uhdPageUpdatedAt == nil && cancelled.snapshot.uhdRetryAfter == nil && cancelled.uhd.count == saved.uhd.count, "Cancellation preserves cache without marking failure or freshness")
        var negative = positive; negative.episodes = [try CatalogueAPI.episode(episode("p0000002", uhd: false))]
        await store.record(negative, replacingID: a.id)
        expect(!store.uhd.contains { $0.id == a.id }, "Fresh on-open negative availability removes saved UHD entry")
        print("PASS: title search, UHD-page parsing, single-request refresh, legacy migration, daily cache, aliases, on-open discoveries, failure retention and cancellation")
    }
}
