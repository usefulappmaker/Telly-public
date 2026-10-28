// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct LiveShelfChannel: Codable, Hashable {
    let id: String
    let title: String
    var image: URL? = nil
    static let defaults = [
        LiveShelfChannel(id: "bbc_one_london", title: "BBC One"), LiveShelfChannel(id: "bbc_two_england", title: "BBC Two"),
        LiveShelfChannel(id: "bbc_three", title: "BBC Three"), LiveShelfChannel(id: "bbc_four", title: "BBC Four"),
        LiveShelfChannel(id: "cbbc", title: "CBBC"), LiveShelfChannel(id: "cbeebies", title: "CBeebies"),
        LiveShelfChannel(id: "bbc_scotland", title: "BBC Scotland"), LiveShelfChannel(id: "bbc_news24", title: "BBC News"),
        LiveShelfChannel(id: "bbc_parliament", title: "BBC Parliament"), LiveShelfChannel(id: "bbc_alba", title: "BBC ALBA"),
        LiveShelfChannel(id: "s4cpbs", title: "S4C")
    ]
}
enum LiveChannelLink {
    static func validID(_ id: String) -> Bool { id.range(of: "^(?:(?:itv:)?[a-z0-9_]{2,64}|c4:(?:C4|E4|M4|F4|4S)|c5:[A-Za-z0-9][A-Za-z0-9-]{0,63})$", options: .regularExpression) != nil }
    static func url(for id: String) -> URL? { validID(id) ? URL(string: "telly://live/\(id)") : nil }
    static func channelID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "telly", url.host == "live", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 1, validID(path[0]) else { return nil }
        return path[0]
    }
}
struct LiveLaunch: Equatable {
    let id = UUID()
    let channelID: String
}
enum LiveShelfArtwork {
    static func current(_ data: Data, now: Date = Date()) -> URL? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let entries = (root?["broadcasts"] as? [String: Any])?["elements"] as? [[String: Any]] ?? []
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? { (value as? String).flatMap { fractional.date(from: $0) ?? plain.date(from: $0) } }
        for entry in entries {
            guard let start = date(entry["scheduled_start"]), let end = date(entry["scheduled_end"]), start <= now, now < end,
                  entry["blanked"] as? Bool != true, let episode = entry["episode"] as? [String: Any],
                  let images = episode["images"] as? [String: Any], let value = images["standard"] as? String,
                  let url = URL(string: value.replacingOccurrences(of: "{recipe}", with: "1280x720")),
                  url.scheme == "https", url.host == "ichef.bbci.co.uk" else { continue }
            return url
        }
        return nil
    }
}

extension Notification.Name { static let tellyLaunchLive = Notification.Name("TellyLaunchLive") }

struct RegionalChannelChoice: Identifiable { let id: String; let title: String }
enum RegionalChannels {
    static let bbcOne: [RegionalChannelChoice] = [
        .init(id: "bbc_one_channel_islands", title: "Channel Islands"),
        .init(id: "bbc_one_east", title: "East"),
        .init(id: "bbc_one_east_midlands", title: "East Midlands"),
        .init(id: "bbc_one_east_yorkshire", title: "East Yorks & Lincs"),
        .init(id: "bbc_one_london", title: "London"),
        .init(id: "bbc_one_north_east", title: "North East & Cumbria"),
        .init(id: "bbc_one_north_west", title: "North West"),
        .init(id: "bbc_one_northern_ireland", title: "Northern Ireland"),
        .init(id: "bbc_one_scotland", title: "Scotland"),
        .init(id: "bbc_one_south", title: "South"),
        .init(id: "bbc_one_south_east", title: "South East"),
        .init(id: "bbc_one_south_west", title: "South West"),
        .init(id: "bbc_one_wales", title: "Wales"),
        .init(id: "bbc_one_west", title: "West"),
        .init(id: "bbc_one_west_midlands", title: "West Midlands"),
        .init(id: "bbc_one_yorks", title: "Yorkshire"),
    ]
    static let bbcTwo: [RegionalChannelChoice] = [
        .init(id: "bbc_two_england", title: "England / Scotland"),
        .init(id: "bbc_two_northern_ireland_digital", title: "Northern Ireland"),
        .init(id: "bbc_two_wales_digital", title: "Wales")
    ]
    static func selectedID(for id: String, defaults: UserDefaults = .standard) -> String {
        let choices: [RegionalChannelChoice], key: String
        switch id {
        case "bbc_one_london": choices = bbcOne; key = "bbcOneRegion"
        case "bbc_two_england": choices = bbcTwo; key = "bbcTwoRegion"
        default: return id
        }
        guard let selected = defaults.string(forKey: key), choices.contains(where: { $0.id == selected }) else { return id }
        return selected
    }
}

