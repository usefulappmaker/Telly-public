import Foundation

@MainActor final class BBCMergedFixture {
    var requests = [String]()
    var failLifestyle = false
    func fetch(_ url: URL) async throws -> Data {
        let genre = url.pathComponents[url.pathComponents.count - 2]
        let page = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
        requests.append("\(genre):\(page)")
        if failLifestyle && genre == "lifestyle" { throw BBCError.message("Temporary failure") }
        let ids = page == 1 ? (genre == "documentaries" ? [1, 2] : [2, 3]) : (genre == "documentaries" ? [4, 5] : [5, 6])
        let shows = ids.map { ["id": "b000000\($0)", "title": "Programme \($0)"] }
        return try JSONSerialization.data(withJSONObject: ["category_programmes": ["page": page, "per_page": 2, "count": 4, "elements": shows]])
    }
}
@main struct BBCMergedCategoryTests {
    @MainActor static func main() async {
        let genres = [Genre(id: "documentaries", title: "Documentaries"), Genre(id: "lifestyle", title: "Lifestyle")]
        let fixture = BBCMergedFixture()
        let store = BBCMergedCategoryStore(api: DiscoveryAPI(fetch: fixture.fetch))
        await store.next(genres: genres)
        precondition(store.shows.map(\.id) == ["b0000001", "b0000002", "b0000003"])
        await store.next(genres: genres)
        precondition(store.shows.map(\.id) == (1...6).map { "b000000\($0)" })
        await store.next(genres: genres)
        precondition(fixture.requests.count == 4 && !store.loading)
        let partial = BBCMergedFixture(); partial.failLifestyle = true
        let retry = BBCMergedCategoryStore(api: DiscoveryAPI(fetch: partial.fetch))
        await retry.next(genres: genres)
        precondition(retry.shows.count == 2 && retry.error != nil)
        let retained = retry.shows.map(\.id)
        partial.failLifestyle = false
        await retry.next(genres: genres); await retry.next(genres: genres)
        precondition(Array(retry.shows.prefix(2)).map(\.id) == retained)
        precondition(Set(retry.shows.map(\.id)) == Set((1...6).map { "b000000\($0)" }))
        precondition(retry.error == nil && partial.requests.filter { $0 == "documentaries:1" }.count == 1)
        print("PASS: one BBC network list merges subcategories, interleaves and deduplicates pages, retains successful data through partial failure/retry and stops at each source's final page")
    }
}
