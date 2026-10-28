import Foundation

@main struct UnifiedCategoryTests {
    static func main() async throws {
        let bbc = try JSONDecoder().decode([Genre].self, from: Data(contentsOf: URL(fileURLWithPath: "Telly/BBCGenreSeed.json")))
        let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Telly/ITVCatalogueSeed.json"))) as! [String: [String: Any]]
        let itv = ITVCatalogueAPI.categories(seed["/watch/categories/drama-soaps"]!)
        let groups = UnifiedCategory.make(bbc: bbc, itv: itv)
        precondition(groups.count == 16)
        precondition(groups.filter { $0.providers.count == 2 }.count == 9)
        precondition(groups.flatMap(\.bbc).count == bbc.count && groups.flatMap(\.itv).count == itv.count, "Every category remains reachable")
        let films = groups.first { $0.id == "films" }!
        precondition(films.title == "Films" && films.bbc.first?.id == "films" && films.itv.first?.path == "/watch/categories/films")
        precondition(groups.first { $0.id == "documentaries-lifestyle" }!.bbc.map(\.id) == ["documentaries", "lifestyle"])
        precondition(Set(groups.first { $0.id == "kids" }!.bbc.map(\.id)) == ["cbbc", "cbeebies"])
        precondition(groups.first { $0.id == "signed" }!.itv.first?.id == "signed-bsl")
        precondition(groups.first { $0.id == "music" }!.providers == [.bbc])
        precondition(UnifiedCategory.make(bbc: bbc + bbc, itv: itv + itv).flatMap(\.bbc).count == bbc.count, "Repeated metadata does not duplicate source routes")
        let unique = ITVCategory(id: "true-crime", title: "True Crime", path: "/watch/categories/true-crime")
        precondition(UnifiedCategory.make(bbc: [], itv: [unique]).first?.providers == [.itv])
        let shared = UnifiedCategory.make(bbc: [Genre(id: "crime", title: "True Crime")], itv: [unique])
        precondition(shared.count == 1 && shared.first?.providers.count == 2, "New equivalent titles merge without a hardcoded route")
        let directory = try JSONSerialization.data(withJSONObject: ["categories": [
            ["id": "films", "title": "Films", "kind": "genre"],
            ["id": "signed", "title": "Signed", "kind": "accessibility"],
            ["id": "cbbc", "title": "CBBC", "kind": "childrens"],
            ["id": "scotland", "title": "Scotland", "kind": "national"]]])
        let parsed = try await DiscoveryAPI(fetch: { _ in directory }).genres()
        precondition(parsed.map(\.id) == ["films", "signed", "cbbc"])
        print("PASS: 16 unified categories, 9 shared by BBC/ITV, all source routes preserved, grouped subcategories, unique topics, metadata deduplication and children's/signed discovery")
    }
}
