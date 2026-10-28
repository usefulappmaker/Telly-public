import Foundation
@main struct Channel5Tests {
    static func require(_ condition: @autoclosure ()->Bool,_ message: String) { precondition(condition(),message) }
    static func main() async throws {
        let shows=try Channel5CatalogueAPI.shows(Data(contentsOf:URL(fileURLWithPath:"Telly/Channel5Seed.json")))
        require(shows.count>1000,"Bundled catalogue contains available provider programmes")
        require(Set(shows.map(\.id)).count==shows.count && shows.allSatisfy { $0.provider == .channel5 },"Stable provider identities are unique")
        let show=shows.first { $0.title == "All Creatures Great and Small" }!
        require(Channel5CatalogueAPI.belongs(show,category:"drama"),"Provider drama joins the shared category")
        require(show.image?.host == "api-images.channel5.com","Artwork uses the provider's image service")
        let now=Date(timeIntervalSince1970:1800000000)
        let available: [String:Any]=["id":"C5515180001","title":"Back to School","vod_s":1790000000,"vod_e":1900000000,"len":3000000,"ep_num":1]
        let episode=Channel5CatalogueAPI.episode(available,show:show,season:"7",now:now)!
        require(episode.programme.showID==show.id && episode.programme.provider == .channel5 && episode.duration=="50 mins","Episodes retain parent, provider and duration for saved progress")
        var future=available;future["vod_s"]=1900000000
        var expired=available;expired["vod_e"]=1790000000
        require(Channel5CatalogueAPI.episode(future,show:show,season:"7",now:now)==nil && Channel5CatalogueAPI.episode(expired,show:show,season:"7",now:now)==nil,"Upcoming and expired episodes cannot be offered as playable")
        let standaloneFixtures = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/Channel5Standalone.json"))) as! [[String:Any]]
        let fixtureDate = Date(timeIntervalSince1970:1792880000)
        for fixture in standaloneFixtures {
            let metadata = fixture["show"] as! [String:Any]
            let standaloneShow = Channel5CatalogueAPI.show(metadata)!
            let id = String(standaloneShow.id.dropFirst(3))
            let prefix = "/shows/" + id
            let replies: [String:Data] = [
                prefix+".json":try JSONSerialization.data(withJSONObject:metadata),
                prefix+"/seasons.json":try JSONSerialization.data(withJSONObject:fixture["seasons"]!),
                prefix+"/episodes.json":try JSONSerialization.data(withJSONObject:fixture["episodes"]!)
            ]
            let api = Channel5CatalogueAPI(fetch: { url in
                guard let data = replies[url.path] else { throw Channel5Error.message("Unexpected standalone fixture route.") }
                return data
            })
            let details = try await api.details(standaloneShow,now:fixtureDate)
            require(details.episodes.count==1 && details.singleEpisode,"Films and specials with null season numbers open their playable programme")
            require(details.episodes[0].subtitle==metadata["title"] as? String,"Standalone programmes use their title rather than an invented episode number")
            require(details.episodes[0].programme.showID==standaloneShow.id && details.episodes[0].programme.provider == .channel5,"Standalone playback retains saved/history parent identities")
            let raw = (fixture["episodes"] as! [String:Any])["episodes"] as! [[String:Any]]
            require(details.episodes[0].id=="c5:"+(raw[0]["id"] as! String),"Standalone entries use the provider playback ID, not the show ID")
        }
        let nullRoute = try Channel5CatalogueAPI.episodesURL(showID:"123",season:nil)
        let numberedRoute = try Channel5CatalogueAPI.episodesURL(showID:"123",season:"7")
        require(nullRoute.path=="/shows/123/episodes.json" && numberedRoute.path=="/shows/123/seasons/7/episodes.json","Standalone and numbered series use the verified provider routes")
        let mixed = Channel5CatalogueAPI.seasons(["seasons":[["seasonNumber":NSNull()],["seasonNumber":"1"],["seasonNumber":2],["seasonNumber":NSNull()]]],standalone:false)
        require(mixed.count==3 && mixed[0]==nil && mixed[1]=="1" && mixed[2]=="2","Unnumbered specials coexist with numbered series without duplicate routes")
        let emptyStandalone = Channel5CatalogueAPI.seasons(["seasons":[]],standalone:true)
        require(emptyStandalone.count==1 && emptyStandalone[0]==nil,"Standalone metadata without a series listing still resolves the programme")
        let groups=UnifiedCategory.make(bbc:[Genre(id:"films",title:"Films")],itv:[ITVCategory(id:"films",title:"Films",path:"/watch/categories/films")],channel4:[Genre(id:"film",title:"Films")],channel5:[Genre(id:"films",title:"Films")])
        require(groups.count==1 && groups[0].providers == [.bbc,.itv,.channel4,.channel5],"Equivalent categories retain all four networks")
        for raw in ["http://cassie.channel5.com/api/v2/licences/fairplay/1/test", "https://cassie.channel5.com.evil.test/api/v2/licences/fairplay/test", "https://name:password@cassie.channel5.com/api/v2/licences/fairplay/test", "https://cassie.channel5.com/api/v2/media/test"] { require(!Channel5Wire.licenceAllowed(URL(string:raw)!),"Untrusted or unrelated licence destinations are rejected") }
        require(!Channel5HTTP.allowed(URL(string:"https://userservice-api.channel5.com.evil.test/")!),"Account service boundary rejects lookalike hosts")
        let contentID = try Channel5Wire.fairPlayContentID("skd://C5515180001")
        require(contentID=="C5515180001","FairPlay preserves the case of the provider identifier")
        do { _=try Channel5Wire.fairPlayContentID("skd://C5&injected=value");preconditionFailure("Unsafe content identifier accepted") } catch { }
        require(Channel5Wire.formValue("a+b/=")=="a%2Bb%2F%3D","Form encoding preserves SPC base64 bytes")
        let fixture=try Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/Channel5Envelope.json"))
        let decoded=try Channel5Wire.decode(fixture)
        require(decoded["fixture"] as? String == "Channel 5 native metadata","Known AES service-envelope fixture decodes correctly")
        let url=try Channel5Wire.signedURL(id:"C5",live:true,now:now)
        let expected=try String(contentsOfFile:"Tests/Fixtures/Channel5Signature.txt",encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        require(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name=="auth" }?.value == expected,"Native request signature matches the independently generated HMAC vector")
        let config: [String:Any]=["googleDaiAdSettings":["queryString":"?id={c5id_lowercase}&session={vcid}&child={tfcd}&consent={consent}"]]
        let dai=try Channel5PlaybackAPI.liveURL(URL(string:"https://dai.google.com/linear/hls/event/example/master.m3u8")!,id:"C5CH11",settings:config)
        let q=URLComponents(url:dai,resolvingAgainstBaseURL:false)!.queryItems!
        require(q.first { $0.name=="child" }?.value == "1" && !q.contains { $0.name=="consent" },"Live sessions preserve child-directed flags and do not invent consent")
        if CommandLine.arguments.contains("--live") {
            for (id,live) in [("C5",true),("C7",true),("C6",true),("C0",true),("C8",true),("C5515180001",false),("C5CH02",true),("3P-AMC-FAST-03",true)] {
                let metadata=try await Channel5Wire.metadata(id:id,live:live,session:nil)
                let (manifest,licence)=try Channel5PlaybackAPI.fairPlay(metadata)
                require(manifest.scheme=="https" && Channel5Wire.licenceAllowed(licence),"Fresh provider metadata offers validated Apple playback services")
                print("PASS fresh native metadata:",id,"FairPlay HLS resolved")
            }
            let details=try await Channel5CatalogueAPI().details(show)
            require(details.series.count>=7 && !details.episodes.isEmpty,"Fresh catch-up programme opens all available seasons")
            for fixture in standaloneFixtures {
                let original = Channel5CatalogueAPI.show(fixture["show"] as! [String:Any])!
                let opened = try await Channel5CatalogueAPI().details(original)
                require(opened.episodes.count==1,"Fresh standalone catalogue exposes its available programme")
                let metadata = try await Channel5Wire.metadata(id:String(opened.episodes[0].id.dropFirst(3)),live:false,session:nil)
                let (_,licence) = try Channel5PlaybackAPI.fairPlay(metadata)
                require(Channel5Wire.licenceAllowed(licence),"Standalone playback resolves FairPlay with the returned episode ID")
                print("PASS fresh standalone:",original.title,"playable programme and FairPlay stream resolved")
            }
            let channels=try await Channel5CatalogueAPI().live()
            require(channels.count>=24 && channels.allSatisfy { $0.provider == .channel5 },"Live directory includes main and themed channels")
            print("PASS fresh catalogue:",details.series.count,"series,",details.episodes.count,"episodes,",channels.count,"live channels")
        }
        print("PASS Channel 5: provider identities, availability, unified categories, host boundaries, FairPlay IDs, form encoding, metadata cryptography and DAI session flags. Device licence acceptance remains a physical Apple TV test.")
    }
}
