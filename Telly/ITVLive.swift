// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ITVLiveAPI {
    var fetch: (URL) async throws -> Data = { try await ITVCatalogueAPI().fetch($0) }
    static let feedURL = URL(string: "https://nownext.oasvc.itv.com/channels")!
    func channels() async throws -> [LiveChannel] { try Self.channels(from: await fetch(Self.feedURL)) }
    static func endpoint(_ url: URL, channelID: String? = nil) throws -> URL {
        let prefix = "/playlist/itvonline/"
        guard url.scheme == "https", ["simulcast.itv.com", "stream-starter.fastly.ottstream.itv.com"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix(prefix) else { throw ITVAccountError.message("Invalid ITV live channel address.") }
        let id = String(url.path.dropFirst(prefix.count))
        guard validID(id), channelID.map({ $0.lowercased() == id.lowercased() }) ?? true else {
            throw ITVAccountError.message("Invalid ITV live channel identifier.")
        }
        return url
    }
    static func validID(_ id: String) -> Bool {
        ["itv", "itv2", "itv3", "itv4", "itvbe"].contains(id.lowercased()) || id.range(of: "^FAST[0-9]{1,3}$", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func channels(from data: Data, now: Date = Date()) throws -> [LiveChannel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let values = root["channels"] as? [[String: Any]] else {
            throw ITVAccountError.message("ITV's live channel list is unavailable.")
        }
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) -> Date? { (value as? String).flatMap { plain.date(from: $0) ?? fractional.date(from: $0) } }
        var seen = Set<String>()
        let channels = values.compactMap { value -> LiveChannel? in
            guard let id = value["id"] as? String, validID(id), let title = value["name"] as? String, !title.isEmpty,
                  let raw = (value["streamUrl"] ?? value["playlistUrl"]) as? String, let url = URL(string: raw),
                  let endpoint = try? endpoint(url, channelID: id), seen.insert(id.lowercased()).inserted else { return nil }
            let images = value["images"] as? [String: Any] ?? [:]
            let logo = ITVCatalogueAPI.image((images["logo"] as? String)?.replacingOccurrences(of: "{image_format}", with: "png"))
            let slots = value["slots"] as? [String: Any] ?? [:]
            let programme = [slots["now"], slots["next"]].compactMap { $0 as? [String: Any] }.compactMap { slot -> LiveProgramme? in
                guard let start = date(slot["start"]), let end = date(slot["end"]), start <= now, now < end,
                      let title = (slot["displayTitle"] ?? slot["brandTitle"] ?? slot["title"]) as? String, !title.isEmpty else { return nil }
                return LiveProgramme(title: title, subtitle: slot["detailedDisplayTitle"] as? String ?? "",
                    image: Self.programmeArtwork(slot), end: end)
            }.first
            return LiveChannel(id: "itv:" + id.lowercased(), title: title, current: programme, logo: logo, itvPlaylistURL: endpoint)
        }
        guard !channels.isEmpty else { throw ITVAccountError.message("ITV returned no compatible live channels.") }
        let main = ["itv:itv", "itv:itv2", "itv:itvbe", "itv:itv3", "itv:itv4"]
        return main.compactMap { id in channels.first { $0.id == id } } + channels.filter { !main.contains($0.id) }
    }
    static func seed(bundle: Bundle = .main) -> [LiveChannel] {
        guard let url = bundle.url(forResource: "ITVLiveSeed", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? channels(from: data)) ?? []
    }
    static func programmeArtwork(_ slot: [String: Any]) -> URL? {
        if let image = ITVCatalogueAPI.image(slot["image"]) { return image }
        guard let brand = slot["brandId"] as? String, brand.range(of: "^[A-Za-z0-9]{5,24}$", options: .regularExpression) != nil else { return nil }
        var parts = URLComponents(string: "https://ovp.itv.com/images/programme/\(brand)/itv_hub/04_DesktopCTV_RailTileLandscape/16x9")!
        parts.queryItems = ["distributionPartner":"itv_hub", "treatment":"title", "w":"640", "h":"360", "q":"80", "fallback":"standard"].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url
    }
    static func playbackURL(from data: Data) throws -> URL {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let video = (root?["Playlist"] as? [String: Any])?["Video"] as? [String: Any]
        let locations = video?["VideoLocations"] as? [[String: Any]] ?? []
        for location in locations where location["IsDar"] as? Bool != true {
            guard let raw = location["Url"] as? String, let url = URL(string: raw), url.scheme == "https",
                  url.host?.hasSuffix(".content.itv.com") == true, url.user == nil, url.password == nil, url.port == nil,
                  url.path.lowercased().hasSuffix(".m3u8") else { continue }
            return url
        }
        throw ITVAccountError.message("ITV did not return a compatible native live stream. This channel may be unavailable on this device.")
    }
    static func requestBody(token: String, osVersion: String, model: String) -> [String: Any] {
        let features = ["hls", "fairplay"]
        return ["client": ["id": "browser", "service": "itv.x", "version": "4.1"],
            "device": ["manufacturer": "Apple", "model": model, "os": ["name": "tvOS", "version": osVersion, "type": "ctv"], "deviceGroup": "ctv"],
            "user": ["token": token], "variantAvailability": ["player": "hls", "platformTag": "ctv", "featureset": ["min": features, "max": features]]]
    }
}
