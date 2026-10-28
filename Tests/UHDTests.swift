import Foundation
@main struct UHDTests {
    static func main() async throws {
        let episode: [String:Any] = ["id":"m002cgz3","title":"The Americas","versions":[["id":"m002cgz2","kind":"original","uhd":true],["id":"p0lbp12q","kind":"audio-described","uhd":false]]]
        let parsed = try CatalogueAPI.episode(episode)
        precondition(parsed.programme.uhdListed == true,"UHD availability comes from selected BBC version metadata")
        let show = try CatalogueAPI.show(["id":"m0028nf0","title":"The Americas","count":1,"initial_children":[episode]])
        precondition(show.uhdListed == true,"Show badge comes from episode metadata")
        let old = try JSONDecoder().decode(Programme.self,from:Data("{\"id\":\"m002cgz3\",\"title\":\"The Americas\",\"summary\":\"\",\"version\":\"m002cgz2\"}".utf8))
        precondition(old.uhdListed == nil,"Old cache does not invent 4K availability")
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=24000000,CODECS="hvc1.2.4.L153.B0,mp4a.40.2",RESOLUTION=3840x2160,VIDEO-RANGE=HLG
        4k.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="avc1.64002A,mp4a.40.2",RESOLUTION=1920x1080
        hd.m3u8
        """
        let variants=BBCService.variants(master,base:URL(string:"https://cdn.example/master.m3u8")!)
        precondition(variants.count==2 && UHDService.compatible(variants[0]) && !UHDService.compatible(variants[1]),"Separate HEVC HLG 2160p from HD")
        var sdr=variants[0];sdr.videoRange="SDR";precondition(!UHDService.compatible(sdr),"Do not claim HLG for SDR")
        var avc=variants[0];avc.codecs="avc1.640033";precondition(!UHDService.compatible(avc),"Require compatible HEVC signalling")
        let selector = Data("<mediaSelection><media kind=\"video\"><connection transferFormat=\"hls\" href=\"https://cdn.example/master.m3u8\"/></media></mediaSelection>".utf8)
        let media="#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:8,\nsegment.m4s\n#EXT-X-ENDLIST\n"
        let service=UHDService(fetch:{url in
            if url.host=="open.live.bbc.co.uk" {return selector}
            return Data((url.path.contains("master") ? master:media).utf8)
        })
        let source=try await service.source(for:parsed.programme)
        precondition(source.requestedHeight==2160 && source.videoRange=="HLG" && source.url.lastPathComponent=="4k.m3u8","Only expose actual HLG HLS source")
        let encrypted=UHDService(fetch:{url in
            if url.host=="open.live.bbc.co.uk" {return selector}
            return Data((url.path.contains("master") ? master:media+"#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\"\n").utf8)
        })
        do {_ = try await encrypted.source(for:parsed.programme);fatalError("Encrypted source accepted without supported licence integration")}catch{}
        let unavailable=UHDService(fetch:{_ in Data("<mediaSelection><error id=\"selectionunavailable\"/></mediaSelection>".utf8)})
        do {_ = try await unavailable.source(for:parsed.programme);fatalError("Catalogue flag was mistaken for playback access")}catch{}
        print("PASS: UHD metadata, backward compatibility, codec/range validation, real-source gating, protected-source rejection and unavailable-service handling")
    }
}
