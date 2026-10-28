// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct LiveChannelsTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        for channel in LiveShelfChannel.defaults {
            check(LiveChannelLink.url(for: channel.id).flatMap { LiveChannelLink.channelID(from: $0) } == channel.id, "Every channel has a playable route")
        }
        check(Set(LiveShelfChannel.defaults.map(\.id)).count == LiveShelfChannel.defaults.count, "No duplicate shelf IDs")
        for raw in ["https://live/bbc_one_london", "telly://live/a/b", "telly://other/bbc_one_london", "telly://live/bbc_one_london?stream=https://example.org", "telly://live/bbc_one_london#x", "telly://user@live/bbc_one_london"] {
            check(LiveChannelLink.channelID(from: URL(string: raw)!) == nil, "Reject malformed or externally supplied stream URLs")
        }
        for channel in LiveShelfChannel.itvDefaults {
            check(LiveChannelLink.url(for: channel.id).flatMap { LiveChannelLink.channelID(from: $0) } == channel.id, "ITV shelf routes retain provider prefix")
        }
        let itv = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/ITVLiveFeed.json"))
        let itvNow = ISO8601DateFormatter().date(from: "2026-10-23T12:30:00Z")!
        let itvShelf = LiveShelfChannel.itvChannels(itv, now: itvNow)
        check(itvShelf.count == 25 && itvShelf.allSatisfy { LiveChannelLink.url(for: $0.id) != nil }, "ITV catalogue maps to native shelf routes")
        check(itvShelf.first?.image?.host == "ovp.itv.com", "ITV current programme artwork")
        check(LiveShelfChannel.itvChannels(Data()).count == 5, "Unavailable ITV metadata retains main-channel defaults")
        let c5 = LiveShelfChannel.channel5Channels(try Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/Channel5LiveFeed.json")))
        check(c5.count == 24,"All Channel 5 standard and themed channels decode")
        for channel in c5 {
            check(LiveChannelLink.url(for:channel.id).flatMap { LiveChannelLink.channelID(from:$0) } == channel.id,"Channel 5 Top Shelf links round-trip, including hyphenated IDs")
        }
        for bad in ["c5:../C5","c5:C5?url=evil","c5:","c5:C5/other","c5:https://evil"] {
            check(!LiveChannelLink.validID(bad),"Reject malformed Channel 5 IDs")
        }
        let combined = LiveShelfChannel.defaults + itvShelf + LiveShelfChannel.channel4Defaults + c5
        let ordered = LiveChannelOrder.sorted(Array(combined.reversed()),id:{ $0.id },title:{ $0.title })
        let main = ordered.filter { LiveChannelOrder.section($0.id) == .main }
        check(main.map(\.title) == ["BBC One","BBC Two","ITV1","Channel 4","Channel 5","ITV2","BBC Four","ITV3","E4","Film4","More4","5USA","BBC Three","ITV4","5STAR","5Drama","5ACTION","4seven","CBBC","CBeebies","BBC News","BBC Parliament"],"Approved Freeview order, independent of provider feed order")
        check(ordered.filter { LiveChannelOrder.section($0.id) == .additional }.map(\.title) == ["BBC Scotland","BBC ALBA","S4C","ITVBe"],"Regional and additional channels follow the main list")
        let itvThemed = ordered.filter { LiveChannelOrder.section($0.id) == .itvThemed }
        check(itvThemed.count == 20 && itvThemed.first?.title == "Carry On and On" && itvThemed.last?.title == "Vera","ITV themed channels remain in their approved section")
        check(ordered.filter { LiveChannelOrder.section($0.id) == .channel5Themed }.count == 19,"Channel 5 themed channels separated from five main services")
        check(LiveChannelOrder.section("bbc_one_northern_ireland") == .main,"Regional BBC One keeps the primary slot")
        check(LiveChannelOrder.sorted(combined+combined,id:{ $0.id },title:{ $0.title }).count == combined.count,"Deduplicate cached/feed channels")
        let future = LiveShelfChannel(id:"itv:fast99",title:"Future channel")
        let extended = LiveChannelOrder.sorted(combined+[future],id:{ $0.id },title:{ $0.title })
        check(extended.filter { LiveChannelOrder.section($0.id) == .itvThemed }.last?.id == future.id,"New FAST services stay in their provider section")
        check(LiveShelfChannel.channel5Channels(Data("{}".utf8)).isEmpty,"Malformed feed safely delegates to saved/default fallback")
        let prefs = UserDefaults(suiteName: "RegionalChannelsTests")!
        prefs.removePersistentDomain(forName: "RegionalChannelsTests")
        check(RegionalChannels.bbcOne.count == 16 && RegionalChannels.bbcTwo.count == 3, "Verified BBC regional directory")
        prefs.set("bbc_one_northern_ireland", forKey: "bbcOneRegion")
        check(RegionalChannels.selectedID(for: "bbc_one_london", defaults: prefs) == "bbc_one_northern_ireland", "Generic Top Shelf route follows the selected region")
        prefs.set("https://invalid.example", forKey: "bbcTwoRegion")
        check(RegionalChannels.selectedID(for: "bbc_two_england", defaults: prefs) == "bbc_two_england", "Corrupt preference safely falls back")
        check(RegionalChannels.selectedID(for: "bbc_news24", defaults: prefs) == "bbc_news24", "Other channels unaffected")
        prefs.removePersistentDomain(forName: "RegionalChannelsTests")
        let now = ISO8601DateFormatter().date(from: "2026-10-19T12:30:00Z")!
        let data = Data(#"{"broadcasts":{"elements":[{"scheduled_start":"2026-10-19T12:00:00Z","scheduled_end":"2026-10-19T13:00:00Z","episode":{"images":{"standard":"https://ichef.bbci.co.uk/images/ic/{recipe}/p0000001.jpg"}}}]}}"#.utf8)
        check(LiveShelfArtwork.current(data, now: now)?.absoluteString.contains("1280x720") == true, "Current programme uses landscape imagery")
        check(LiveShelfArtwork.current(data, now: now.addingTimeInterval(3600)) == nil, "Expired programmes do not supply current artwork")
        print("PASS: approved Freeview order, themed sections, 65 channel mappings, safe launch links, regional slots, deduplication, artwork and expiry")
    }
}
