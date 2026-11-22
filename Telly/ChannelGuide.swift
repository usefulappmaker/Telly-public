// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One scheduled broadcast on a live channel.
struct GuideEntry: Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date
    let title: String
    let subtitle: String
    let synopsis: String
    let episodeID: String?
    /// The broadcaster already lists this episode as available on demand (episodeID: a BBC pid, or "c4:<programme id>").
    let onDemand: Bool
    let isRepeat: Bool
    /// A past programme the broadcaster doesn't flag as on demand, but whose catalogue we can search to try to find it
    /// (ITV: the Freeview schedule says nothing about catch-up, so an earlier ITV programme is looked up on ITVX when
    /// the user selects it). nil when there is nothing to look up.
    var catchUp: ContentProvider? = nil
    func isOnAir(at date: Date) -> Bool { start <= date && date < end }
    func isPast(at date: Date) -> Bool { end <= date }
}

struct GuideChannel: Identifiable {
    let channel: LiveChannel
    let entries: [GuideEntry]
    var id: String { channel.id }
}

/// A stretch of one channel's row in the guide: a programme, or an unscheduled gap.
struct GuideSegment: Identifiable {
    let id: String
    let entry: GuideEntry?
    let start: Date
    let end: Date
    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

enum ChannelGuide {
    /// The guide opens half an hour before the current half-hour, so the programme on air keeps a
    /// readable width. `hoursBack` extends the window to earlier programmes.
    static func origin(for now: Date, hoursBack: Int = 0) -> Date {
        Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 1800).rounded(.down) * 1800 - 1800 - Double(hoursBack) * 3600)
    }
    /// BBC's `from_date` accepts only minute precision in UTC, without a zone suffix.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }
    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    static func times(_ entry: GuideEntry) -> String { "\(clock(entry.start)) – \(clock(entry.end))" }
    /// BBC returns each channel's schedule from the programme on air at the requested time (default: now) onwards.
    static func entries(_ data: Data) -> [GuideEntry] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let values = (root?["broadcasts"] as? [String: Any])?["elements"] as? [[String: Any]] ?? []
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ raw: Any?) -> Date? { (raw as? String).flatMap { fractional.date(from: $0) ?? plain.date(from: $0) } }
        var seen = Set<String>()
        return values.compactMap { broadcast -> GuideEntry? in
            guard let start = date(broadcast["scheduled_start"]), let end = date(broadcast["scheduled_end"]), end > start,
                  broadcast["blanked"] as? Bool != true,
                  let episode = broadcast["episode"] as? [String: Any], let title = episode["title"] as? String else { return nil }
            let id = broadcast["id"] as? String ?? "\(start.timeIntervalSince1970)"
            guard seen.insert(id).inserted else { return nil }
            let synopses = episode["synopses"] as? [String: Any] ?? [:]
            let episodeID = (episode["id"] as? String).flatMap { try? BBCService.pid($0) }
            return GuideEntry(id: id, start: start, end: end, title: title, subtitle: episode["subtitle"] as? String ?? "",
                              synopsis: ["medium", "small", "large"].compactMap { synopses[$0] as? String }.first { !$0.isEmpty } ?? "",
                              episodeID: episodeID, onDemand: episode["status"] as? String == "available",
                              isRepeat: broadcast["repeat"] as? Bool == true)
        }.sorted { $0.start < $1.start }
    }
    /// Every channel's schedule: BBC from iPlayer, Channel 4 from its own TV guide, ITV and Channel 5 from Freeview's
    /// guide. A channel without a schedule source gets an empty row; one unavailable feed never hides the others.
    static func load(_ channels: [LiveChannel], from origin: Date? = nil, until: Date? = nil, perPage: Int = 50, maxPages: Int = 12,
                     channel4: @escaping (URL) async throws -> Data = { try await Channel4HTTP.shared.data($0) },
                     freeview: @escaping (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 },
                     itv: @escaping (URL) async throws -> Data = { try await ITVLiveAPI().fetch($0) },
                     channel5: @escaping (URL) async throws -> Data = { try await Channel5HTTP.shared.data($0) },
                     fetch: @escaping (URL) async throws -> Data = { try await BBCService().fetch($0) }) async -> [GuideChannel] {
        let start = origin ?? Date(), end = until ?? start.addingTimeInterval(86400)
        async let bbc = loadBBC(channels.filter { $0.provider == .bbc }, from: origin, until: until, perPage: perPage, maxPages: maxPages, fetch: fetch)
        async let c4 = loadChannel4(channels.filter { $0.provider == .channel4 }, from: start, until: end, fetch: channel4)
        async let fv = loadFreeview(channels.filter { freeviewNames[$0.id] != nil }, from: start, until: end, fetch: freeview)
        async let nowNext = loadNowNext(channels.filter { [.itv, .channel5].contains($0.provider) && freeviewNames[$0.id] == nil }, itv: itv, channel5: channel5)
        var rows = [String: [GuideEntry]]()
        for (id, entries) in await nowNext { rows[id] = entries }
        for row in await bbc { rows[row.id] = row.entries }
        for (id, entries) in await c4 { rows[id] = entries }
        for (id, entries) in await fv { rows[id] = entries }
        return channels.map { GuideChannel(channel: $0, entries: rows[$0.id] ?? []) }
    }

    // MARK: Channel 4: its TV guide lists a UK day per request, a week back and ten days ahead.
    static func channel4Entries(_ data: Data) -> [String: [GuideEntry]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let channels = root["channels"] as? [String: Any] else { return [:] }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ raw: Any?) -> Date? { (raw as? String).flatMap { fractional.date(from: $0) ?? plain.date(from: $0) } }
        var result = [String: [GuideEntry]]()
        for (code, value) in channels {
            guard code.range(of: "^[A-Z0-9]{2,3}$", options: .regularExpression) != nil,
                  let programmes = (value as? [String: Any])?["programmes"] as? [[String: Any]] else { continue }
            result["c4:" + code] = programmes.compactMap { slot -> GuideEntry? in
                guard let start = date(slot["startDate"]), let end = date(slot["endDate"]), end > start,
                      let title = (slot["title"] ?? slot["brandTitle"]) as? String, !title.isEmpty else { return nil }
                let slotID = slot["slotId"] as? String ?? "\(start.timeIntervalSince1970)"
                let programme = (slot["programmeId"] as? String).flatMap { $0.range(of: #"^[0-9]+-[0-9]+$"#, options: .regularExpression) != nil ? $0 : nil }
                let catchUp = slot["isOnCatchup"] as? Bool == true && programme != nil
                return GuideEntry(id: "c4:\(code):\(slotID)", start: start, end: end, title: title, subtitle: "",
                                  synopsis: slot["summary"] as? String ?? "", episodeID: programme.map { "c4:" + $0 },
                                  onDemand: catchUp, isRepeat: slot["isRepeat"] as? Bool == true)
            }
        }
        return result
    }
    static func loadChannel4(_ channels: [LiveChannel], from start: Date, until end: Date,
                             fetch: @escaping (URL) async throws -> Data) async -> [String: [GuideEntry]] {
        guard !channels.isEmpty else { return [:] }
        let days = ukDays(from: start, until: end)
        let wanted = Set(channels.map(\.id))
        let batches = await withTaskGroup(of: [String: [GuideEntry]].self) { group in
            for day in days {
                group.addTask {
                    guard let url = URL(string: "https://www.channel4.com/tv-guide/api/" + day), let data = try? await fetch(url) else { return [:] }
                    return channel4Entries(data)
                }
            }
            var all = [[String: [GuideEntry]]]()
            for await batch in group { all.append(batch) }
            return all
        }
        return merge(batches, keeping: wanted)
    }

    // MARK: ITV and Channel 5: Freeview's guide lists every Freeview channel, a day per request, five days back.
    static let freeviewNames: [String: String] = [
        "itv:itv": "ITV1", "itv:itv2": "ITV2", "itv:itv3": "ITV3", "itv:itv4": "ITV4", "itv:itvbe": "ITVBe",
        "c5:C5": "5", "c5:C7": "5USA", "c5:C6": "5STAR", "c5:C0": "5ACTION", "c5:C8": "5DRAMA",
    ]
    /// Freeview's London listings (network id 64257); programmes are the same across regions apart from local news.
    static let freeviewNetwork = 64257
    static func freeviewEntries(_ data: Data) -> [String: [GuideEntry]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let programs = (root["data"] as? [String: Any])?["programs"] as? [[String: Any]] else { return [:] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let byName = Dictionary(freeviewNames.map { ($0.value.uppercased(), $0.key) }, uniquingKeysWith: { first, _ in first })
        var result = [String: [GuideEntry]]()
        for program in programs {
            guard let name = program["title"] as? String, let id = byName[name.uppercased()],
                  let events = program["events"] as? [[String: Any]] else { continue }
            result[id, default: []] += events.compactMap { event -> GuideEntry? in
                guard let raw = event["start_time"] as? String, let start = formatter.date(from: raw),
                      let length = duration(event["duration"] as? String), length > 0,
                      let title = event["main_title"] as? String, !title.isEmpty else { return nil }
                let key = event["uuid"] as? String ?? event["program_id"] as? String ?? "\(start.timeIntervalSince1970)"
                return GuideEntry(id: "fv:\(id):\(key)", start: start, end: start.addingTimeInterval(length), title: title,
                                  subtitle: event["secondary_title"] as? String ?? "", synopsis: "", episodeID: nil, onDemand: false, isRepeat: false,
                                  // ITV's earlier programmes can be looked up on ITVX; Channel 5's catalogue isn't wired up yet.
                                  catchUp: id.hasPrefix("itv:") ? .itv : nil)
            }
        }
        return result
    }
    /// ISO 8601 durations as Freeview writes them: PT2H15M, PT45M, PT1H30M20S.
    static func duration(_ raw: String?) -> TimeInterval? {
        guard let raw, raw.hasPrefix("PT") else { return nil }
        var total = 0.0, number = ""
        for ch in raw.dropFirst(2) {
            if ch.isNumber { number.append(ch); continue }
            guard let value = Double(number) else { return nil }
            switch ch { case "H": total += value * 3600; case "M": total += value * 60; case "S": total += value; default: return nil }
            number = ""
        }
        return number.isEmpty ? total : nil
    }
    static func loadFreeview(_ channels: [LiveChannel], from start: Date, until end: Date,
                             fetch: @escaping (URL) async throws -> Data) async -> [String: [GuideEntry]] {
        guard !channels.isEmpty else { return [:] }
        var day = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 86400).rounded(.down) * 86400)
        var starts = [Date]()
        while day < end { starts.append(day); day.addTimeInterval(86400) }
        let wanted = Set(channels.map(\.id))
        let batches = await withTaskGroup(of: [String: [GuideEntry]].self) { group in
            for day in starts {
                group.addTask {
                    let url = URL(string: "https://www.freeview.co.uk/api/tv-guide?nid=\(freeviewNetwork)&start=\(Int(day.timeIntervalSince1970))")!
                    // The feed sometimes answers with an empty body: try again briefly.
                    for attempt in 0..<3 {
                        if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000) }
                        if let data = try? await fetch(url) {
                            let entries = freeviewEntries(data)
                            if !entries.isEmpty { return entries }
                        }
                    }
                    return [:]
                }
            }
            var all = [[String: [GuideEntry]]]()
            for await batch in group { all.append(batch) }
            return all
        }
        return merge(batches, keeping: wanted)
    }

    // MARK: Streaming-only channels: ITV's now/next feed, and Channel 5's now-next feed (several hours ahead).
    static func itvNowNextEntries(_ data: Data) -> [String: [GuideEntry]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let channels = root["channels"] as? [[String: Any]] else { return [:] }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ raw: Any?) -> Date? { (raw as? String).flatMap { plain.date(from: $0) ?? fractional.date(from: $0) } }
        var result = [String: [GuideEntry]]()
        for channel in channels {
            guard let id = channel["id"] as? String, ITVLiveAPI.validID(id), let slots = channel["slots"] as? [String: Any] else { continue }
            let key = "itv:" + id.lowercased()
            result[key] = ["now", "next"].compactMap { slots[$0] as? [String: Any] }.compactMap { slot -> GuideEntry? in
                guard let start = date(slot["start"]), let end = date(slot["end"]), end > start,
                      let title = (slot["displayTitle"] ?? slot["brandTitle"] ?? slot["title"]) as? String, !title.isEmpty else { return nil }
                return GuideEntry(id: "itvnn:\(key):\(Int(start.timeIntervalSince1970))", start: start, end: end, title: title,
                                  subtitle: slot["detailedDisplayTitle"] as? String ?? "", synopsis: "", episodeID: nil, onDemand: false, isRepeat: false)
            }
        }
        return result
    }
    /// Channel 5's now-next feed lists start times only: each programme ends when the next begins.
    static func channel5NowNextEntries(_ data: Data, channel key: String) -> [GuideEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schedule = root["schedule"] as? [[String: Any]] else { return [] }
        let ordered = schedule.compactMap { slot -> (Double, String)? in
            guard let start = slot["tran_s"] as? Double, let title = slot["title"] as? String, !title.isEmpty else { return nil }
            return (start, title)
        }.sorted { $0.0 < $1.0 }
        return zip(ordered, ordered.dropFirst()).compactMap { this, next in
            guard next.0 > this.0 else { return nil }
            return GuideEntry(id: "c5nn:\(key):\(Int(this.0))", start: Date(timeIntervalSince1970: this.0), end: Date(timeIntervalSince1970: next.0),
                              title: this.1, subtitle: "", synopsis: "", episodeID: nil, onDemand: false, isRepeat: false)
        }
    }
    static func loadNowNext(_ channels: [LiveChannel], itv: @escaping (URL) async throws -> Data,
                            channel5: @escaping (URL) async throws -> Data) async -> [String: [GuideEntry]] {
        guard !channels.isEmpty else { return [:] }
        let wanted = Set(channels.map(\.id))
        return await withTaskGroup(of: [String: [GuideEntry]].self) { group in
            if channels.contains(where: { $0.provider == .itv }) {
                group.addTask { (try? await itv(ITVLiveAPI.feedURL)).map(itvNowNextEntries) ?? [:] }
            }
            for channel in channels where channel.provider == .channel5 {
                let code = String(channel.id.dropFirst(3))
                guard code.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
                      let url = URL(string: "https://feeds-api.channel5.com/feed/now-next/\(code).json") else { continue }
                group.addTask { (try? await channel5(url)).map { [channel.id: channel5NowNextEntries($0, channel: channel.id)] } ?? [:] }
            }
            var result = [String: [GuideEntry]]()
            for await batch in group { for (id, entries) in batch where wanted.contains(id) { result[id] = entries } }
            return result
        }
    }

    /// UK calendar days (yyyy-MM-dd) covering a stretch of time, for guides that list by day.
    static func ukDays(from start: Date, until end: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var day = calendar.startOfDay(for: start), days = [String]()
        while day < end, days.count < 21 {
            days.append(formatter.string(from: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }
    static func merge(_ batches: [[String: [GuideEntry]]], keeping wanted: Set<String>) -> [String: [GuideEntry]] {
        var result = [String: [GuideEntry]]()
        for batch in batches { for (id, entries) in batch where wanted.contains(id) { result[id, default: []] += entries } }
        return result.mapValues { entries in
            var seen = Set<String>()
            return entries.filter { seen.insert($0.id).inserted }.sorted { $0.start < $1.start }
        }
    }

    /// BBC: independent channel schedules from iPlayer. With `until`, further pages are fetched (up to `maxPages`)
    /// until the schedule reaches that time.
    static func loadBBC(_ channels: [LiveChannel], from origin: Date? = nil, until: Date? = nil, perPage: Int = 50, maxPages: Int = 12,
                        fetch: @escaping (URL) async throws -> Data) async -> [GuideChannel] {
        guard !channels.isEmpty else { return [] }
        let since = origin.map { "&from_date=" + stamp($0) } ?? ""
        return await withTaskGroup(of: (Int, GuideChannel).self) { group in
            for (index, channel) in channels.enumerated() {
                group.addTask {
                    var collected = [GuideEntry](), seen = Set<String>()
                    for page in 1...max(1, maxPages) {
                        let url = URL(string: "https://ibl.api.bbc.co.uk/ibl/v1/channels/\(channel.id)/broadcasts?per_page=\(perPage)\(since)" + (page > 1 ? "&page=\(page)" : ""))!
                        guard let data = try? await fetch(url) else { break }
                        let batch = entries(data)
                        collected += batch.filter { seen.insert($0.id).inserted }
                        // A short page is the end of the schedule; stop once it reaches the requested time.
                        guard let until, batch.count >= perPage / 2, let last = batch.last, last.end < until else { break }
                    }
                    return (index, GuideChannel(channel: channel, entries: collected.sorted { $0.start < $1.start }))
                }
            }
            var results = [(Int, GuideChannel)]()
            for await value in group { results.append(value) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
    /// Remote navigation shows a fixed stretch of time that pages at its edges. Up and Down keep a
    /// focus time, so moving between channels stays in the same column instead of jumping to
    /// whichever programme the focus engine reaches first.
    static func playable(_ entry: GuideEntry, at now: Date) -> Bool { !entry.isPast(at: now) || entry.onDemand || entry.catchUp != nil }
    static func halfHour(_ date: Date, roundingUp: Bool = false) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 1800).rounded(roundingUp ? .up : .down) * 1800)
    }
    /// The programme to land on in a row: the one showing at `time`, else the nearest one on screen. Programmes that
    /// can no longer be watched take focus too (greyed out), so Up and Down always have something directly beneath.
    static func landing(in entries: [GuideEntry], at time: Date, from start: Date, to end: Date) -> GuideEntry? {
        let shown = segments(entries, from: start, to: end).compactMap(\.entry)
        func distance(_ entry: GuideEntry) -> TimeInterval {
            // The programme showing at `time` wins outright, including over one that ends exactly then.
            entry.isOnAir(at: time) ? -1 : min(abs(entry.start.timeIntervalSince(time)), abs(entry.end.timeIntervalSince(time)))
        }
        return shown.min { distance($0) < distance($1) }
    }
    /// Left or Right from `focused`: where the window moves and what to focus there. Nil when the next programme
    /// that way is already on screen (the focus engine moves to it) or there is none in the guide.
    static func page(_ entries: [GuideEntry], from focused: GuideEntry, forward: Bool, start: Date, span: TimeInterval,
                     earliest: Date, latest: Date) -> (start: Date, entry: GuideEntry)? {
        let shown = Set(segments(entries, from: start, to: start.addingTimeInterval(span)).compactMap { $0.entry?.id })
        let candidates = entries.filter { $0.end > earliest && $0.start < latest }
        let lastStart = max(earliest, latest.addingTimeInterval(-span))
        // Nothing beyond a long programme: scroll through it, keeping it focused, so the other rows can be seen.
        let step = max(1800, halfHour(start.addingTimeInterval(span)).timeIntervalSince(start) - 1800)
        if forward {
            guard let next = candidates.first(where: { $0.start >= focused.end }) else {
                let target = min(start.addingTimeInterval(step), lastStart, halfHour(focused.end.addingTimeInterval(-1800)))
                return focused.end > start.addingTimeInterval(span) && target > start ? (target, focused) : nil
            }
            guard !shown.contains(next.id) else { return nil }
            let target = min(halfHour(next.start), lastStart)
            return target > start ? (target, next) : nil
        } else {
            guard let previous = candidates.last(where: { $0.end <= focused.start }) else {
                let target = max(start.addingTimeInterval(-step), earliest, halfHour(focused.start))
                return focused.start < start && target < start ? (target, focused) : nil
            }
            guard !shown.contains(previous.id) else { return nil }
            let target = max(halfHour(previous.end, roundingUp: true).addingTimeInterval(-span), earliest)
            return target < start ? (target, previous) : nil
        }
    }
    /// Lay one channel out as contiguous programme and gap segments clipped to a time window.
    /// An overlapping broadcast starts where the previous one ended.
    static func segments(_ entries: [GuideEntry], from origin: Date, to end: Date) -> [GuideSegment] {
        var result = [GuideSegment](), cursor = origin
        for entry in entries where entry.end > origin && entry.start < end {
            let from = max(entry.start, cursor), to = min(entry.end, end)
            guard to > from else { continue }
            if from > cursor { result.append(GuideSegment(id: "gap-\(cursor.timeIntervalSinceReferenceDate)", entry: nil, start: cursor, end: from)) }
            result.append(GuideSegment(id: entry.id, entry: entry, start: from, end: to))
            cursor = to
        }
        return result
    }
}

/// Finding an earlier ITV programme on ITVX from its Freeview guide slot. The Freeview schedule gives a title, a start
/// time and often a "Series 3: 15. Episode name" subtitle; ITVX is searched for the show and its episodes are matched
/// by original broadcast date, series-and-episode number, or episode name. Matching is best-effort: live, news and
/// sport usually have no ITVX episode and come back unmatched, which the guide reports instead of promising playback.
enum ITVGuideMatch {
    /// What the Freeview subtitle tells us about the episode.
    struct Slot: Equatable { var series: Int?; var number: Int?; var name: String? }

    static func normalise(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// "Series 3: 15. Jade" -> (3, 15, "Jade"); "15. Jade" -> (nil, 15, "Jade"); "New: Jade" / "Jade" -> (nil, nil, "Jade").
    static func parse(_ subtitle: String) -> Slot {
        var slot = Slot()
        var rest = subtitle.trimmingCharacters(in: .whitespaces)
        // Drop a leading tag Freeview sometimes prepends, e.g. "New:" or "Live:".
        if let m = rest.range(of: #"(?i)^(new|live|brand new)\s*[:.]\s*"#, options: .regularExpression) { rest = String(rest[m.upperBound...]) }
        if let m = rest.range(of: #"(?i)^series\s+(\d+)\s*[:.]?\s*"#, options: .regularExpression) {
            slot.series = Int(rest[m].components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? "")
            rest = String(rest[m.upperBound...])
        }
        if let m = rest.range(of: #"^(\d+)\s*[.:]\s*"#, options: .regularExpression) {
            slot.number = Int(rest[m].components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? "")
            rest = String(rest[m.upperBound...])
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        slot.name = name.isEmpty ? nil : name
        return slot
    }
    static func seriesNumber(_ label: String) -> Int? {
        guard let m = label.range(of: #"(?i)series\s+(\d+)"#, options: .regularExpression) else { return nil }
        return Int(label[m].components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? "")
    }
    /// The name inside an episode subtitle ("Episode 15 · Jade" -> "Jade", "Jade" -> "Jade").
    static func episodeName(_ subtitle: String) -> String {
        subtitle.components(separatedBy: " · ").last.map { $0.range(of: #"(?i)^episode\s+\d+$"#, options: .regularExpression) == nil ? $0 : "" } ?? subtitle
    }
    /// The show whose title matches the slot's exactly (ignoring case and punctuation). A near-but-different title like
    /// "The Chase Celebrity" for "The Chase" is left unmatched rather than risk playing the wrong programme.
    static func bestShow(_ shows: [CatalogueShow], title: String) -> CatalogueShow? {
        let wanted = normalise(title)
        guard !wanted.isEmpty else { return nil }
        return shows.first { normalise($0.title) == wanted }
    }
    /// The episode in a show that a Freeview slot refers to, or nil when nothing matches confidently. A film or
    /// one-episode show is taken by title alone; otherwise an episode must match on date, series+number, or name.
    static func match(_ episodes: [CatalogueEpisode], to entry: GuideEntry, now: Date) -> CatalogueEpisode? {
        guard !episodes.isEmpty else { return nil }
        if episodes.count == 1 { return episodes[0] }
        let slot = parse(entry.subtitle)
        let iso = ISO8601DateFormatter()
        func score(_ ep: CatalogueEpisode) -> Int {
            var score = 0
            if let raw = ep.broadcastDate, let date = iso.date(from: raw) {
                let gap = abs(date.timeIntervalSince(entry.start))
                if gap <= 36 * 3600 { score += 4 } else if gap <= 7 * 86400 { score += 1 }
            }
            if let n = slot.number, ep.parentPosition == n {
                if let s = slot.series, let es = seriesNumber(ep.seriesTitle) { score += es == s ? 5 : -3 } else { score += 2 }
            }
            if let name = slot.name {
                let episodeName = normalise(episodeName(ep.subtitle))
                if !episodeName.isEmpty, episodeName == normalise(name) { score += 4 }
            }
            return score
        }
        let ranked = episodes.map { ($0, score($0)) }.filter { $0.1 >= 4 }
        return ranked.max { a, b in
            if a.1 != b.1 { return a.1 < b.1 }   // higher score wins
            let da = a.0.broadcastDate.flatMap(iso.date(from:)) ?? .distantPast
            let db = b.0.broadcastDate.flatMap(iso.date(from:)) ?? .distantPast
            return da < db                        // then the most recent broadcast
        }?.0
    }

    /// Search ITVX and resolve the episode behind a past ITV guide slot, ready to play. Throws a clear message when
    /// the programme can't be found rather than leaving the user waiting.
    static func resolve(_ entry: GuideEntry, api: ITVCatalogueAPI = ITVCatalogueAPI(), now: Date = Date()) async throws -> Programme {
        let unavailable = BBCError.message("This programme isn't available to watch on demand on ITVX.")
        let shows = (try? await api.search(entry.title)) ?? []
        guard let show = bestShow(shows, title: entry.title) else { throw unavailable }
        let detailed = (try? await api.details(show)) ?? show
        guard let episode = match(detailed.episodes, to: entry, now: now) else { throw unavailable }
        return episode.programme
    }
}
