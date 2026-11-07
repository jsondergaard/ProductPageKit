public import Foundation
public import ProductPageKitCore
import Security

/// A Google Cloud service account's JSON key, which the Play Console has
/// been given access to under Users and permissions. It needs to manage the
/// store presence.
public struct PlayCredentials: Sendable {
    public let clientEmail: String
    /// The key's PKCS #1 RSA private key, DER.
    let privateKey: Data
    /// Where the account trades a signed assertion for an access token.
    public let tokenURI: URL

    /// `PLAY_KEY_PATH`, a key file, or `PLAY_KEY_JSON`, the key itself.
    public init(environment: Environment) throws {
        if let json = environment[Self.jsonVariable] {
            try self.init(json: Data(json.utf8), source: Self.jsonVariable)
        } else if let path = environment[Self.pathVariable] {
            let expanded = NSString(string: path).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: expanded) else { throw PlayCredentialsError.noKeyFile(expanded) }
            try self.init(json: data, source: expanded)
        } else {
            throw PlayCredentialsError.missing
        }
    }

    /// - Parameter source: where the key was read, for an error to name.
    public init(json: Data, source: String) throws {
        struct Key: Decodable {
            let type: String?
            let client_email: String?
            let private_key: String?
            let token_uri: String?
        }
        guard let key = try? JSONDecoder().decode(Key.self, from: json), key.type == "service_account",
              let email = key.client_email, let pem = key.private_key,
              let der = PEM.decode(pem, label: "PRIVATE KEY"), let rsa = PEM.rsaKey(fromPKCS8: der),
              Self.secKey(rsa) != nil
        else { throw PlayCredentialsError.unreadableKey(source) }
        clientEmail = email
        privateKey = rsa
        tokenURI = key.token_uri.flatMap(URL.init(string:)) ?? URL(string: "https://oauth2.googleapis.com/token")!
    }

    public static let pathVariable = "PLAY_KEY_PATH"
    public static let jsonVariable = "PLAY_KEY_JSON"

    /// `data` signed with RSASSA-PKCS1-v1_5 and SHA-256, as RS256 asks.
    func sign(_ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let key = Self.secKey(privateKey),
              let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error)
        else { throw PlayCredentialsError.signing(error?.takeRetainedValue().localizedDescription ?? "no key") }
        return signature as Data
    }

    static func secKey(_ pkcs1: Data) -> SecKey? {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        return SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil)
    }
}

public enum PlayCredentialsError: Error, CustomStringConvertible {
    case missing
    case noKeyFile(String)
    case unreadableKey(String)
    case signing(String)

    public var description: String {
        switch self {
        case .missing:
            "Missing \(PlayCredentials.pathVariable), a service account's JSON key file, or \(PlayCredentials.jsonVariable), the key itself. Put one in the repository's .env or export it. The account needs access to the app in the Play Console."
        case .noKeyFile(let path):
            "\(PlayCredentials.pathVariable) does not exist: \(path)"
        case .unreadableKey(let source):
            "\(source) is not a service account's JSON key with an RSA private key."
        case .signing(let reason):
            "Could not sign the Google Play token: \(reason)"
        }
    }
}

/// PEM text, and the DER inside it.
enum PEM {
    /// The DER between `-----BEGIN label-----` and its end line.
    static func decode(_ pem: String, label: String) -> Data? {
        let begin = "-----BEGIN \(label)-----", end = "-----END \(label)-----"
        guard let start = pem.range(of: begin), let stop = pem.range(of: end, range: start.upperBound..<pem.endIndex)
        else { return nil }
        return Data(base64Encoded: String(pem[start.upperBound..<stop.lowerBound]).filter { !$0.isWhitespace })
    }

    /// The PKCS #1 `RSAPrivateKey` a PKCS #8 `PrivateKeyInfo` wraps:
    /// `SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING key }`.
    static func rsaKey(fromPKCS8 der: Data) -> Data? {
        var outer = DER(der)
        guard var info = outer.read(tag: 0x30).map(DER.init), outer.isAtEnd,
              info.read(tag: 0x02) != nil, info.read(tag: 0x30) != nil
        else { return nil }
        return info.read(tag: 0x04)
    }
}

/// Reads DER one element at a time.
struct DER {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool { offset == bytes.count }

    /// The contents of the next element when its tag is `tag`.
    mutating func read(tag: UInt8) -> Data? {
        guard offset + 2 <= bytes.count, bytes[offset] == tag else { return nil }
        var index = offset + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), index + count <= bytes.count else { return nil }
            length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard index + length <= bytes.count else { return nil }
        offset = index + length
        return Data(bytes[index..<offset])
    }
}
