import Foundation
@main struct DASHTests {
    static func main() async throws {
        let xml = """
        <MPD type="static" mediaPresentationDuration="PT10S"><Period>
        <AdaptationSet contentType="video" frameRate="25"><SegmentTemplate timescale="1000" duration="4000" startNumber="1" initialization="$RepresentationID$/IS.mp4" media="$RepresentationID$/$Number%06d$.m4s"/>
        <Representation id="video-low" width="1920" height="1080" codecs="hev1.2.4.L150.B0" bandwidth="8000000"/>
        <Representation id="video-high" width="3840" height="2160" codecs="hev1.2.4.L153.B0" bandwidth="24000000"/>
        </AdaptationSet>
        <AdaptationSet contentType="audio" codecs="mp4a.40.2" lang="eng"><SegmentTemplate timescale="1000" duration="4000" initialization="$RepresentationID$/IS.mp4" media="$RepresentationID$/$Number%06d$.m4s"/><Representation id="audio" bandwidth="192000"/></AdaptationSet>
        </Period></MPD>
        """
        let base = URL(string:"https://cdn.example/programme/master.mpd?token=example")!
        let parsed = try DASHManifest.parse(Data(xml.utf8),url:base)
        precondition(parsed.video.height==2160 && parsed.video.width==3840 && parsed.audio.codec=="mp4a.40.2","Select 4K video with separate compatible audio")
        precondition(parsed.video.segments.count==3 && parsed.video.segments.last?.duration==2,"VOD segmentation and final duration")
        precondition(parsed.video.segments[0].url.path=="/programme/video-high/000001.m4s" && parsed.video.segments[0].url.query=="token=example","DASH template formatting and signed query propagation")
        precondition(parsed.video.playlist.contains("#EXT-X-MAP:") && parsed.video.playlist.contains("#EXT-X-ENDLIST"),"fMP4 initialization and VOD playlist")
        precondition(String(decoding:parsed.playlists["/master.m3u8"]!,as:UTF8.self).contains("VIDEO-RANGE=HLG"),"HLG master signalling")
        let timelineXML=xml.replacingOccurrences(of:"duration=\"4000\"",with:"presentationTimeOffset=\"10000\"").replacingOccurrences(of:"media=\"$RepresentationID$/$Number%06d$.m4s\"/>",with:"media=\"$RepresentationID$/$Time$.m4s\"><SegmentTimeline><S t=\"10000\" d=\"4000\" r=\"-1\"/></SegmentTimeline></SegmentTemplate>")
        let timeline=try DASHManifest.parse(Data(timelineXML.utf8),url:base)
        precondition(timeline.video.segments.count==3 && timeline.video.segments[0].url.path.hasSuffix("/10000.m4s"),"Timeline repeats, presentation offset and time template")
        var initialization=Data([0,0,0,19]);initialization.append(Data("colrnclx".utf8));initialization.append(contentsOf:[0,9,0,18,0,9,0])
        precondition(DASHManifest.signalsHLG(initialization),"HLG transfer 18 with BT.2020 primaries")
        var sdr=initialization;sdr[15]=14
        precondition(!DASHManifest.signalsHLG(sdr),"Do not label BT.2020 SDR as HLG")
        let protected=xml.replacingOccurrences(of:"<Period>",with:"<Period><ContentProtection schemeIdUri=\"urn:example\"/>")
        do {_ = try DASHManifest.parse(Data(protected.utf8),url:base);fatalError("Protected presentation accepted")}catch{}
        do {_ = try DASHManifest.parse(Data(xml.replacingOccurrences(of:"type=\"static\"",with:"type=\"dynamic\"").utf8),url:base);fatalError("Dynamic presentation accepted")}catch{}
        let server=LocalHLSServer();let url=try await server.start(playlists:parsed.playlists)
        let (data,response)=try await URLSession.shared.data(from:url)
        precondition((response as? HTTPURLResponse)?.statusCode==200 && String(decoding:data,as:UTF8.self).contains("RESOLUTION=3840x2160"),"Loopback playlist delivery")
        let (_,missing)=try await URLSession.shared.data(from:url.deletingLastPathComponent().appendingPathComponent("private-key.pem"))
        precondition((missing as? HTTPURLResponse)?.statusCode==404,"Loopback server never serves arbitrary files")
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        let (head, headResponse) = try await URLSession.shared.data(for: request)
        precondition(head.isEmpty && (headResponse as? HTTPURLResponse)?.statusCode == 200, "HEAD does not send a response body")
        request.httpMethod = "GET"; request.setValue("bytes=0-6", forHTTPHeaderField: "Range")
        let (partial, partialResponse) = try await URLSession.shared.data(for: request)
        precondition(partial == Data("#EXTM3U".utf8) && (partialResponse as? HTTPURLResponse)?.statusCode == 206, "HTTP byte-range delivery")
        precondition(LocalHLSServer.byteRange("bytes=-3", count: 10) == 7..<10 && LocalHLSServer.byteRange("bytes=4-", count: 10) == 4..<10, "Suffix and open-ended ranges")
        precondition(LocalHLSServer.byteRange("bytes=10-", count: 10) == nil && LocalHLSServer.byteRange("bytes=0-1,4-5", count: 10) == nil, "Invalid ranges rejected")
        let videoPlaylist = String(decoding: parsed.playlists["/video.m3u8"]!, as: UTF8.self)
        precondition(videoPlaylist.contains("video/init.mp4") && videoPlaylist.contains("video/0.m4s") && !videoPlaylist.contains("https://"), "Every fragment goes through the normalization bridge")
        precondition(parsed.mediaResources["/video/0.m4s"] == parsed.video.segments[0].url, "Bridge allowlist preserves signed CDN URLs")
        server.stop()
        try await fragmentRegressionTests()
        print("PASS: DASH templates/timelines, audio selection, HLG detection, protection checks, and loopback HLS/ranges and padded-fragment regression")
    }
}