/// Curated event services; do not enumerate unadvertised stream numbers.
struct AdditionalLiveStream: Identifiable {
    let id: String
    let title: String
    static let all = [
        AdditionalLiveStream(id: "red_button_one", title: "Red Button"),
        AdditionalLiveStream(id: "uk_bbc_stream_041", title: "Red Button UHD")
    ]
    static let uhdManifest = URL(string: "https://ve-uhd-push-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:uk_bbc_stream_041/iptv_uhd_v1.mpd")!
}


extension LiveShelfChannel {
    static let itvDefaults = [("itv", "ITV1"), ("itv2", "ITV2"), ("itvbe", "ITVBe"), ("itv3", "ITV3"), ("itv4", "ITV4")].map { LiveShelfChannel(id: "itv:" + $0.0, title: $0.1) }
    static func itvChannels(_ data: Data, now: Date = Date()) -> [LiveShelfChannel] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let values = root?["channels"] as? [[String: Any]] ?? []
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        var seen = Set<String>()
        let entries = values.compactMap { value -> LiveShelfChannel? in
            guard let raw = value["id"] as? String else { return nil }
            let id = raw.lowercased()
            guard ["itv", "itv2", "itv3", "itv4", "itvbe"].contains(id) || id.range(of: "^fast[0-9]{1,3}$", options: .regularExpression) != nil,
                  let title = value["name"] as? String, !title.isEmpty, seen.insert(id).inserted else { return nil }
            let slots = value["slots"] as? [String: Any] ?? [:]
            let current = [slots["now"], slots["next"]].compactMap { $0 as? [String: Any] }.first { slot in
                guard let a = slot["start"] as? String, let z = slot["end"] as? String,
                      let start = plain.date(from: a) ?? fractional.date(from: a), let end = plain.date(from: z) ?? fractional.date(from: z) else { return false }
                return start <= now && now < end
            }
            var image: URL?
            if let brand = current?["brandId"] as? String, brand.range(of: "^[A-Za-z0-9]{5,24}$", options: .regularExpression) != nil {
                image = URL(string: "https://ovp.itv.com/images/programme/\(brand)/itv_hub/04_DesktopCTV_RailTileLandscape/16x9?distributionPartner=itv_hub&treatment=title&w=1280&h=720&q=80&fallback=standard")
            }
            return LiveShelfChannel(id: "itv:" + id, title: title, image: image)
        }
        return entries.isEmpty ? itvDefaults : entries
    }
}

extension LiveShelfChannel {
    static let channel4Defaults = [("C4","Channel 4"),("E4","E4"),("M4","More4"),("F4","Film4"),("4S","4seven")].map { LiveShelfChannel(id:"c4:"+$0.0,title:$0.1) }
    static func channel4Channels(_ data: Data, now: Date = Date()) -> [LiveShelfChannel] {
        let root = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        let rows = (root?["slots"] as? [String:Any])?["now"] as? [[String:Any]] ?? []
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
        return channel4Defaults.map { channel in
            var channel = channel
            if let row = rows.first(where: { $0["channel"] as? String == String(channel.id.dropFirst(3)) }),
               let end = row["end"] as? String, let date = plain.date(from:end) ?? fractional.date(from:end), date > now,
               let image = row["image"] as? [String:Any], let raw = image["href"] as? String,
               let url = URL(string:raw.replacingOccurrences(of:"{&resize}",with:"&resize=1280:720")), url.scheme == "https", url.host?.hasSuffix(".c4assets.com") == true { channel.image = url }
            return channel
        }
    }
}

