import Foundation
@main struct PlaybackPolicyTests {
    static func main() async throws {
        let hd = PlaybackSource(url: URL(string: "https://cdn.example/hd.m3u8")!, requested1080: true)
        let uhd = PlaybackSource(url: URL(string: "http://127.0.0.1/4k.m3u8")!, requested1080: true, requestedHeight: 2160, videoRange: "HLG")
        var hdCalled = false
        let best = try await PlaybackPolicy.bestSource(uhd: { uhd }, hd: { hdCalled = true; return hd })
        precondition(best.requestedHeight == 2160 && !hdCalled, "Prefer playable UHD without fetching HD")
        let fallback = try await PlaybackPolicy.bestSource(uhd: { throw BBCError.message("Unavailable") }, hd: { hdCalled = true; return hd })
        precondition(fallback.url == hd.url && hdCalled, "Unavailable UHD falls back to best HD")
        let unconfigured = try await PlaybackPolicy.bestSource(uhd: nil, hd: { hd })
        precondition(unconfigured.url == hd.url, "HD works without UHD configuration")
        hdCalled = false
        do {
            _ = try await PlaybackPolicy.bestSource(uhd: { throw CancellationError() }, hd: { hdCalled = true; return hd })
            fatalError("Cancellation swallowed")
        } catch is CancellationError {}
        precondition(!hdCalled, "Cancellation must not start fallback playback")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PlaybackPolicy.bestSource(uhd: { fatalError("Cancelled request started") }, hd: { fatalError("Cancelled fallback started") })
        }
        do { _ = try await cancelled.value; fatalError("Cancelled task accepted") } catch is CancellationError {}
        do {
            _ = try await PlaybackPolicy.bestSource(uhd: nil, hd: { throw BBCError.message("HD unavailable") })
            fatalError("Missing fallback error")
        } catch let error as BBCError { precondition(error.localizedDescription == "HD unavailable") }
        for (height, range, label) in [(2160,"HLG","4K"),(2160,"PQ","4K"),(2160,"SDR","4K"),(1080,"SDR","FHD"),(720,"SDR","HD"),(576,"SDR","SD"),(480,"SDR","SD")] {
            precondition(PlaybackPolicy.badge(height: height, videoRange: range) == label, "Received quality badge")
        }
        precondition(PlaybackPolicy.badge(height: 0, videoRange: "HLG") == nil, "Do not show a requested quality as received")
        print("PASS: automatic UHD priority, HD fallback, cancellation, errors and received-quality badges")
    }
}
