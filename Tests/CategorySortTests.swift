import Foundation

@MainActor final class CategorySortFixture {
    var urls = [URL]()
    var pending: CheckedContinuation<Data,Error>?
    var hold = false
    func response(_ id: String = "b0000001") throws -> Data {
        try JSONSerialization.data(withJSONObject:["category_programmes":["elements":[["id":id,"title":id]],"page":1,"per_page":30,"count":1]])
    }
    func fetch(_ url: URL) async throws -> Data {
        urls.append(url)
        if hold { hold = false; return try await withCheckedThrowingContinuation { pending = $0 } }
        if url.path.contains("/atoz/") { return try JSONSerialization.data(withJSONObject:["atoz_programmes":["elements":[],"page":1,"per_page":30,"count":0]]) }
        return try response("b0000002")
    }
}
@main struct CategorySortTests {
    @MainActor static func main() async throws {
        func check(_ condition: @autoclosure ()->Bool,_ message: String) { guard condition() else { fatalError(message) } }
        func show(_ id: String,_ title: String,_ date: String? = nil) -> CatalogueShow {
            var s = CatalogueShow(id:id,title:title,summary:"",image:nil,letter:"a",channel:"BBC",categories:[],expectedEpisodes:1,singleEpisode:false,episodes:[])
            s.catalogueDate = CategorySorting.date(date); return s
        }
        let alpha = show("a","Alpha","2026-10-28T00:00:00Z"), zebra = show("z","Zebra","2026-10-27T00:00:00.000Z")
        var beta = show("b","Beta"); beta.indexedAt = .distantFuture
        let gamma = show("g","Gamma")
        let source = [zebra,gamma,beta,alpha]
        check(CategorySorting.sorted(source,by:.date).map(\.id) == ["a","z","b","g"],"Date newest first, undated alphabetically last; ignore cache refresh time")
        check(CategorySorting.sorted(source,by:.alphabetical).map(\.id) == ["a","b","g","z"],"A-Z ignores date")
        let learned = CategorySorting.date("2026-10-29T12:00:00Z")!
        check(CategorySorting.sorted(source,by:.date,cached:["g":learned]).first?.id == "g","Dates learned from opened programmes update category order")
        var episodeProgramme = Programme(id:"u:11",title:"Episode",summary:"",image:nil,version:"",guidance:nil)
        var u = show("u:1","U programme")
        u.episodes = [CatalogueEpisode(programme:episodeProgramme,subtitle:"Episode",duration:"",sliceID:"1",seriesTitle:"1",broadcastDate:"2026-10-28T00:00:00Z")]
        check(CategorySorting.knownDate(u) == nil,"Never use U's availability-window date as broadcast date")
        episodeProgramme.firstBroadcastDateTime = "2026-10-28T12:00:00Z"
        u.episodes = [CatalogueEpisode(programme:episodeProgramme,subtitle:"Episode",duration:"",sliceID:"1",seriesTitle:"1")]
        check(CategorySorting.knownDate(u) != nil,"Use genuine episode broadcast metadata")
        let label = CategorySorting.date("First shown: Tue 29 Sep 2026")
        check(label == CategorySorting.date("2026-09-29T00:00:00Z"),"Channel 4 first-shown label parsed correctly")
        check(CategorySorting.date("not a date") == nil,"Malformed dates remain unknown")
        let itv = ITVCatalogueAPI.show(["programmeId":"1/1234","title":"Example","dateTime":"2026-10-28T20:00:00Z"])
        check(itv?.catalogueDate == CategorySorting.date("2026-10-28T20:00:00Z"),"ITV category listing date retained")
        var old = try JSONSerialization.jsonObject(with:JSONEncoder().encode(alpha)) as! [String:Any]
        old.removeValue(forKey:"catalogueDate")
        let decoded = try JSONDecoder().decode(CatalogueShow.self,from:JSONSerialization.data(withJSONObject:old))
        check(decoded.catalogueDate == nil,"Older cached/saved programme snapshots still decode")
        check(CategorySortOrder.allCases.map(\.rawValue) == ["Date","A-Z"],"Minimal requested control labels")
        let fixture = CategorySortFixture(), api = DiscoveryAPI(fetch:fixture.fetch)
        _ = try await api.page(category:"comedy",page:1,sort:.date)
        check(URLComponents(url:fixture.urls.last!,resolvingAgainstBaseURL:false)!.queryItems!.contains { $0.name == "sort" && $0.value == "recent" },"BBC Date requests recent-first from provider")
        _ = try await api.page(letter:"a",page:1,sort:.date)
        check(!(URLComponents(url:fixture.urls.last!,resolvingAgainstBaseURL:false)!.queryItems ?? []).contains { $0.name == "sort" },"A-Z letter pages never request category recency")
        let store = BBCMergedCategoryStore(api:api)
        fixture.hold = true
        let oldRequest = Task { await store.next(genres:[Genre(id:"comedy",title:"Comedy")],sort:.date) }
        for _ in 0..<100 where fixture.pending == nil { await Task.yield() }
        check(fixture.pending != nil,"Old request suspended")
        store.reset()
        await store.next(genres:[Genre(id:"comedy",title:"Comedy")],sort:.alphabetical)
        fixture.pending?.resume(returning:try fixture.response("b0000009")); fixture.pending = nil
        await oldRequest.value
        check(store.shows.map(\.id) == ["b0000002"] && !store.loading,"Stale sort response cannot overwrite new page state")
        print("PASS: category Date/A-Z order, undated fallback, real date fields, ignored availability/refresh dates, old-cache compatibility, BBC recency and stale-request reset")
    }
}
