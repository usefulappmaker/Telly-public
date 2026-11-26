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
        // Single episodes are separate from programmes, newest first, and kept per profile.
        let second = Programme(id:"p0000002",title:"Two",summary:"",image:nil,version:"",guidance:nil)
        restored.toggle(episode,in:show);restored.toggle(second,in:show)
        precondition(restored.savedEpisodes.map(\.id)==["p0000002","p0000001"] && restored.contains(episode) && !restored.contains(show),"Saving an episode leaves its programme unsaved")
        precondition(restored.savedEpisodes[0].show?.id==show.id && restored.savedEpisodes[0].show?.episodes.isEmpty==true,"A saved episode remembers its programme without the episode list")
        restored.toggle(show);restored.toggle(second,in:show)
        let relaunched = Library(defaults:defaults)
        precondition(relaunched.savedEpisodes.map(\.id)==["p0000001"] && relaunched.contains(show),"Removing an episode keeps the other and the programme, across launches")
        restored.toggle(show)
        precondition(Library(defaults:defaults).contains(episode),"Removing a programme keeps its saved episode")
        let profile = UserDefaults.standard.string(forKey:ProfileStore.currentKey)
        UserDefaults.standard.set("someone-else",forKey:ProfileStore.currentKey)
        precondition(Library(defaults:defaults).savedEpisodes.isEmpty,"Another profile has its own saved episodes")
        UserDefaults.standard.set(profile,forKey:ProfileStore.currentKey)
        let oldJSON = Data("[{\"id\":\"p0000001\",\"title\":\"Old episode\",\"summary\":\"\",\"version\":\"\"},{\"id\":\"p0000002\",\"title\":\"Second episode\",\"summary\":\"\",\"version\":\"\"}]".utf8)
        defaults.set(oldJSON,forKey:"saved")
        await restored.migrate(resolve:{_ in show})
        precondition(restored.saved.count==1 && restored.saved[0].id==show.id && defaults.data(forKey:"saved")==nil,"Old saved episodes migrate to one parent show")
        defaults.set(oldJSON,forKey:"saved")
        await restored.migrate(resolve:{_ in throw BBCError.message("Offline")})
        precondition(defaults.data(forKey:"saved") != nil && restored.migrationWarning != nil,"Failed migration retains old data for retry")
        print("PASS: programme-level and single-episode saves, per-profile, deduplication, persistence, legacy episode migration and failure recovery")
    }
}
