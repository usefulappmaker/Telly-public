// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

struct WatchRecord: Codable, Identifiable {
    let id: String
    var episode: CatalogueEpisode
    var show: CatalogueShow?
    var nextEpisode: CatalogueEpisode?
    var position: Double
    var duration: Double
    var completed: Bool
    var updatedAt: Date
    var target: Programme? { completed ? nextEpisode?.programme : episode.programme }
    var fraction: Double { min(1, max(0, position / max(1, duration))) }
    var remainingMinutes: Int { max(1, Int(ceil((duration - position) / 60))) }
}

enum EpisodeSequence {
    private static func number(_ text: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
    private static func season(_ episode: CatalogueEpisode) -> Int? {
        number(episode.seriesTitle + " " + episode.subtitle, pattern: "\\b(?:series|season)\\s+(\\d+)\\b")
    }
    private static func position(_ episode: CatalogueEpisode) -> Int? {
        if let value = episode.parentPosition, value > 0 { return value }
        let subtitle = episode.subtitle.components(separatedBy: ": ").last ?? episode.subtitle
        return number(subtitle, pattern: "^\\s*(?:episode\\s+)?(\\d+)(?:[.:]\\s*|\\s+|$)")
    }
    private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter
    }()
    private static let plainDate = ISO8601DateFormatter()
    private static func date(_ episode: CatalogueEpisode) -> Date? {
        guard let value = episode.broadcastDate else { return nil }
        return fractionalDate.date(from:value) ?? plainDate.date(from:value)
    }
    /// BBC pages may arrive newest-first. Use explicit episode positions, then dates,
    /// and preserve source order when no comparable ordering metadata is supplied.
    static func ordered(_ episodes: [CatalogueEpisode]) -> [CatalogueEpisode] {
        // Compute keys once: large daily-programme archives otherwise repeatedly
        // parse the same dates and episode numbers during every sort comparison.
        episodes.enumerated().map { index,episode in
            (episode,index,season(episode) ?? Int.max,position(episode) ?? Int.max,date(episode) ?? .distantFuture)
        }.sorted { a,b in
            if a.2 != b.2 { return a.2 < b.2 }
            if a.3 != b.3 { return a.3 < b.3 }
            if a.4 != b.4 { return a.4 < b.4 }
            return a.1 < b.1
        }.map { $0.0 }
    }
    static func orderedSeries(_ series: [CatalogueSeries]) -> [CatalogueSeries] {
        series.enumerated().sorted { left, right in
            if let a = left.element.episodes.first.flatMap(season), let b = right.element.episodes.first.flatMap(season), a != b { return a < b }
            return left.offset < right.offset
        }.map(\.element)
    }
    /// There is no universal soap flag across providers. Prefer genre metadata,
    /// retaining a small fallback for familiar soaps when a provider omits it.
    static func newestFirst(_ show: CatalogueShow) -> Bool {
        if show.categories.contains(where: { $0.localizedCaseInsensitiveContains("soap") }) { return true }
        let names = ["eastenders","coronation street","emmerdale","hollyoaks","home and away","neighbours"]
        return names.contains(show.title.trimmingCharacters(in:.whitespacesAndNewlines).lowercased())
    }
    static func displayed(_ episodes: [CatalogueEpisode], in show: CatalogueShow) -> [CatalogueEpisode] {
        guard newestFirst(show) else { return ordered(episodes) }
        // Dates take precedence for daily programmes whose episode numbers reset.
        return episodes.enumerated().map { index,episode in
            (episode,index,date(episode),position(episode))
        }.sorted { a,b in
            if let da = a.2, let db = b.2, da != db { return da > db }
            if a.2 != nil && b.2 == nil { return true }
            if a.2 == nil && b.2 != nil { return false }
            if let pa = a.3, let pb = b.3, pa != pb { return pa > pb }
            if a.3 != nil && b.3 == nil { return true }
            if a.3 == nil && b.3 != nil { return false }
            return a.1 < b.1
        }.map { $0.0 }
    }
    static func latestSeries(_ series: [CatalogueSeries]) -> CatalogueSeries? {
        func rank(_ group: CatalogueSeries) -> Int? {
            number(group.title,pattern:#"\b(?:series|season)\s+(\d+)\b"#) ??
                number(group.title,pattern:#"\b((?:19|20)\d{2})\b"#) ?? group.episodes.first.flatMap(season)
        }
        return series.enumerated().map { index,group in
            (group,index,rank(group),group.episodes.compactMap(date).max())
        }.sorted { a,b in
            if let ra = a.2, let rb = b.2, ra != rb { return ra > rb }
            if a.2 != nil && b.2 == nil { return true }
            if a.2 == nil && b.2 != nil { return false }
            if let da = a.3, let db = b.3, da != db { return da > db }
            if a.3 != nil && b.3 == nil { return true }
            if a.3 == nil && b.3 != nil { return false }
            return a.1 < b.1
        }.first?.0
    }
    static func next(after current: CatalogueEpisode, in show: CatalogueShow) -> CatalogueEpisode? {
        let candidates = show.episodes.filter { $0.id != current.id }
        if newestFirst(show), let released = date(current) {
            // Browsing is descending; automatic succession must still move forward.
            // A double bill may share its release timestamp: positions break ties.
            let currentPosition = position(current)
            let dated = candidates.compactMap { episode -> (CatalogueEpisode,Date,Int)? in
                guard let date = date(episode) else { return nil }
                let p = position(episode)
                let laterInDoubleBill = date == released && episode.sliceID == current.sliceID &&
                    currentPosition != nil && p.map { $0 > currentPosition! } == true
                guard date > released || laterInDoubleBill else { return nil }
                return (episode,date,p ?? Int.max)
            }
            if let next = dated.min(by:{ ($0.1,$0.2) < ($1.1,$1.2) }) { return next.0 }
        }
        if let order = position(current) {
            if let series = season(current) {
                // Sort by BBC episode position and explicit series number, rather
                // than assuming the API is oldest-first (some shows are reversed).
                let numbered = candidates.compactMap { episode -> (CatalogueEpisode, Int, Int)? in
                    guard let s = season(episode), let p = position(episode), s > series || (s == series && p > order) else { return nil }
                    return (episode, s, p)
                }
                if let next = numbered.min(by: { ($0.1, $0.2) < ($1.1, $1.2) }) { return next.0 }
            } else {
                let sameSeries = candidates.filter { $0.sliceID == current.sliceID && position($0).map { $0 > order } == true }
                if let next = sameSeries.min(by: { position($0)! < position($1)! }) { return next }
            }
        }
        if let released = date(current) {
            return candidates.filter { date($0).map { $0 > released } == true }
                .min { date($0)! < date($1)! }
        }
        // Without ordering metadata, leave the programme available to browse
        // rather than guessing that a reversed API list is chronological.
        return nil
    }
}

@MainActor final class WatchHistory: ObservableObject {
    @Published private(set) var records: [WatchRecord] = []
    @Published private(set) var warning: String?
    private let defaults: UserDefaults
    private static let key = "continueWatching-v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            do {
                records = try JSONDecoder().decode([WatchRecord].self, from: data)
                    .filter { $0.position.isFinite && $0.duration.isFinite && $0.position >= 0 && $0.duration > 0 }
                    .sorted { $0.updatedAt > $1.updatedAt }
            } catch { warning = "Viewing history could not be read. New progress can still be saved." }
        }
    }
    static func isComplete(position: Double, duration: Double, ended: Bool = false) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        return ended || (position / duration >= 0.95 && duration - position <= 120)
    }
    func resumePosition(for episodeID: String) -> Double {
        guard let record = records.first(where: { $0.episode.id == episodeID }), !record.completed else { return 0 }
        return record.position
    }
    func update(episode: CatalogueEpisode, show: CatalogueShow?, next: CatalogueEpisode?, position: Double, duration: Double, ended: Bool = false, now: Date = Date()) {
        guard position.isFinite, duration.isFinite, duration > 0, position >= 0, position >= 5 || ended else { return }
        let id = show?.id ?? episode.programme.showID ?? episode.id
        let completed = Self.isComplete(position: position, duration: duration, ended: ended)
        if let old = records.first(where: { $0.id == id }), old.episode.id == episode.id,
           abs(old.position - position) < 0.5, old.completed == completed { return }
        var compact = show
        compact?.episodes = []; compact?.indexedAt = nil
        let oldNext = records.first { $0.id == id && $0.episode.id == episode.id }?.nextEpisode
        let record = WatchRecord(id: id, episode: episode, show: compact, nextEpisode: next ?? oldNext,
                                 position: min(position, duration), duration: duration, completed: completed, updatedAt: now)
        records.removeAll { $0.id == id }; records.insert(record, at: 0)
        records = Array(records.prefix(40)); persist()
    }
    func remove(_ id: String) { records.removeAll { $0.id == id }; persist() }
    private func persist() {
        do { defaults.set(try JSONEncoder().encode(records), forKey: Self.key); warning = nil }
        catch { warning = "Viewing progress could not be saved." }
    }
}

/// Wall-clock deadline avoids extending the countdown when UI rendering is busy.
struct NextEpisodeCountdown {
    let deadline: Date
    init(now: Date = Date()) { deadline = now.addingTimeInterval(15) }
    func remaining(at now: Date = Date()) -> Int { max(0,Int(ceil(deadline.timeIntervalSince(now)))) }
}
