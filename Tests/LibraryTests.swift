import Foundation
@main struct LibraryTests {
    @MainActor static func main() async throws {
        let name = "TellyTests-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let episode = Programme(id:"p0000001",title:"One",summary:"",image:nil,version:"",guidance:nil)
        let show = CatalogueShow(id:"b0000001",title:"A programme",summary:"",image:nil,letter:"a",channel:"BBC",categories:[],expectedEpisodes:3,singleEpisode:false,episodes:[CatalogueEpisode(programme:episode,subtitle:"1",duration:"",sliceID:"s1",seriesTitle:"Series 1")],indexedAt:Date())
        let library = Library(defaults:defaults)
        library.save(show);library.save(show)
        precondition(library.saved.count==1 && library.saved[0].episodes.isEmpty,"Saving stores the parent, deduplicates and strips episodes")
        let restored = Library(defaults:defaults)
        precondition(restored.contains(show),"Saved programme persists across launches")
        restored.remove(show)
        precondition(!Library(defaults:defaults).contains(show),"Removal persists")
        let oldJSON = Data("[{\"id\":\"p0000001\",\"title\":\"Old episode\",\"summary\":\"\",\"version\":\"\"},{\"id\":\"p0000002\",\"title\":\"Second episode\",\"summary\":\"\",\"version\":\"\"}]".utf8)
        defaults.set(oldJSON,forKey:"saved")
        await restored.migrate(resolve:{_ in show})
        precondition(restored.saved.count==1 && restored.saved[0].id==show.id && defaults.data(forKey:"saved")==nil,"Old saved episodes migrate to one parent show")
        defaults.set(oldJSON,forKey:"saved")
        await restored.migrate(resolve:{_ in throw BBCError.message("Offline")})
        precondition(defaults.data(forKey:"saved") != nil && restored.migrationWarning != nil,"Failed migration retains old data for retry")
        print("PASS: programme-level saves, deduplication, persistence, legacy episode migration and failure recovery")
    }
}
