import Foundation
@main struct Channel5PairingTests {
    static func main() throws {
        let session = Data(#"{"sessionId":"fixture-account-session"}"#.utf8)
        let created = try Channel5PairingResponse.session(from:Channel5Response(data:session,status:201))
        precondition(created == "fixture-account-session", "HTTP 201 completes pairing")
        let existing = try Channel5PairingResponse.session(from:Channel5Response(data:session,status:200))
        precondition(existing == created, "HTTP 200 remains supported")
        let pending = try Channel5PairingResponse.session(from:Channel5Response(data:Data(),status:204))
        precondition(pending == nil, "HTTP 204 continues polling")
        for response in [Channel5Response(data:session,status:401),Channel5Response(data:session,status:403),Channel5Response(data:session,status:404),Channel5Response(data:session,status:410),Channel5Response(data:Data("{}".utf8),status:201),Channel5Response(data:Data(#"{"sessionId":""}"#.utf8),status:201),Channel5Response(data:Data(#"{"sessionId":"value\r\nInjected: header"}"#.utf8),status:201)] {
            do { _ = try Channel5PairingResponse.session(from:response); preconditionFailure("An invalid pairing response was accepted") } catch { }
        }
        print("PASS Channel 5 pairing: 201 session creation, 200 compatibility, 204 waiting, expired/denied responses and invalid session rejection.")
    }
}
