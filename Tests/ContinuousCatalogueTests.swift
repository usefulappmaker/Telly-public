import Foundation

@MainActor final class CatalogueFixture {
    var requests = [Int]()
    var failSecond = false
    var pauseFirst = false
    func fetch(_ url: URL) async throws -> Data {
        let page = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
        requests.append(page)
        if pauseFirst { try await Task.sleep(nanoseconds: 30_000_000) }
        if failSecond && page == 2 { throw BBCError.message("Temporary failure") }
        let ids = page == 1 ? ["b0000001", "b0000002"] : ["b0000002", "b0000003"]
        let key = url.path.contains("atoz") ? "atoz_programmes" : "category_programmes"
        return try JSONSerialization.data(withJSONObject: [key: ["page": page, "per_page": 2, "count": 4, "elements": ids.map { ["id": $0, "title": $0] }]])
    }
}

@main struct ContinuousCatalogueTests {
    @MainActor static func main() async {
        let fixture = CatalogueFixture()
        let store = ContinuousCatalogueStore(api: DiscoveryAPI(fetch: fixture.fetch))
        await store.next(category: "drama", letter: nil)
        precondition(store.shows.count == 2 && store.hasMore)
        fixture.failSecond = true
        await store.next(category: "drama", letter: nil)
        precondition(store.shows.count == 2 && store.error != nil && !store.loading)
        fixture.failSecond = false
        await store.next(category: "drama", letter: nil)
        precondition(store.shows.map(\.id) == ["b0000001", "b0000002", "b0000003"] && !store.hasMore && store.error == nil)
        await store.next(category: "drama", letter: nil)
        precondition(fixture.requests == [1, 2, 2], "Append without resetting; retry same page; stop after last API page despite overlapping results")
        let letters = CatalogueFixture(); letters.pauseFirst = true
        let az = ContinuousCatalogueStore(api: DiscoveryAPI(fetch: letters.fetch))
        let first = Task { await az.next(category: nil, letter: "a") }
        await Task.yield()
        await az.next(category: nil, letter: "a")
        await first.value
        precondition(letters.requests == [1] && az.shows.count == 2, "Concurrent visible rows share one request")
        print("PASS: continuous category/A–Z append, duplicate removal, retained rows on failure, retry, final-page stop and concurrent request guard")
    }
}
