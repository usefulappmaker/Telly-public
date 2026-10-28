import Foundation

@main struct FeaturedTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func show(_ id: String, premium: Bool = false) -> CatalogueShow {
        var show = CatalogueShow(id:id,title:id,summary:"Summary",image:URL(string:"https://example.com/landscape.jpg"),letter:"a",channel:"",categories:[],expectedEpisodes:2,singleEpisode:false,episodes:[])
        show.premium = premium; return show
    }
    static func main() async throws {
        var sources: [ContentProvider:[HomeFeature]] = [:]
        for (p,prefix) in zip(FeaturedCatalogue.providers,["bbc:","itv:","c4:","c5:","u:"]) {
            sources[p] = (0..<4).map { FeaturedCatalogue.feature(show(prefix + String($0))) }
        }
        let mixed = FeaturedCatalogue.mix(sources)
        check(mixed.count == 10,"Two picks from each network")
        check(mixed.map { $0.show.provider } == FeaturedCatalogue.providers + FeaturedCatalogue.providers,"Interleaved network order")
        sources[.itv] = [FeaturedCatalogue.feature(show("itv:paid",premium:true)),sources[.itv]![0],sources[.itv]![0],sources[.itv]![1]]
        sources[.channel4] = []
        let partial = FeaturedCatalogue.mix(sources)
        check(partial.count == 8,"Missing provider does not prevent other networks")
        check(Set(partial.map(\.id)).count == partial.count,"Duplicate programme removed")
        check(!partial.contains { $0.id == "itv:paid" },"Premium programmes excluded")
        var collection = show("itv:collection"); collection.providerURL = URL(string:"https://www.itv.com/watch/collections/test/123")
        check(FeaturedCatalogue.mix([.itv:[FeaturedCatalogue.feature(collection)]]).isEmpty,"Collection targets excluded")

        let a = HomeRow(id:"first",title:"Most Popular",shows:[show("bbc:1")])
        let b = HomeRow(id:"posters",title:"Stream Every Episode",shows:[show("bbc:2")])
        var drama5 = show("c5:2"); drama5.categories = ["Drama"]
        var dramaU = show("u:2"); dramaU.categories = ["category:drama"]
        var comedy4 = show("c4:2"); comedy4.categories = ["Comedy"]
        let homeRows = HomepageRows.make(bbc:[a,b],itv:[ITVRail(id:"featured",title:"Featured",shows:[show("itv:1")],more:"/watch/collections/example/123")],
            channel4:[show("c4:1")],channel4All:[comedy4],channel5:[show("c5:1")],channel5All:[drama5],u:[show("u:1")],uAll:[dramaU])
        check(Array(homeRows.prefix(5).map(\.provider)) == FeaturedCatalogue.providers,"Every available network appears before any repeats")
        check(homeRows.first?.title == "Discover BBC" && homeRows[1].title == "Discover ITV","Keep Discover network headings")
        check(homeRows.first(where:{ $0.id == "bbc:posters" })?.posters == true,"BBC portrait row remains intact")
        check(homeRows.first(where:{ $0.provider == .itv })?.more == "/watch/collections/example/123","ITV View all routes preserved")
        check(homeRows.contains(where:{ $0.title == "Comedy on Channel 4" }) && homeRows.contains(where:{ $0.title == "Drama on Channel 5" }) && homeRows.contains(where:{ $0.title == "Drama on U" }),"Cached category rows give other providers additional prominence")
        check(homeRows.allSatisfy { !$0.shows.isEmpty } && Set(homeRows.map(\.id)).count == homeRows.count,"No empty or colliding rows")
        let sparse = HomepageRows.interleave([.bbc:[HomepageRail(id:"b1",provider:.bbc,title:"BBC",shows:[show("bbc:1")]),HomepageRail(id:"b2",provider:.bbc,title:"BBC 2",shows:[show("bbc:2")])],.u:[HomepageRail(id:"u1",provider:.u,title:"U",shows:[show("u:1")])]])
        check(sparse.map(\.id) == ["b1","u1","b2"],"Missing providers never block remaining rows")
        let brand: [String:Any] = ["id":123,"name":"U programme","slug":"u-programme","available_episodes":3,"image":"https://uktv-res.cloudinary.com/image/private/v1/test.jpg"]
        let root: [Any] = ["$","element","rail",["header":"Top Series to Stream from U On Demand","items":[["linked_brand":brand,"subtitle":"Editorial synopsis","image":"https://uktv-res.cloudinary.com/image/private/v1/hero.jpg"]]]]
        let flight = "ab:" + String(decoding:try JSONSerialization.data(withJSONObject:root),as:UTF8.self) + "\n"
        let split = flight.index(flight.startIndex,offsetBy:flight.count/2)
        let frames = [String(flight[..<split]),String(flight[split...])]
        let html = try frames.map { "<script>self.__next_f.push(" + String(decoding:try JSONSerialization.data(withJSONObject:[1,$0]),as:UTF8.self) + ")</script>" }.joined()
        let u = FeaturedCatalogue.uFeatures(Data(html.utf8),known:[])
        check(u.count == 1 && u[0].id == "u:123","U split flight frames and linked brand resolved")
        check(u[0].synopsis == "Editorial synopsis","Editorial text preserved")
        check(FeaturedCatalogue.uFeatures(Data("not a catalogue".utf8),known:[]).isEmpty,"Malformed page has safe fallback")

        let rail = Data(#"{"filters":{"ids":["episode-b","episode-a","../bad"]}}"#.utf8)
        let order = try FeaturedCatalogue.channel5IDs(rail)
        check(order == ["episode-b","episode-a"],"Validate catalogue IDs")
        let raw = Data(#"{"watchables":[{"id":"episode-a","sh_id":"111","sh_title":"First","vod_s":1,"vod_e":2000},{"id":"episode-b","sh_id":"222","sh_title":"Second","vod_s":1,"vod_e":2000},{"id":"episode-expired","sh_id":"333","sh_title":"Expired","vod_s":1,"vod_e":50}]}"#.utf8)
        let c5 = try FeaturedCatalogue.channel5Features(raw,order:order + ["episode-expired"],known:[],now:Date(timeIntervalSince1970:100))
        check(c5.map(\.id) == ["c5:222","c5:111"],"Retain editorial order, resolve show ID rather than episode ID, skip expired")
        check(c5[0].headline == "Second","Use programme title")
        if CommandLine.arguments.contains("--recorded") {
            let root = URL(fileURLWithPath:"Tests/Fixtures/UFeaturedPage.html")
            let liveU = FeaturedCatalogue.uFeatures(try Data(contentsOf:root),known:[])
            check(liveU.count >= 2,"Actual U homepage decodes at least two editorial programmes")
            print("Recorded official U homepage:",liveU.prefix(2).map(\.headline).joined(separator:", "))
        }
        if CommandLine.arguments.contains("--network") {
            let client = FeaturedCatalogueClient()
            async let uRequest = client.u([])
            async let c5Request = client.channel5([])
            let (freshU,fresh5) = try await (uRequest,c5Request)
            check(freshU.count >= 2 && fresh5.count >= 2,"Official live feeds supply at least two programmes each")
            print("Live U:",freshU.prefix(2).map(\.headline).joined(separator:", "))
            print("Live Channel 5:",fresh5.prefix(2).map(\.headline).joined(separator:", "))
        }
        print("Featured tests passed")
    }
}
