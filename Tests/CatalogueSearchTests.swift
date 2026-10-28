import Foundation

actor SearchGate {
    private var pending: [String:CheckedContinuation<[SearchProviderBatch],Never>] = [:]
    private var requests: [String] = []
    func fetch(_ query: String) async -> [SearchProviderBatch] {
        requests.append(query)
        return await withCheckedContinuation { pending[query]=$0 }
    }
    func started(_ query: String) -> Bool { pending[query] != nil }
    func count() -> Int { requests.count }
    func finish(_ query: String, shows: [CatalogueShow]) { pending.removeValue(forKey:query)?.resume(returning:[SearchProviderBatch(provider:.itv,shows:shows)]) }
}
actor SearchCalls {
    private var values: [String] = []
    func record(_ query: String) { values.append(query) }
    func all() -> [String] { values }
}
@main struct CatalogueSearchTests {
    static func show(_ id: String,_ title: String,_ summary: String = "") -> CatalogueShow {
        CatalogueShow(id:id,title:title,summary:summary,image:nil,letter:"",channel:"",categories:[],expectedEpisodes:0,singleEpisode:false,episodes:[])
    }
    @MainActor static func wait(_ gate: SearchGate,_ query: String) async throws {
        for _ in 0..<200 {
            if await gate.started(query) { return }
            try await Task.sleep(nanoseconds:5_000_000)
        }
        preconditionFailure("Expected remote request did not start")
    }
    @MainActor static func main() async throws {
        let exact=show("bbc00001","Home"),prefix=show("bbc00002","Home Town"),contains=show("bbc00003","Going Home"),summary=show("bbc00004","Coast","A journey home")
        var snapshot=CatalogueIndexSnapshot();snapshot.catalogue=[summary,contains,prefix,exact]
        var uhd=exact;uhd.uhdListed=true;uhd.uhdEpisodeCount=2;snapshot.uhd=[uhd]
        let source=SearchCatalogueSource(revisions:[1,1,1,1,1],bbc:snapshot,cached:[[show("itv:home","Hôme"),show("c4:home","Home"),show("c5:home","Home"),show("c5:home","Home duplicate"),show("u:home","Home")]])
        let engine=ProgrammeSearchIndex();try await engine.prepare(source)
        let local=try await engine.matches("  HOME ")
        precondition(local.count==8 && Set(local.map(\.id)).count==8,"All five providers retain unique identities; case/diacritics are folded")
        precondition(local.first(where:{$0.id==exact.id})?.uhdEpisodeCount==2,"BBC UHD metadata survives the prepared index")
        let exactPosition=local.firstIndex(where:{$0.id==exact.id})!,prefixPosition=local.firstIndex(where:{$0.id==prefix.id})!,containsPosition=local.firstIndex(where:{$0.id==contains.id})!,summaryPosition=local.firstIndex(where:{$0.id==summary.id})!
        precondition(exactPosition<prefixPosition && prefixPosition<containsPosition && containsPosition<summaryPosition,"Exact/prefix/title/summary ranking is stable")
        let multi=try await engine.matches("journey home");precondition(multi.map(\.id)==[summary.id],"All query words match local searchable text")
        let updated=SearchCatalogueSource(revisions:[2,1,1,1],bbc:CatalogueIndexSnapshot(catalogue:[show("bbc00001","Changed")]),cached:[])
        try await engine.prepare(updated);let changed=try await engine.matches("home");precondition(changed.isEmpty,"Catalogue revision changes rebuild prepared text")

        let gate=SearchGate(),model=CatalogueSearchModel(delay:0,remote:{ await gate.fetch($0) })
        let old=Task { await model.update("old",source:source) };try await wait(gate,"old")
        let new=Task { await model.update("new",source:source) };try await wait(gate,"new")
        await gate.finish("new",shows:[show("itv:new","New")]);await new.value
        await gate.finish("old",shows:[show("itv:old","Old")]);await old.value
        precondition(model.state.query=="new" && model.state.results.map(\.id)==["itv:new"],"Slow stale responses cannot replace the current query")
        await model.update("new",source:source)
        let cacheCalls=await gate.count();precondition(cacheCalls==2,"Repeated settled queries use the bounded cache without a network request")
        let clearing=Task { await model.update("clear",source:source) };try await wait(gate,"clear")
        await model.update("  ",source:source);await gate.finish("clear",shows:[show("itv:clear","Clear")]);await clearing.value
        precondition(model.state.results.isEmpty && model.state.query.isEmpty && !model.state.searching,"Clearing the field cancels pending publication")

        let calls=SearchCalls(),debounced=CatalogueSearchModel(delay:80_000_000,remote:{ q in await calls.record(q);return [] })
        let first=Task { await debounced.update("ho",source:source) }
        try await Task.sleep(nanoseconds:10_000_000);first.cancel();await first.value
        await debounced.update("home",source:source)
        let typedCalls=await calls.all();precondition(typedCalls==["home"],"Rapid cancelled input does not launch remote searches")
        let retained=debounced.state.results
        let typing=Task { await debounced.update("hom",source:source) }
        try await Task.sleep(nanoseconds:10_000_000)
        precondition(debounced.state.results==retained,"Typing preserves current cards instead of clearing/rebuilding the grid")
        typing.cancel();await typing.value
        let failed=CatalogueSearchModel(delay:0,remote:{ _ in [SearchProviderBatch(provider:.channel4,failed:true),SearchProviderBatch(provider:.itv,shows:[show("itv:remote","Home Remote")])] })
        await failed.update("home",source:source)
        precondition(failed.state.error != nil && failed.state.results.contains(where:{$0.id==exact.id}) && failed.state.results.contains(where:{$0.id=="itv:remote"}),"One provider failure retains local and successful remote results")
        print("PASS search: ranking, all-network deduplication, UHD, revision invalidation, debounce, stale responses, caching, clear/cancel, stable cards and partial failure.")

        let data=try Data(contentsOf:URL(fileURLWithPath:"Telly/CatalogueSeed.plist"))
        let seeded=try PropertyListDecoder().decode(CatalogueIndexSnapshot.self,from:data)
        let itvSeed=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"Telly/ITVCatalogueSeed.json"))) as! [String:[String:Any]]
        let seedShows=itvSeed.values.flatMap { ITVCatalogueAPI.rails($0).flatMap(\.shows) }
        let channel5=try Channel5CatalogueAPI.shows(Data(contentsOf:URL(fileURLWithPath:"Telly/Channel5Seed.json")))
        let queries=["home","the","a"]
        var oldCount=0,newCount=0
        let before=Date()
        for _ in 0..<4 { for q in queries {
            oldCount += seeded.search(q).count
            oldCount += itvSeed.values.flatMap { ITVCatalogueAPI.rails($0).flatMap(\.shows) }.filter { $0.title.localizedCaseInsensitiveContains(q) }.count
            oldCount += channel5.filter { $0.title.localizedCaseInsensitiveContains(q) }.count
        } }
        let legacy=Date().timeIntervalSince(before)
        let prepared=ProgrammeSearchIndex();let start=Date()
        try await prepared.prepare(SearchCatalogueSource(revisions:[1],bbc:seeded,cached:[seedShows,channel5]))
        let preparation=Date().timeIntervalSince(start),matching=Date()
        for _ in 0..<4 { for q in queries { newCount += try await prepared.matches(q).count } }
        let searches=Date().timeIntervalSince(matching)
        precondition(oldCount>0 && newCount>0)
        print(String(format:"Search benchmark (12 repeated reads; %d BBC / %d Channel 5 shows): legacy %.3fs; one-time background preparation %.3fs; prepared matching %.3fs.",seeded.catalogue.count,channel5.count,legacy,preparation,searches))
    }
}
