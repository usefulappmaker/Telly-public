import Foundation

@main struct WatchHistoryTests {
    @MainActor static func main() throws {
        func episode(_ id: String, season: Int = 1, number: Int, date: String? = nil) -> CatalogueEpisode {
            var programme = Programme(id: id, title: "Example", summary: "", image: nil, version: "v0000001", guidance: nil)
            programme.showID = "b0000001"; programme.showTitle = "Example"; programme.episodeSubtitle = "Series \(season): \(number). Episode title"
            return CatalogueEpisode(programme: programme, subtitle: programme.episodeSubtitle!, duration: "1 hour", sliceID: "s\(season)", seriesTitle: "Series \(season)", parentPosition: number, broadcastDate: date)
        }
        let one = episode("b0000002", number: 1), two = episode("b0000003", number: 2), three = episode("b0000004", number: 3), nextSeries = episode("b0000005", season: 2, number: 1)
        var show = CatalogueShow(id: "b0000001", title: "Example", summary: "", image: nil, letter: "e", channel: "BBC", categories: [], expectedEpisodes: 4, singleEpisode: false, episodes: [nextSeries, three, two, one], indexedAt: Date())
        precondition(EpisodeSequence.ordered(show.episodes).map(\.id) == [one.id, two.id, three.id, nextSeries.id], "Programme page starts at Episode 1, in series order")
        precondition(EpisodeSequence.orderedSeries(show.series).map(\.title) == ["Series 1", "Series 2"], "Chronological series ordering remains available for succession")
        precondition(EpisodeSequence.next(after: one, in: show)?.id == two.id, "API newest-first must not reverse watch order")
        precondition(EpisodeSequence.next(after: three, in: show)?.id == nextSeries.id, "Advance to the first episode of the next series")
        precondition(EpisodeSequence.next(after: nextSeries, in: show) == nil, "Final episode has no invented successor")
        precondition(EpisodeSequence.latestSeries(show.series)?.title == "Series 2", "Programme page defaults to most recent season")
        precondition(EpisodeSequence.displayed([three,two,one],in:show).map(\.id) == [one.id,two.id,three.id], "Normal series keep forward episode order")
        var soap = show
        soap.title = "EastEnders"; soap.categories = ["drama-and-soaps","soaps"]
        precondition(EpisodeSequence.newestFirst(soap), "Use available soap category tags")
        precondition(EpisodeSequence.displayed([one,two,three],in:soap).map(\.id) == [three.id,two.id,one.id], "Soaps browse newest first")
        precondition(EpisodeSequence.next(after: one,in:soap)?.id == two.id, "Descending browsing never reverses autoplay")
        var doubleOne = one, doubleTwo = two, tomorrow = three
        doubleOne.broadcastDate = "2026-10-27T06:00:00Z"; doubleTwo.broadcastDate = doubleOne.broadcastDate
        tomorrow.broadcastDate = "2026-10-28T06:00:00Z"
        soap.episodes = [tomorrow,doubleTwo,doubleOne]
        precondition(EpisodeSequence.next(after:doubleOne,in:soap)?.id == doubleTwo.id,"Same-time double bill uses episode position before tomorrow")
        soap.categories = []
        precondition(EpisodeSequence.newestFirst(soap), "Known soap fallback when tags are omitted")
        soap.title = "Long-running documentary"; soap.expectedEpisodes = 1011
        precondition(!EpisodeSequence.newestFirst(soap), "Episode count alone must not reverse a programme")
        let oldYear = CatalogueEpisode(programme:one.programme,subtitle:"Old",duration:"",sliceID:"year25",seriesTitle:"2025",broadcastDate:"2025-12-31T20:00:00Z")
        let newYear = CatalogueEpisode(programme:two.programme,subtitle:"New",duration:"",sliceID:"year26",seriesTitle:"2026",broadcastDate:"2026-01-01T20:00:00Z")
        soap.episodes = [oldYear,newYear]
        precondition(EpisodeSequence.latestSeries(soap.series)?.title == "2026", "Year-based series select latest year")
        let unknownA = CatalogueSeries(id:"a",title:"Specials",episodes:[oldYear]), unknownB = CatalogueSeries(id:"b",title:"Episodes",episodes:[newYear])
        precondition(EpisodeSequence.latestSeries([unknownA,unknownB])?.id == "b", "Undated season labels use episode broadcast dates")
        soap.title = "EastEnders"
        let archive = (1...1011).map { episode("archive-\($0)",number:$0) }
        precondition(EpisodeSequence.displayed(archive,in:soap).prefix(30).map(\.id) == (982...1011).reversed().map { "archive-\($0)" }, "First page of a 1,011-episode soap archive contains the newest thirty")
        let now = Date(timeIntervalSince1970:1000), countdown = NextEpisodeCountdown(now:Date(timeIntervalSince1970:1000))
        precondition(countdown.remaining(at:now) == 15 && countdown.remaining(at:now.addingTimeInterval(14.2)) == 1, "Fifteen second countdown")
        precondition(countdown.remaining(at:now.addingTimeInterval(15)) == 0 && countdown.remaining(at:now.addingTimeInterval(100)) == 0,"Countdown reaches zero without going negative")
        show.episodes.removeAll { $0.id == one.id }
        precondition(EpisodeSequence.next(after: one, in: show)?.id == two.id, "Completed episode can expire without losing next-episode ordering")
        var dated = CatalogueEpisode(programme: one.programme, subtitle: "Monday", duration: "", sliceID: "days", seriesTitle: "Episodes", broadcastDate: "2026-10-12T20:00:00.000Z")
        var datedNext = CatalogueEpisode(programme: two.programme, subtitle: "Tuesday", duration: "", sliceID: "days", seriesTitle: "Episodes", broadcastDate: "2026-10-13T20:00:00.000Z")
        show.episodes = [datedNext, dated]
        precondition(EpisodeSequence.next(after: dated, in: show)?.id == datedNext.id, "Unnumbered episodes use broadcast dates")
        dated.broadcastDate = nil; datedNext.broadcastDate = nil; show.episodes = [datedNext, dated]
        precondition(EpisodeSequence.next(after: dated, in: show) == nil, "Do not guess order without metadata")
        show.episodes = [three, two, one]; show.expectedEpisodes = 3
        let suite = "TellyHistoryTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = WatchHistory(defaults: defaults)
        history.update(episode: one, show: show, next: two, position: 120, duration: 3600)
        precondition(history.records.count == 1 && history.resumePosition(for: one.id) == 120, "Save resume position")
        precondition(history.records[0].show?.episodes.isEmpty == true, "History never embeds a full show catalogue")
        let reopened = WatchHistory(defaults: defaults)
        precondition(reopened.resumePosition(for: one.id) == 120 && reopened.records[0].nextEpisode?.id == two.id, "Progress and next episode persist across launches")
        let time = history.records[0].updatedAt
        history.update(episode: one, show: show, next: two, position: 120, duration: 3600)
        precondition(history.records[0].updatedAt == time, "Paused clock does not rewrite history or recency")
        history.update(episode: one, show: show, next: two, position: 3480, duration: 3600)
        precondition(history.records[0].completed && history.records[0].target?.id == two.id && history.resumePosition(for: one.id) == 0, "Finished episode offers the next episode")
        history.update(episode: two, show: show, next: three, position: 50, duration: 3600)
        precondition(history.records.count == 1 && history.records[0].episode.id == two.id && !history.records[0].completed, "Only one entry per programme, following the episode now watched")
        history.update(episode: two, show: show, next: nil, position: 55, duration: 3600)
        precondition(history.records[0].nextEpisode?.id == three.id, "Keep a known successor when a compact show is used")
        history.update(episode: two, show: show, next: three, position: 5, duration: 3600)
        precondition(history.resumePosition(for: two.id) == 5, "Start over replaces the bookmark after playback actually advances")
        history.update(episode: two, show: show, next: three, position: .nan, duration: 3600)
        history.update(episode: two, show: show, next: three, position: 100, duration: .infinity)
        precondition(history.resumePosition(for: two.id) == 5, "Unknown/invalid media times do not corrupt saved progress")
        history.update(episode: two, show: show, next: three, position: 3600, duration: 3600, ended: true)
        precondition(history.records[0].completed, "Actual end notification marks completion")
        precondition(!WatchHistory.isComplete(position: 3420, duration: 3600), "95 percent alone does not skip more than two minutes")
        precondition(WatchHistory.isComplete(position: 95, duration: 100), "Completion scales to short programmes")
        history.remove(show.id)
        precondition(WatchHistory(defaults: defaults).records.isEmpty, "Removing a programme persists")
        defaults.set(Data("bad JSON".utf8), forKey: "continueWatching-v1")
        let corrupt = WatchHistory(defaults: defaults)
        precondition(corrupt.records.isEmpty && corrupt.warning != nil, "Corrupt history does not prevent launch")
        corrupt.update(episode: one, show: show, next: two, position: 15, duration: 3600)
        precondition(corrupt.warning == nil && WatchHistory(defaults: defaults).records.count == 1, "New progress recovers from corrupt storage")
        print("PASS: latest season/year selection, soap archive ordering, chronological succession, 15-second deadline, history persistence and recovery")
    }
}