/// Shared by the app and Top Shelf so filtering/caching cannot change channel order.
enum LiveChannelSection: String, CaseIterable {
    case main, additional, itvThemed, channel5Themed
    var title: String {
        switch self {
        case .main: return "Live TV"
        case .additional: return "Regional & additional channels"
        case .itvThemed: return "ITV themed channels"
        case .channel5Themed: return "Channel 5 themed channels"
        }
    }
}
enum LiveChannelOrder {
    static let main = ["bbc_one_london","bbc_two_england","itv:itv","c4:C4","c5:C5","itv:itv2",
        "bbc_four","itv:itv3","c4:E4","c4:F4","c4:M4","c5:C7","bbc_three","itv:itv4",
        "c5:C6","c5:C8","c5:C0","c4:4S","cbbc","cbeebies","bbc_news24","bbc_parliament"]
    static let additional = ["bbc_scotland","bbc_alba","s4cpbs","itv:itvbe"]
    static let itvThemed = ["itv:fast16","itv:fast14","itv:fast20","itv:fast10","itv:fast17","itv:fast8",
        "itv:fast5","itv:fast4","itv:fast1","itv:fast7","itv:fast6","itv:fast9","itv:fast12",
        "itv:fast11","itv:fast22","itv:fast3","itv:fast15","itv:fast19","itv:fast13","itv:fast2"]
    static let channel5Themed = ["c5:C5CH07","c5:3P-AMC-FAST-02","c5:3P-AMC-FAST-01","c5:C5CH05",
        "c5:C5CH18","c5:C5CH01","c5:C5CH10","c5:C5CH09","c5:C5CH04","c5:C5CH16",
        "c5:3P-HEARST-FAST-01","c5:3P-AMC-FAST-04","c5:C5CH11","c5:C5CH14",
        "c5:3P-HEARST-FAST-02","c5:C5CH02","c5:C5CH03","c5:3P-AMC-FAST-03","c5:C5CH06"]
    private static func canonical(_ id: String) -> String {
        if id.hasPrefix("bbc_one_") { return "bbc_one_london" }
        if id.hasPrefix("bbc_two_") { return "bbc_two_england" }
        return id
    }
    static func section(_ id: String) -> LiveChannelSection {
        let id = canonical(id)
        if main.contains(id) { return .main }
        if id.hasPrefix("itv:fast") { return .itvThemed }
        if id.hasPrefix("c5:") { return .channel5Themed }
        return .additional
    }
    private static func rank(_ id: String) -> Int {
        let id = canonical(id)
        switch section(id) {
        case .main: return main.firstIndex(of:id) ?? Int.max
        case .additional: return additional.firstIndex(of:id) ?? Int.max
        case .itvThemed: return itvThemed.firstIndex(of:id) ?? Int.max
        case .channel5Themed: return channel5Themed.firstIndex(of:id) ?? Int.max
        }
    }
    static func sorted<T>(_ channels: [T], id: (T)->String, title: (T)->String) -> [T] {
        var seen = Set<String>()
        return channels.filter { seen.insert(id($0)).inserted }.sorted { a,b in
            let sa = LiveChannelSection.allCases.firstIndex(of:section(id(a)))!, sb = LiveChannelSection.allCases.firstIndex(of:section(id(b)))!
            if sa != sb { return sa < sb }
            let ra = rank(id(a)), rb = rank(id(b))
            if ra != rb { return ra < rb }
            let comparison = title(a).localizedStandardCompare(title(b))
            return comparison == .orderedSame ? id(a) < id(b) : comparison == .orderedAscending
        }
    }
}
extension LiveShelfChannel {
    static let channel5Defaults = [("C5","Channel 5"),("C7","5USA"),("C6","5STAR"),("C0","5ACTION"),("C8","5Drama")].map {
        LiveShelfChannel(id:"c5:" + $0.0,title:$0.1,image:channel5Image($0.0))
    }
    private static func channel5Image(_ id: String) -> URL? {
        URL(string:"https://api-images.channel5.com/otis/images/channel/" + id + "/640x360.jpg")
    }
    static func channel5Channels(_ data: Data) -> [LiveShelfChannel] {
        guard let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let contents = (root["filters"] as? [String:Any])?["contents"] as? [[String:Any]] else { return [] }
        var seen = Set<String>()
        return contents.compactMap { row in
            guard row["live"] as? Bool == true, let raw = row["channel"] as? String,
                  LiveChannelLink.validID("c5:" + raw), let title = row["title"] as? String,
                  !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, seen.insert(raw).inserted else { return nil }
            return LiveShelfChannel(id:"c5:" + raw,title:title.trimmingCharacters(in:.whitespacesAndNewlines),image:channel5Image(raw))
        }
    }
}
