import Foundation

final class UTestVault: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UCredentials?
    private(set) var writes = 0
    func read() -> UCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: UCredentials) { lock.lock(); defer { lock.unlock() }; self.value = value; writes += 1 }
    func remove() { lock.lock(); defer { lock.unlock() }; value = nil }
    var vault: UAccountVault { UAccountVault(read:{ self.read() },write:{ self.write($0) },remove:{ self.remove() }) }
}
actor UPollFixture {
    let code: Data
    let account: Data
    var polls = 0
    var waiter: CheckedContinuation<UResponse,Never>?
    var hold = false
    init(code: Data, account: Data) { self.code = code; self.account = account }
    func setHold() { hold = true }
    func waiting() -> Bool { waiter != nil }
    func finish() { waiter?.resume(returning:UResponse(data:account,status:200)); waiter = nil }
    func send(_ url: URL) async -> UResponse {
        if url.path == "/get_code" { return UResponse(data:code,status:200) }
        if hold { return await withCheckedContinuation { waiter = $0 } }
        polls += 1
        return polls == 1 ? UResponse(data:Data(#"{"error":"No user details found for code pair"}"#.utf8),status:404) : UResponse(data:account,status:200)
    }
}
@main struct UPlaybackTests {
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value) }
    static func mustFail(_ block: () throws -> Void) {
        do { try block(); fatalError("Expected a validation error") } catch { }
    }
    static func main() async throws {
        let now = Date(timeIntervalSince1970:1793100000)
        let code = try json(["code":"AB12C","match_code":"A02467AF-BBF2-469D-BDF5-ED892C76C477","qr_code":"<svg/> walled off from UI"])
        let account = try json(["int_mpp_id":12345678,"mpp_session_token":"fixture-session-0123456789abcdef","long_session_expiry":"2099-11-06T15:02:45.0714611+00:00","first_name":"Not retained","gender":"Not retained","age":"Not retained"])
        let pairing = try UPairing.parse(code,revision:UUID(),now:now)
        precondition(pairing.activationURL.absoluteString == "https://u.co.uk/activate?code=AB12C")
        precondition(pairing.checkURL.host == "tvlogin.uktvapi.co.uk")
        precondition(pairing.expiresAt.timeIntervalSince(now) == 1800)
        let session = try UCredentials.parse(account,now:now)
        precondition(session.accountID == "12345678" && session.expiresAt > now)
        let saved = try JSONSerialization.jsonObject(with:JSONEncoder().encode(session)) as! [String:Any]
        precondition(Set(saved.keys) == ["accountID","sessionToken","expiresAt"],"Personal profile fields must not be retained")
        mustFail { _ = try UPairing.parse(json(["code":"../bad","match_code":"bad"]),revision:UUID()) }
        mustFail { _ = try UCredentials.parse(json(["int_mpp_id":123,"mpp_session_token":"bad\r\nheader-value-123","long_session_expiry":"2099-01-01T00:00:00Z"])) }
        mustFail { _ = try UCredentials.parse(account,now:Date(timeIntervalSince1970:5000000000)) }
        let memory = UTestVault(), server = UPollFixture(code:code,account:account)
        let service = UAccountService(vault:memory.vault,fetch:{ await server.send($0) })
        let pin = try await service.newCode()
        let pending = try await service.check(pin,now:now); precondition(!pending && memory.read() == nil)
        let complete = try await service.check(pin,now:now); precondition(complete && memory.read()?.accountID == session.accountID)
        let signedIn = try await service.isSignedIn(now:now); precondition(signedIn)
        try await service.signOut(); let signedOut = try await service.isSignedIn(now:now); precondition(!signedOut)
        let stale = try await service.newCode(); _ = try await service.newCode()
        do { _ = try await service.check(stale,now:now); fatalError("Replaced codes must be invalidated") } catch is CancellationError { }
        let active = try await service.newCode(); await server.setHold()
        let late = Task { try await service.check(active,now:now) }
        for _ in 0..<200 { if await server.waiting() { break }; try await Task.sleep(nanoseconds:1_000_000) }
        await service.cancel(active); await server.finish()
        do { _ = try await late.value; fatalError("Cancelled pairing must not save a late response") } catch is CancellationError { }
        precondition(memory.read() == nil)

        let certificate = "https://manifest.prod.boltdns.net/license/v1/fairplay_app_cert/1242911124001"
        let licence = "https://manifest.prod.boltdns.net/license/v1/fairplay/1242911124001/asset/key?fastly_token=fixture"
        let manifest = "https://manifest.prod.boltdns.net/manifest/v1/hls/fairplay/master.m3u8?fastly_token=fixture"
        let source: [String:Any] = ["type":"application/x-mpegURL","src":manifest,"key_systems":["com.apple.fps.1_0":["certificate_url":certificate,"key_request_url":licence]]]
        let metadata = try json(["id":"6406235534112","sources":[source]])
        let (hls,cert,config) = try UPlaybackWire.fairPlay(metadata,id:"6406235534112",now:now)
        precondition(hls.absoluteString == manifest && cert.absoluteString == certificate && config.licence.absoluteString == licence)
        mustFail { _ = try UPlaybackWire.fairPlay(metadata,id:"different") }
        mustFail { _ = try UPlaybackWire.videoURL("../other") }
        precondition(!UHTTP.allowed(URL(string:"https://attacker.example/get_code")!))
        precondition(!UHTTP.allowed(URL(string:"https://edge.api.brightcove.com/playback/v1/accounts/999/videos/123")!))
        precondition(!UHTTP.mediaAllowed(URL(string:"http://manifest.prod.boltdns.net/a.m3u8")!))
        let raw = "skd://assetId=71e78848-9cd6-47aa-8b3b-d7d8cc44eef0&variantId=fairplay"
        let contentID = try UPlaybackWire.contentID(raw)
        precondition(contentID == String(raw.dropFirst(6)),"Brightcove identifiers must retain query spelling and case")
        let spc = Data([0,1,2,254,255])
        let body = try JSONSerialization.jsonObject(with:UPlaybackWire.licenceBody(spc:spc,contentID:contentID)) as! [String:Any]
        precondition(body["server_playback_context"] as? String == spc.base64EncodedString())
        precondition(body["key_id"] == nil && body["publisher_id"] == nil,"Dynamic Delivery omits undefined legacy fields")
        let legacy = try JSONSerialization.jsonObject(with:UPlaybackWire.licenceBody(spc:spc,contentID:"publisher/application/key/id")) as! [String:Any]
        precondition(legacy["key_id"] as? String == "id")
        mustFail { _ = try UPlaybackWire.contentID("https://unexpected.example/key") }
        print("PASS U playback: real-format pairing/expiry, minimal secure credentials, pending/complete states, cancellation/stale-response protection, source ownership/HTTPS, exact SKD identifiers and Brightcove JSON licence transport.")
        if CommandLine.arguments.contains("--network") {
            let player = try await UHTTP.shared.send(UPlaybackWire.playerConfigURL)
            precondition(player.status == 200)
            let policy = try UPlaybackWire.policy(player.data)
            for id in ["6406235534112","6377027362112","6405813926112"] {
                let response = try await UHTTP.shared.send(UPlaybackWire.videoURL(id),policy:policy)
                precondition(response.status == 200)
                let (_,cert,_) = try UPlaybackWire.fairPlay(response.data,id:id)
                let certificate = try await UHTTP.shared.send(cert,limit:16384)
                precondition(certificate.status == 200 && certificate.data.count > 500 && certificate.data.first == 0x30)
                print("LIVE U playback metadata and FairPlay certificate: \(id), certificate \(certificate.data.count) bytes")
            }
        }
    }
}
