import Foundation
func verify(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
@main struct Channel4Tests {
    static func main() async throws {
        let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Telly/Channel4Seed.json"))) as! [String:[String:Any]]
        let page = Channel4CatalogueAPI.page(seed["/categories/comedy"]!)
        verify(page.shows.count == 60 && page.total > 60, "Category retains its first page and advertised total")
        verify(page.shows.allSatisfy { $0.provider == .channel4 && $0.providerURL?.host == "www.channel4.com" }, "Channel 4 namespaced identities and routes")
        verify(page.shows.first?.title == "Taskmaster", "Retains the official category order")
        let fixture = ["initialData": seed["/programmes/the-great-british-bake-off"]!]
        let raw = Data(("window.__PARAMS__ = " + String(decoding: try JSONSerialization.data(withJSONObject:fixture),as:UTF8.self) + ";").utf8)
        let initial = try Channel4CatalogueAPI.state(raw)
        verify((initial["brand"] as? [String:Any])?["websafeTitle"] as? String == "the-great-british-bake-off", "SSR data handles JavaScript undefined without executing page code")
        let normalized = Channel4CatalogueAPI.state
        let miniature = Data(#"window.__PARAMS__={"initialData":{"text":"undefined and escaped \" brace }","missing":undefined}};"#.utf8)
        let parsed = try normalized(miniature)
        verify(parsed["text"] as? String == "undefined and escaped \" brace }", "Does not rewrite string contents or stop on quoted braces")
        let brand = initial["brand"] as! [String:Any]
        let show = Channel4CatalogueAPI.show(brand)!
        let details = try Channel4CatalogueAPI.details(initial, fallback: show)
        verify(details.episodes.count > 80 && details.series.count > 5, "All available series/episodes in the selected programme are parsed")
        verify(details.episodes.allSatisfy { $0.programme.provider == .channel4 && $0.programme.showID == show.id }, "Episodes retain provider and parent for resume/up-next")
        let availability = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/Channel4Availability.json"))) as! [String:[String:Any]]
        for name in ["bakeoff", "gogglebox", "frasier"] {
            let listed = try Channel4CatalogueAPI.details(availability[name]!, fallback: show)
            verify(listed.episodes.count == 2, "Only playable episodes are offered for \(name), excluding upcoming listings with null play flags")
            verify(!listed.episodes.contains { ["c4:79486-006", "c4:78331-009"].contains($0.id) }, "Upcoming Bake Off and Gogglebox episodes must not start a playback request")
        }
        let unavailable: [String:Any] = ["brand": ["episodes": [
            ["programmeId":"1-001", "showPlayLabel":false],
            ["programmeId":"1-002"],
            ["programmeId":"1-003", "showPlayLabel":true, "nextOn":true]
        ]]]
        let excluded = try Channel4CatalogueAPI.details(unavailable, fallback: show)
        verify(excluded.episodes.isEmpty, "Missing, false and upcoming flags do not advertise playable episodes")
        let liveData = try JSONSerialization.data(withJSONObject: seed["/api/now-next"]!)
        let now = ISO8601DateFormatter().date(from: "2026-10-23T21:30:00Z")!
        let live = try Channel4CatalogueAPI.live(liveData, now: now)
        verify(live.count == 5 && live[0].current != nil, "All five main channels retain current programme artwork")
        verify(live.allSatisfy { $0.provider == .channel4 && LiveChannelLink.channelID(from: LiveChannelLink.url(for: $0.id)!) == $0.id }, "All five channel links route to Channel 4")
        let second = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:"Tests/Fixtures/Channel4ComedyPage2.json"))) as! [String:Any]
        let next = Channel4CatalogueAPI.page(second)
        verify(next.offset == 60 && !next.shows.isEmpty, "Current category pagination honours its next offset")
        verify(Set(page.shows.map(\.id)).isDisjoint(with: Set(next.shows.map(\.id))), "Continuous category pages do not repeat programmes")
        for raw in ["http://www.channel4.com/", "https://evil.example/", "https://www.channel4.com.evil.example/", "https://keys.c4.aws.redbeemedia.com:443/"] { verify(!Channel4HTTP.allowed(URL(string:raw)!), "Unexpected transport destination rejected") }
        verify(ITVCatalogueAPI.show(["programmeTitle":"BBC compatibility placeholder", "programmeId":"10/8290"])?.provider == .itv, "ITV provider identity remains unchanged")
        print("Channel 4 fixtures passed: SSR, catalogue pages, all series/episodes, channel artwork, stable IDs, deep links and transport hosts.")
        guard CommandLine.arguments.contains("--live") else { return }
        for slug in ["the-great-british-bake-off", "gogglebox", "frasier"] {
            let initial = try Channel4CatalogueAPI.state(await Channel4HTTP.shared.data(URL(string:"https://www.channel4.com/programmes/" + slug)!))
            let fresh = try Channel4CatalogueAPI.details(initial, fallback: show)
            let rows = (initial["brand"] as! [String:Any])["episodes"] as! [[String:Any]]
            let upcoming = Set(rows.filter { $0["nextOn"] as? Bool == true }.compactMap { ($0["programmeId"] as? String).map { "c4:" + $0 } })
            verify(!fresh.episodes.isEmpty && Set(fresh.episodes.map(\.id)).isDisjoint(with: upcoming), "Fresh \(slug) catalogue excludes announced episodes")
            print("Fresh \(slug) catalogue: \(fresh.episodes.count) playable episodes; \(upcoming.count) upcoming listings excluded.")
        }
        for (id, live) in [("C4",true),("E4",true),("M4",true),("F4",true),("4S",true),("79486-003",false),("78331-008",false),("18926-001",false)] {
            FileHandle.standardError.write(Data("Checking fresh \(live ? "live" : "catch-up") session…\n".utf8))
            let source = try await Channel4PlaybackAPI.shared.source(id:id,live:live)
            verify(source.channel4FairPlay?.licence.host == "keys.c4.aws.redbeemedia.com", "Resolved the normal FairPlay licence service")
            verify((source.fairPlayCertificate?.count ?? 0) > 100, "Received the application certificate")
            verify(source.url.path.contains("m3u8"), "Received an HLS stream")
            if !live, let subtitles = source.channel4Subtitles {
                let master = String(decoding:try await Channel4HTTP.shared.data(source.url),as:UTF8.self)
                let patched = String(decoding:try Channel4Subtitles.master(master,base:source.url,subtitles:subtitles),as:UTF8.self)
                verify(patched.contains("SUBTITLES=\"channel4-subtitles\"") && patched.contains(subtitles.absoluteString), "Native VOD subtitles retain the broadcaster playlist")
                verify(patched.components(separatedBy:"#EXT-X-STREAM-INF:").count == master.components(separatedBy:"#EXT-X-STREAM-INF:").count, "Subtitle integration retains every video rendition")
            }
            print("Fresh anonymous \(live ? "live" : "catch-up") session: HLS source, session-specific licence endpoint and certificate resolved. Native licence exchange remains a device check.")
        }
    }
}
