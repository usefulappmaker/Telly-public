// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TVServices
import UIKit

final class ContentProvider: TVTopShelfContentProvider {
    private struct Snapshot: Codable { let date: Date; let channels: [LiveShelfChannel] }
    private var cacheURL: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("live-shelf.json") }
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task { @MainActor in
            let saved = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
            if let saved, !saved.channels.isEmpty, saved.channels.contains(where: { $0.id.hasPrefix("c4:") }) && saved.channels.contains(where: { $0.id.hasPrefix("c5:") }), Date().timeIntervalSince(saved.date) < 600 {
                completionHandler(content(saved.channels)); return
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2; configuration.timeoutIntervalForResource = 4
            configuration.httpMaximumConnectionsPerHost = 8
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            func fallback(_ prefix: String, _ defaults: [LiveShelfChannel]) -> [LiveShelfChannel] {
                let values = saved?.channels.filter { $0.id.hasPrefix(prefix) } ?? []
                return values.isEmpty ? defaults : values
            }
            let previousBBC = saved?.channels.filter { !$0.id.contains(":") } ?? []
            var channels = previousBBC.isEmpty ? LiveShelfChannel.defaults : previousBBC
            async let itvResponse = try? session.data(from: URL(string: "https://nownext.oasvc.itv.com/channels")!)
            async let channel4Response = try? session.data(from: URL(string:"https://www.channel4.com/api/now-next")!)
            async let channel5Response = try? session.data(from:URL(string:"https://feeds-api.channel5.com/collections/PLC_5LiveTVPageSubNav/concise.json?vod_available=my5desktop")!)
            var refreshed = false
            if let (data, response) = try? await session.data(from: URL(string: "https://ibl.api.bbc.co.uk/ibl/v1/channels")!),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let values = root["channels"] as? [[String: Any]] {
                let available = values.compactMap { value -> LiveShelfChannel? in
                    guard value["has_schedule"] as? Bool == true, let id = value["id"] as? String,
                          LiveChannelLink.validID(id), let title = value["title"] as? String else { return nil }
                    return LiveShelfChannel(id: id, title: title)
                }
                if !available.isEmpty { channels = available; refreshed = true }
            }
            if let (data, response) = await itvResponse, (response as? HTTPURLResponse)?.statusCode == 200 {
                channels += LiveShelfChannel.itvChannels(data); refreshed = true
            } else { channels += fallback("itv:",LiveShelfChannel.itvDefaults) }
            if let (data,response) = await channel4Response, (response as? HTTPURLResponse)?.statusCode == 200 {
                channels += LiveShelfChannel.channel4Channels(data); refreshed = true
            } else { channels += fallback("c4:",LiveShelfChannel.channel4Defaults) }
            if let (data,response) = await channel5Response, (response as? HTTPURLResponse)?.statusCode == 200,
               !LiveShelfChannel.channel5Channels(data).isEmpty {
                channels += LiveShelfChannel.channel5Channels(data); refreshed = true
            } else { channels += fallback("c5:",LiveShelfChannel.channel5Defaults) }
            channels = await withTaskGroup(of: (Int, LiveShelfChannel).self) { group in
                for (index, entry) in channels.enumerated() {
                    group.addTask {
                        var entry = entry
                        if entry.id.contains(":") { return (index, entry) }
                        let url = URL(string: "https://ibl.api.bbc.co.uk/ibl/v1/channels/\(entry.id)/broadcasts?per_page=20")!
                        if let (data, _) = try? await session.data(from: url), let image = LiveShelfArtwork.current(data) { entry.image = image }
                        return (index, entry)
                    }
                }
                var entries = [(Int, LiveShelfChannel)]()
                for await entry in group { entries.append(entry) }
                return entries.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if refreshed || saved == nil {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(Snapshot(date: Date(), channels: channels)) { try? data.write(to: cacheURL, options: .atomic) }
            }
            completionHandler(content(channels))
        }
    }
    @MainActor private func content(_ channels: [LiveShelfChannel]) -> TVTopShelfSectionedContent {
        let ordered = LiveChannelOrder.sorted(channels,id:{ $0.id },title:{ $0.title })
        let sections = LiveChannelSection.allCases.compactMap { kind -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
            let items = ordered.filter { LiveChannelOrder.section($0.id) == kind }.compactMap { channel -> TVTopShelfSectionedItem? in
                guard let url = LiveChannelLink.url(for:channel.id) else { return nil }
                let item = TVTopShelfSectionedItem(identifier:channel.id)
                item.title = channel.title; item.imageShape = .hdtv
                item.displayAction = TVTopShelfAction(url:url); item.playAction = TVTopShelfAction(url:url)
                let image = channel.image ?? fallbackImage(channel)
                item.setImageURL(image,for:.screenScale1x); item.setImageURL(image,for:.screenScale2x)
                return item
            }
            guard !items.isEmpty else { return nil }
            let section = TVTopShelfItemCollection(items:items); section.title = kind.title
            return section
        }
        return TVTopShelfSectionedContent(sections:sections)
    }
    @MainActor private func fallbackImage(_ channel: LiveShelfChannel) -> URL? {
        let url = cacheURL.deletingLastPathComponent().appendingPathComponent("\(channel.id).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { context in
            UIColor(white: 0.08, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: UIColor.white]
            (channel.title as NSString).draw(in: CGRect(x: 40, y: 140, width: 560, height: 120), withAttributes: attributes)
        }
        guard let data = image.pngData() else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return url
    }
}
