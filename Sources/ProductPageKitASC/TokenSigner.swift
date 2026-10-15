import CryptoKit
import Foundation

/// The ES256 bearer token App Store Connect accepts: valid for 15 minutes,
/// reused until a minute before it expires.
actor TokenSigner {
    let credentials: Credentials
    let now: @Sendable () -> Date
    private var cached: (token: String, expiry: Date)?

    static let lifetime: TimeInterval = 15 * 60

    init(credentials: Credentials, now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials
        self.now = now
    }

    func token() throws -> String {
        let issued = now()
        if let cached, issued < cached.expiry.addingTimeInterval(-60) { return cached.token }
        let token = try Self.sign(credentials: credentials, issuedAt: issued)
        cached = (token, issued.addingTimeInterval(Self.lifetime))
        return token
    }

    static func sign(credentials: Credentials, issuedAt: Date) throws -> String {
        struct Header: Encodable {
            let alg = "ES256"
            let kid: String
            let typ = "JWT"
        }
        struct Payload: Encodable {
            let iss: String
            let iat: Int
            let exp: Int
            let aud = "appstoreconnect-v1"
        }
        let issued = Int(issuedAt.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = try encoder.encode(Header(kid: credentials.keyID)).base64URL
        let payload = try encoder.encode(Payload(iss: credentials.issuerID, iat: issued, exp: issued + Int(lifetime))).base64URL
        let input = "\(header).\(payload)"
        let signature = try credentials.privateKey.signature(for: Data(input.utf8))
        return "\(input).\(signature.rawRepresentation.base64URL)"
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