// Small synthetic boxes exercise the precise failure without bundling BBC media.
private func be(_ value: Int, _ count: Int = 4) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ((count - 1 - $0) * 8)) })
}
private func box(_ type: String, _ payload: Data) -> Data { be(payload.count + 8) + Data(type.utf8) + payload }
private func fragment(padding: Int, extended: Bool = false, toEnd: Bool = false) -> Data {
    let tfhd = box("tfhd", be(0x020000) + be(1))
    func moof(_ offset: Int) -> Data {
        box("moof", box("mfhd", be(0) + be(18)) + box("traf", tfhd + box("tfdt", be(0x01000000) + be(65280, 8)) + box("trun", be(0x00000201) + be(1) + be(offset) + be(4))))
    }
    let header = extended ? 16 : 8
    let m = moof(moof(0).count + header + padding)
    let payload = Data(repeating: 0xbc, count: padding) + Data([0x21,0x1a,0x94,0x6d])
    let media = extended ? be(1) + Data("mdat".utf8) + be(payload.count + 16, 8) + payload : be(toEnd ? 0 : payload.count + 8) + Data("mdat".utf8) + payload
    return m + media
}
private final class FragmentProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cdn.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = fragment(padding: 2)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func fragmentRegressionTests() async throws {
    for padding in [0, 2, 16] {
        for extended in [false, true] {
            let corrected = try FMP4Normalizer.normalize(fragment(padding: padding, extended: extended))
            precondition(corrected == fragment(padding: 0, extended: extended), "Remove padding, fix mdat size and trun offset, preserve encoded samples")
            let again = try FMP4Normalizer.normalize(corrected)
            precondition(again == corrected, "Normalization is idempotent")
        }
    }
    let sizeToEnd = try FMP4Normalizer.normalize(fragment(padding: 2, toEnd: true))
    precondition(sizeToEnd == fragment(padding: 0, toEnd: true), "Size-to-end mdat")
    for invalid in [Data([0, 1, 2]), fragment(padding: 4097), Data(fragment(padding: 2).dropLast())] {
        do { _ = try FMP4Normalizer.normalize(invalid); fatalError("Malformed fragment accepted") } catch {}
    }
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FragmentProtocol.self]
    let server = LocalHLSServer(configuration: configuration)
    let master = try await server.start(playlists: [:], media: ["/video/18.m4s": URL(string: "https://cdn.example/video/18.m4s?token=test")!])
    let url = master.deletingLastPathComponent().appendingPathComponent("video/18.m4s")
    let (normalized, response) = try await URLSession.shared.data(from: url)
    precondition((response as? HTTPURLResponse)?.statusCode == 200 && normalized == fragment(padding: 0), "Real bridge normalizes remote fragments")
    var request = URLRequest(url: url); request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
    let (partial, partialResponse) = try await URLSession.shared.data(for: request)
    precondition((partialResponse as? HTTPURLResponse)?.statusCode == 206 && partial == normalized.prefix(16), "Ranges apply after normalization")
    server.stop()
}
