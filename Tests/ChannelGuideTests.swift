// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct ChannelGuideTests {
    static func main() async throws {
        func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        func at(_ raw: String) -> Date { ISO8601DateFormatter().date(from: raw)! }
        func entry(_ id: String, _ start: String, _ end: String) -> GuideEntry {
            GuideEntry(id: id, start: at(start), end: at(end), title: id, subtitle: "", synopsis: "", episodeID: nil, onDemand: false, isRepeat: false)
        }

        // The window opens half an hour before the current half-hour, in whole half-hours.
        let now = at("2026-10-19T12:40:00Z")
        check(ChannelGuide.origin(for: now) == at("2026-10-19T12:00:00Z"), "Guide opens half an hour before the current half-hour")
        check(ChannelGuide.origin(for: at("2026-10-19T12:30:00Z")) == at("2026-10-19T12:00:00Z"), "A half-hour boundary belongs to the slot it starts")
        check(ChannelGuide.origin(for: now, hoursBack: 8) == at("2026-10-19T04:00:00Z"), "Earlier programmes extend the window by whole hours")
        check(ChannelGuide.stamp(at("2026-10-19T04:00:00Z")) == "2026-10-19T04:00", "BBC from_date is minute precision in UTC without a zone suffix")

        let schedule = Data(#"""
        {"broadcasts":{"elements":[
        {"id":"b1","scheduled_start":"2026-10-19T12:00:00Z","scheduled_end":"2026-10-19T13:00:00Z","repeat":true,
         "episode":{"id":"p0000001","title":"Later","subtitle":"Series 1: Episode 1","status":"available","synopses":{"medium":"","small":"Short","large":"Long"}}},
        {"id":"b0","scheduled_start":"2026-10-19T11:00:00.000Z","scheduled_end":"2026-10-19T12:00:00.000Z",
         "episode":{"title":"Earlier","status":"unavailable","synopses":{"medium":"Medium"}}},
        {"id":"b1","scheduled_start":"2026-10-19T12:00:00Z","scheduled_end":"2026-10-19T13:00:00Z","episode":{"title":"Duplicate"}},
        {"id":"b2","scheduled_start":"2026-10-19T13:00:00Z","scheduled_end":"2026-10-19T14:00:00Z","blanked":true,"episode":{"title":"Blanked"}},
        {"id":"b3","scheduled_start":"2026-10-19T14:00:00Z","scheduled_end":"2026-10-19T14:00:00Z","episode":{"title":"No duration"}},
        {"id":"b4","scheduled_start":"2026-10-19T15:00:00Z","scheduled_end":"2026-10-19T16:00:00Z"}
        ]}}
        """#.utf8)
        let entries = ChannelGuide.entries(schedule)
        check(entries.map(\.id) == ["b0", "b1"], "Blanked, duplicate, empty and episode-less broadcasts are dropped; the rest sort by start")
        let earlier = entries[0], later = entries[1]
        check(earlier.start == at("2026-10-19T11:00:00Z") && earlier.synopsis == "Medium", "Fractional-second dates and the medium synopsis are read")
        check(!earlier.onDemand && earlier.episodeID == nil && !earlier.isRepeat, "Only episodes BBC lists as available are offered on demand")
        check(later.onDemand && later.episodeID == "p0000001" && later.isRepeat, "Available episodes keep their identifier and repeat flag")
        check(later.subtitle == "Series 1: Episode 1" && later.synopsis == "Short", "An empty synopsis falls back to the next length")
        check(earlier.isPast(at: now) && !earlier.isOnAir(at: now), "A finished programme is past")
        check(later.isOnAir(at: now) && !later.isPast(at: now), "The programme spanning now is on air")
        check(later.isPast(at: later.end) && !later.isOnAir(at: later.end), "A programme ends at its scheduled end")
        check(ChannelGuide.entries(Data("<html>Service Temporarily Unavailable</html>".utf8)).isEmpty, "A non-JSON response yields an empty schedule")

        // 12:00–12:30, a quarter-hour gap, 12:45–13:30, then a broadcast overlapping the previous one.
        let row = [entry("a", "2026-10-19T12:00:00Z", "2026-10-19T12:30:00Z"), entry("b", "2026-10-19T12:45:00Z", "2026-10-19T13:30:00Z"),
                   entry("hidden", "2026-10-19T13:00:00Z", "2026-10-19T13:20:00Z"), entry("c", "2026-10-19T13:15:00Z", "2026-10-19T14:00:00Z")]
        let segments = ChannelGuide.segments(row, from: at("2026-10-19T12:10:00Z"), to: at("2026-10-19T13:45:00Z"))
        check(segments.map { $0.entry?.id ?? "gap" } == ["a", "gap", "b", "c"], "Programmes and gaps alternate; a broadcast hidden by the previous one is skipped")
        check(segments.map(\.minutes) == [20, 15, 45, 15], "Segments are clipped to the window and an overlap starts where the previous programme ended")
        check(segments.map(\.minutes).reduce(0, +) == 95, "Segments fill the window exactly, so every row keeps the same width")
        let late = ChannelGuide.segments([row[1]], from: at("2026-10-19T12:00:00Z"), to: at("2026-10-19T13:00:00Z"))
        check(late.map { $0.entry?.id ?? "gap" } == ["gap", "b"] && late.map(\.minutes) == [45, 15], "A row starting late opens with a gap")
        check(ChannelGuide.segments(row, from: at("2026-10-19T15:00:00Z"), to: at("2026-10-19T16:00:00Z")).isEmpty, "Nothing scheduled in the window leaves the row empty")

        // Remote navigation: Up and Down land on the programme at the focus time; Left and Right page at the window's edges.
        func playable(_ id: String, _ start: String, _ end: String, onDemand: Bool = true) -> GuideEntry {
            GuideEntry(id: id, start: at(start), end: at(end), title: id, subtitle: "", synopsis: "", episodeID: nil, onDemand: onDemand, isRepeat: false)
        }
        let day = [playable("past", "2026-10-19T10:00:00Z", "2026-10-19T11:00:00Z", onDemand: false),
                   playable("morning", "2026-10-19T11:00:00Z", "2026-10-19T12:15:00Z"),
                   playable("noon", "2026-10-19T12:15:00Z", "2026-10-19T13:00:00Z"),
                   playable("film", "2026-10-19T13:00:00Z", "2026-10-19T15:30:00Z"),
                   playable("late", "2026-10-19T15:30:00Z", "2026-10-19T16:00:00Z")]
        let open = at("2026-10-19T12:00:00Z"), span: TimeInterval = 2.5 * 3600, first = at("2026-10-19T04:00:00Z"), last = at("2026-10-19T18:00:00Z")
        func land(_ time: String) -> String? { ChannelGuide.landing(in: day, at: at(time), from: open, to: open.addingTimeInterval(span))?.id }
        check(land("2026-10-19T12:40:00Z") == "noon", "Up and Down land on the programme showing at the focus time")
        check(land("2026-10-19T13:00:00Z") == "film", "At a programme boundary the one starting wins over the one ending")
        check(land("2026-10-19T12:00:00Z") == "morning", "A programme that began before the window still counts at its left edge")
        check(ChannelGuide.landing(in: [day[0]], at: at("2026-10-19T10:30:00Z"), from: open.addingTimeInterval(-7200), to: open)?.id == "past",
              "A programme that can no longer be watched still takes focus, so the column is kept")
        check(ChannelGuide.landing(in: [day[0]], at: open, from: open, to: open.addingTimeInterval(span)) == nil, "A row with nothing on screen is skipped")
        check(ChannelGuide.landing(in: [day[0], day[4]], at: open, from: at("2026-10-19T10:00:00Z"), to: at("2026-10-19T16:00:00Z"))?.id == "past",
              "In a gap in the schedule, the nearest programme is chosen")
        func page(_ id: String, _ forward: Bool, from start: Date = open) -> (String, Date)? {
            ChannelGuide.page(day, from: day.first { $0.id == id }!, forward: forward, start: start, span: span, earliest: first, latest: last).map { ($0.entry.id, $0.start) }
        }
        check(page("noon", true) == nil && page("noon", false) == nil, "A neighbour already on screen is left to the focus engine")
        check(page("film", true).map { $0 == ("late", at("2026-10-19T15:30:00Z")) } == true, "Right at the edge opens the window at the next programme")
        check(page("morning", false, from: at("2026-10-19T11:00:00Z")).map { $0 == ("past", at("2026-10-19T08:30:00Z")) } == true,
              "Programmes that can no longer be watched are paged to as well")
        check(page("past", false, from: at("2026-10-19T10:00:00Z")) == nil, "Nothing earlier in the guide: the window stays")
        check(page("film", false, from: at("2026-10-19T13:00:00Z")).map { $0 == ("noon", at("2026-10-19T10:30:00Z")) } == true,
              "Left at the edge brings the previous programme's end into view")
        let long = [playable("marathon", "2026-10-19T06:00:00Z", "2026-10-19T18:00:00Z")]
        let back = ChannelGuide.page(long, from: long[0], forward: false, start: open, span: span, earliest: first, latest: last)
        check(back?.entry.id == "marathon" && back!.start == at("2026-10-19T10:00:00Z"), "With nothing beyond a long programme, Left scrolls through it and keeps it focused")
        let ahead = ChannelGuide.page(long, from: long[0], forward: true, start: open, span: span, earliest: first, latest: last)
        check(ahead?.entry.id == "marathon" && ahead!.start == at("2026-10-19T14:00:00Z"), "Right scrolls through it too")
        check(ChannelGuide.page(long, from: long[0], forward: true, start: last.addingTimeInterval(-span), span: span, earliest: first, latest: last) == nil,
              "Scrolling stops at the end of the guide")

        let channels = [LiveChannel(id: "bbc_one_london", title: "BBC One"), LiveChannel(id: "bbc_two_england", title: "BBC Two"), LiveChannel(id: "bbc_four", title: "BBC Four")]
        let guide = await ChannelGuide.load(channels, from: at("2026-10-19T04:00:00Z"), perPage: 100) { url in
            guard url.absoluteString.hasSuffix("/broadcasts?per_page=100&from_date=2026-10-19T04:00") else { throw BBCError.message("Unexpected schedule request") }
            if url.path.contains("bbc_two_england") { throw BBCError.message("Schedule unavailable") }
            return schedule
        }
        check(guide.map(\.id) == channels.map(\.id), "Channels keep their order whichever schedule arrives first")
        check(guide[0].entries.count == 2 && guide[2].entries.count == 2 && guide[1].entries.isEmpty, "One unavailable schedule does not hide the others")
        // Long ranges page through the schedule until it reaches the requested time, without duplicates.
        func page(_ start: Int, count: Int) -> Data {
            let stamp = ISO8601DateFormatter()
            let items: [[String: Any]] = (0..<count).map { i in
                let from = at("2026-10-19T00:00:00Z").addingTimeInterval(Double(start + i) * 1800)
                return ["id": "p\(start + i)", "scheduled_start": stamp.string(from: from),
                        "scheduled_end": stamp.string(from: from.addingTimeInterval(1800)), "episode": ["title": "T"]]
            }
            return try! JSONSerialization.data(withJSONObject: ["broadcasts": ["elements": items]])
        }
        var requested = [String]()
        let paged = await ChannelGuide.load([channels[0]], from: at("2026-10-19T00:00:00Z"), until: at("2026-10-21T00:00:00Z"), perPage: 40) { url in
            requested.append(url.query ?? "")
            switch url.query?.components(separatedBy: "&page=").last {
            case "2": return page(39, count: 40)   // overlaps page 1 by one broadcast
            case "3": return page(79, count: 40)
            default: return page(0, count: 40)
            }
        }
        check(requested.count == 3 && requested[1].hasSuffix("&page=2"), "Pages are fetched until the schedule reaches the requested time")
        check(paged[0].entries.count == 119 && Set(paged[0].entries.map(\.id)).count == 119, "Broadcasts repeated across pages appear once")
        var single = 0
        _ = await ChannelGuide.load([channels[0]], from: at("2026-10-19T00:00:00Z"), perPage: 40) { _ in single += 1; return page(0, count: 40) }
        check(single == 1, "Without an end time only the first page is fetched")
        // Channel 4's own guide: catch-up programmes keep their programme ID for playback; slots are per channel.
        let c4 = Data(#"""
        {"channels":{"C4":{"id":"C4","programmes":[
          {"slotId":"1-1","startDate":"2026-10-19T12:00:00.000Z","endDate":"2026-10-19T12:30:00.000Z","title":"Earlier","summary":"S","isOnCatchup":true,"programmeId":"37854-009","isRepeat":true},
          {"slotId":"1-2","startDate":"2026-10-19T12:30:00.000Z","endDate":"2026-10-19T13:00:00.000Z","brandTitle":"Later","isOnCatchup":false,"programmeId":"bad id"}]},
          "XX!":{"programmes":[{"slotId":"x","startDate":"2026-10-19T12:00:00Z","endDate":"2026-10-19T13:00:00Z","title":"Ignored"}]}}}
        """#.utf8)
        let c4Rows = ChannelGuide.channel4Entries(c4)
        check(Set(c4Rows.keys) == ["c4:C4"], "Channel 4 rows are keyed by channel code; malformed codes are dropped")
        check(c4Rows["c4:C4"]?.map(\.title) == ["Earlier", "Later"], "Titles fall back to the brand title")
        check(c4Rows["c4:C4"]?[0].episodeID == "c4:37854-009" && c4Rows["c4:C4"]?[0].onDemand == true && c4Rows["c4:C4"]?[0].isRepeat == true,
              "A catch-up slot keeps its programme ID for on-demand playback")
        check(c4Rows["c4:C4"]?[1].episodeID == nil && c4Rows["c4:C4"]?[1].onDemand == false, "A malformed programme ID is never offered on demand")

        // Freeview's guide: ITV and Channel 5 rows matched by channel name, ISO 8601 durations.
        let fv = Data(#"""
        {"status":"success","data":{"programs":[
          {"title":"ITV1","events":[{"uuid":"a","main_title":"News","secondary_title":"Evening","start_time":"2026-10-19T18:00:00+0000","duration":"PT30M"},
                                    {"uuid":"b","main_title":"Film","start_time":"2026-10-19T18:30:00+0000","duration":"PT2H15M"}]},
          {"title":"5USA","events":[{"uuid":"c","main_title":"NCIS","start_time":"2026-10-19T18:00:00+0000","duration":"PT1H"}]},
          {"title":"BBC ONE Lon","events":[{"uuid":"d","main_title":"Not ours","start_time":"2026-10-19T18:00:00+0000","duration":"PT1H"}]}]}}
        """#.utf8)
        let fvRows = ChannelGuide.freeviewEntries(fv)
        check(Set(fvRows.keys) == ["itv:itv", "c5:C7"], "Freeview rows map to Telly's ITV and Channel 5 channels only")
        check(fvRows["itv:itv"]?.map(\.title) == ["News", "Film"] && fvRows["itv:itv"]?[0].subtitle == "Evening", "Freeview titles and episode titles are read")
        check(fvRows["itv:itv"]?[1].end == at("2026-10-19T20:45:00Z"), "Durations set the end time")
        check(ChannelGuide.duration("PT1H30M20S") == 5420 && ChannelGuide.duration("PT45M") == 2700 && ChannelGuide.duration("45M") == nil, "ISO 8601 durations parse")
        check(ChannelGuide.ukDays(from: at("2026-10-18T23:30:00Z"), until: at("2026-10-20T00:30:00Z")) == ["2026-10-19", "2026-10-20"],
              "UK days follow British time, not UTC")

        // One load covers every provider; each feed is only asked for its own channels.
        var c4Asked = [String](), fvAsked = 0, bbcAsked = 0
        let mixed = [LiveChannel(id: "bbc_four", title: "BBC Four"), LiveChannel(id: "c4:C4", title: "Channel 4"),
                     LiveChannel(id: "itv:itv", title: "ITV1"), LiveChannel(id: "c5:C5CH01", title: "A FAST channel")]
        let loaded = await ChannelGuide.load(mixed, from: at("2026-10-19T10:00:00Z"), until: at("2026-10-19T20:00:00Z"), perPage: 100,
                                             channel4: { url in c4Asked.append(url.lastPathComponent); return c4 },
                                             freeview: { _ in fvAsked += 1; return fv }) { _ in bbcAsked += 1; return schedule }
        check(loaded.map(\.id) == mixed.map(\.id), "Rows keep the channel order")
        check(loaded[0].entries.count == 2 && loaded[1].entries.count == 2 && loaded[2].entries.count == 2 && loaded[3].entries.isEmpty,
              "BBC, Channel 4 and Freeview rows fill in; a channel without a schedule source stays empty")
        check(c4Asked == ["2026-10-19"] && fvAsked == 1 && bbcAsked >= 1, "Each guide is fetched once per day it covers")
        print("PASS: guide window, schedule parsing, on-demand flags, timeline segments, remote navigation, paged loading, Channel 4 and Freeview guides and independent channel loading")
    }
}
