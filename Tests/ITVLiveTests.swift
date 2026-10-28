import Foundation

func check(_ value: Bool, _ message: String) { precondition(value, message) }
func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func session(_ suffix: String = "one") -> Data {
    json(["access_token": "access-" + suffix, "refresh_token": "refresh-" + suffix, "expires_in": 3600])
}
func playlist(_ locations: [[String: Any]] = [["Url":"https://live.example.content.itv.com/live/master.m3u8?session=fixture","IsDar":false]]) -> Data {
    json(["Playlist":["Video":["VideoLocations":locations]]])
}
final class MemoryVault: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ITVCredentials?
    private var count = 0
    init(_ value: ITVCredentials? = nil) { self.value = value }
    func read() -> ITVCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: ITVCredentials) { lock.lock(); defer { lock.unlock() }; self.value = value; count += 1 }
    func remove() { lock.lock(); defer { lock.unlock() }; value = nil }
    func writes() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    var vault: ITVAccountVault { ITVAccountVault(read: { self.read() }, write: { self.write($0) }, remove: { self.remove() }) }
}
actor FixtureServer {
    var requests: [URLRequest] = []
    var pending = true
    var liveStatus = 401
    var renewStatus = 200
    var refreshes = 0
    var liveCalls = 0
    func send(_ request: URLRequest) async throws -> ITVHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        if path == "/generate/code" { return ITVHTTPResponse(data: json(["code":"123456"]), status: 200) }
        if path == "/verify/123456" {
            if pending { pending = false; return ITVHTTPResponse(data: json(["error":"Code Not Found"]), status: 404) }
            return ITVHTTPResponse(data: json(["token":"pair-refresh"]), status: 200)
        }
        if path == "/token" {
            refreshes += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            return ITVHTTPResponse(data: session(String(refreshes)), status: renewStatus)
        }
        if path.hasPrefix("/playlist/itvonline/") {
            liveCalls += 1
            let status = liveStatus; if status == 401 { liveStatus = 200 }
            return ITVHTTPResponse(data: playlist(), status: status)
        }
        fatalError("Unexpected fixture endpoint")
    }
    func stats() -> (refreshes: Int, live: Int) { (refreshes, liveCalls) }
    func configuration(live: Int = 200, renewal: Int = 200) { liveStatus = live; renewStatus = renewal }
    func captured() -> [URLRequest] { requests }
}
actor PausedServer {
    var continuation: CheckedContinuation<ITVHTTPResponse, Never>?
    func send(_ request: URLRequest) async -> ITVHTTPResponse {
        if request.url!.path.hasPrefix("/verify/") { return ITVHTTPResponse(data: json(["token":"test-refresh"]), status: 200) }
        return await withCheckedContinuation { continuation = $0 }
    }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(returning: ITVHTTPResponse(data: session(), status: 200)); continuation = nil }
}
@main struct ITVLiveChecks {
    static func main() async throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let date = ISO8601DateFormatter().date(from: "2026-10-23T13:00:00Z")!
        let channels = try ITVLiveAPI.channels(from: fixture, now: date)
        check(channels.count == 25, "All 25 channels in the observed public feed are retained")
        check(Array(channels.prefix(5)).map(\.title) == ["ITV1","ITV2","ITVBe","ITV3","ITV4"], "Main channels precede themed channels")
        check(channels[0].provider == .itv && channels[0].current?.title == "ITV Racing", "ITV routing and current schedule")
        let stale = try ITVLiveAPI.channels(from: fixture, now: date.addingTimeInterval(7 * 86400))
        check(stale.allSatisfy { $0.current == nil }, "Stale schedules are never displayed as on now")
        let oldBBC = try JSONDecoder().decode(LiveChannel.self, from: json(["id":"bbc_one_london","title":"BBC One"]))
        check(oldBBC.provider == .bbc && oldBBC.itvPlaylistURL == nil, "Existing BBC channels remain compatible")
        let expected = try ITVLiveAPI.playbackURL(from: playlist())
        check(expected.query == "session=fixture", "Signed HLS URL remains unmodified")
        for bad in ["http://simulcast.itv.com/playlist/itvonline/ITV", "https://simulcast.itv.com.evil.example/playlist/itvonline/ITV", "https://simulcast.itv.com/playlist/itvonline/../ITV", "https://simulcast.itv.com/playlist/itvonline/ITV?x=y"] {
            do { _ = try ITVLiveAPI.endpoint(URL(string: bad)!); fatalError("Unsafe endpoint accepted") } catch {}
        }
        for locations: [[String: Any]] in [
            [["Url":"https://evil.example/live.m3u8"]],
            [["Url":"https://cdn.content.itv.com/live.mpd"]],
            [["Url":"https://cdn.content.itv.com/live.m3u8", "IsDar":true]]
        ] {
            do { _ = try ITVLiveAPI.playbackURL(from: playlist(locations)); fatalError("Unsupported media accepted") } catch {}
        }
        let server = FixtureServer(), memory = MemoryVault()
        let api = ITVAccountService(transport: { try await server.send($0) }, vault: memory.vault)
        let code = try await api.newCode(); check(code == "123456", "Device pairing code")
        let pending = try await api.checkCode(code); check(!pending && memory.read() == nil, "404 means awaiting approval, no account persisted")
        let paired = try await api.checkCode(code); check(paired && memory.read() != nil, "Approved code exchanges its token and persists the issued session")
        let url = try await api.liveURL(channel: channels[0], osVersion: "26.0", model: "Apple TV")
        check(url == expected, "Live response resolves without altering its URL")
        let stats = await server.stats(); check(stats.refreshes == 2 && stats.live == 2, "Playback 401 renews once and retries once")
        let requests = await server.captured()
        let firstExchange = requests.first { $0.url?.path == "/token" }!
        check(URLComponents(url: firstExchange.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "pair-refresh", "Verify token is used as the refresh token")
        let liveRequest = requests.first { $0.httpMethod == "POST" }!
        let body = try JSONSerialization.jsonObject(with: liveRequest.httpBody!) as! [String: Any]
        check((body["variantAvailability"] as? [String: Any])?["platformTag"] as? String == "ctv", "Live requests negotiate CTV")
        check((body["device"] as? [String: Any])?["manufacturer"] as? String == "Apple", "Native device description")
        check((body["user"] as? [String: Any])?["token"] as? String != nil, "Live session uses Telly's account token")
        try await api.signOut(); check(memory.read() == nil, "Sign-out clears stored credentials")
        do { _ = try await api.liveURL(channel: channels[0], osVersion:"26", model:"TV"); fatalError("Signed-out playback accepted") }
        catch ITVAccountError.signInRequired {}
        let expired = ITVCredentials(accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast)
        let concurrentServer = FixtureServer(), concurrentMemory = MemoryVault(expired)
        await concurrentServer.configuration()
        let concurrentAPI = ITVAccountService(transport: { try await concurrentServer.send($0) }, vault: concurrentMemory.vault)
        async let one = concurrentAPI.liveURL(channel: channels[0], osVersion:"26", model:"TV")
        async let two = concurrentAPI.liveURL(channel: channels[1], osVersion:"26", model:"TV")
        _ = try await (one, two)
        let concurrentStats = await concurrentServer.stats()
        check(concurrentStats.refreshes == 1 && concurrentMemory.writes() == 1, "Simultaneous channel requests share one token renewal")
        let deniedServer = FixtureServer(), deniedMemory = MemoryVault(expired)
        await deniedServer.configuration(renewal: 401)
        let deniedAPI = ITVAccountService(transport: { try await deniedServer.send($0) }, vault: deniedMemory.vault)
        do { _ = try await deniedAPI.liveURL(channel: channels[0], osVersion:"26", model:"TV"); fatalError("Invalid renewal accepted") }
        catch ITVAccountError.signInRequired {}
        check(deniedMemory.read() == nil, "Rejected refresh requests a fresh sign-in")
        for cancellation in [false,true] {
            let paused = PausedServer(), memory = MemoryVault()
            let api = ITVAccountService(transport: { await paused.send($0) }, vault: memory.vault)
            let task = Task { try await api.checkCode("123456") }
            while !(await paused.waiting()) { await Task.yield() }
            if cancellation { task.cancel() } else { try await api.signOut() }
            await paused.release()
            do { _ = try await task.value; fatalError("Cancelled pairing succeeded") } catch is CancellationError {}
            check(memory.read() == nil && memory.writes() == 0, "Cancellation/sign-out during pairing cannot restore credentials")
        }
        if CommandLine.arguments.contains("--network") {
            let memory = MemoryVault(), api = ITVAccountService(vault: memory.vault)
            let code = try await api.newCode()
            let approved = try await api.checkCode(code)
            check(!approved && memory.read() == nil, "Real ITV code generation and unapproved polling work without browser credentials")
            let live = try await ITVLiveAPI().channels()
            check(!live.isEmpty && live.allSatisfy { $0.provider == .itv }, "Real ITV live feed parses")
            print("Native URLSession network checks passed: code generation, pending verification and live channel feed.")
        }
        print("ITV live/account checks passed: 25 channels, stale schedules, URL validation, pairing, renewal/retry, concurrent refresh and cancellation/sign-out races.")
    }
}
