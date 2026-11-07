import CryptoKit
public import Foundation
public import HTTPTypes
public import ProductPageKitCore
public import ProductPageKitPlay
import Security

/// Google Play's Publishing API and its token endpoint, in memory: edits
/// copy the live listing, change their copy, and replace the live one when
/// committed. Tokens are granted only to assertions the test key signed.
public final class FakeGooglePlay: PlayTransport, @unchecked Sendable {
    public struct Image: Equatable, Sendable {
        public let id: String
        public let data: Data

        public init(id: String, data: Data) {
            self.id = id
            self.data = data
        }
    }

    public struct State: Equatable, Sendable {
        public var defaultLanguage = "en-US"
        public var listings: [String: PlayListing] = [:]
        /// By language, then by slot.
        public var images: [String: [PlayImageType: [Image]]] = [:]
        public var tracks: [PlayTrack] = []

        public init() {}
    }

    private let lock = NSLock()
    private var current: State
    private var edits: [String: State] = [:]
    private var log: [String] = []
    private var commits: [String] = []
    private var counter = 0
    private var failing: (method: String, path: String)?
    private let publicKey: SecKey

    public static let packageName = "com.example.app"

    public init(_ live: State = State()) {
        current = live
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        publicKey = SecKeyCopyPublicKey(SecKeyCreateWithData(Self.pkcs1 as CFData, attributes as CFDictionary, nil)!)!
    }

    /// The committed listing.
    public var live: State { lock.withLock { current } }
    /// `METHOD path` of every API request, in order.
    public var requests: [String] { lock.withLock { log } }
    /// Each commit's query: empty, or `changesNotSentForReview=true`.
    public var commitQueries: [String] { lock.withLock { commits } }
    /// Edits opened and neither committed nor deleted.
    public var openEdits: Int { lock.withLock { edits.count } }

    /// Replaces the committed listing.
    public func reset(to state: State) {
        lock.withLock { current = state }
    }

    /// Answers the first request whose method is `method` and whose path
    /// contains `path` with a server error.
    public func fail(_ method: String, _ path: String) {
        lock.withLock { failing = (method, path) }
    }

    public func send(_ request: HTTPRequest, body: Data?) async throws -> (HTTPResponse, Data) {
        lock.withLock { answer(request, body: body ?? Data()) }
    }

    private func answer(_ request: HTTPRequest, body: Data) -> (HTTPResponse, Data) {
        let full = request.path ?? ""
        let path = String(full.prefix { $0 != "?" })
        let query = full.contains("?") ? String(full.drop { $0 != "?" }.dropFirst()) : ""
        let method = request.method.rawValue
        if request.authority == "oauth2.example" { return token(body) }
        guard request.headerFields[.authorization]?.hasPrefix("Bearer token-") == true else { return error(401, "no token") }
        log.append("\(method) \(path)")
        if let failing, failing.method == method, path.contains(failing.path) {
            self.failing = nil
            return error(500, "scripted failure")
        }
        let base = "/androidpublisher/v3/applications/\(Self.packageName)/edits"
        let upload = "/upload" + base
        let rest: Substring
        if path.hasPrefix(upload) {
            rest = path.dropFirst(upload.count)
        } else if path.hasPrefix(base) {
            rest = path.dropFirst(base.count)
        } else {
            return error(404, "no such app")
        }
        if rest.isEmpty, method == "POST" {
            counter += 1
            let id = "edit-\(counter)"
            edits[id] = current
            return json(["id": id, "expiryTimeSeconds": "3600"])
        }
        let parts = rest.dropFirst().split(separator: "/").map(String.init)
        guard let first = parts.first else { return error(404, "no route") }
        if first.hasSuffix(":commit"), method == "POST" {
            let id = String(first.dropLast(":commit".count))
            guard let edit = edits.removeValue(forKey: id) else { return error(404, "edit not found") }
            current = edit
            commits.append(query)
            return json(["id": id])
        }
        guard var edit = edits[first] else { return error(404, "edit not found") }
        defer { if edits[first] != nil { edits[first] = edit } }
        let route = Array(parts.dropFirst())
        let language = route.count > 1 ? route[1] : ""
        let type = route.count > 2 ? PlayImageType(rawValue: route[2]) : nil
        switch (method, route.first ?? "", route.count) {
        case ("DELETE", "", 0):
            edits[first] = nil
            return (HTTPResponse(status: .noContent), Data())
        case ("GET", "details", 1):
            return json(["defaultLanguage": edit.defaultLanguage])
        case ("GET", "listings", 1):
            return encoded(Listings(listings: edit.listings.keys.sorted().map { edit.listings[$0]! }))
        case ("PUT", "listings", 2):
            guard var listing = try? JSONDecoder().decode(PlayListing.self, from: body) else { return error(400, "bad listing") }
            listing.language = language
            edit.listings[language] = listing
            return encoded(listing)
        case ("PATCH", "listings", 2):
            guard var listing = edit.listings[language] else { return error(404, "no listing for \(language)") }
            guard let text = try? JSONDecoder().decode(PlayListing.Text.self, from: body) else { return error(400, "bad listing") }
            listing.title = text.title ?? listing.title
            listing.shortDescription = text.shortDescription ?? listing.shortDescription
            listing.fullDescription = text.fullDescription ?? listing.fullDescription
            edit.listings[language] = listing
            return encoded(listing)
        case ("GET", "listings", 3):
            guard let type else { return error(400, "no such slot") }
            return encoded(Images(images: (edit.images[language]?[type] ?? []).map(Self.image)))
        case ("POST", "listings", 3):
            guard let type, query == "uploadType=media" else { return error(400, "bad upload") }
            counter += 1
            let image = Image(id: "image-\(counter)", data: body)
            edit.images[language, default: [:]][type, default: []].append(image)
            return encoded(Uploaded(image: Self.image(image)))
        case ("DELETE", "listings", 4):
            let id = route[3]
            guard let type, edit.images[language]?[type]?.contains(where: { $0.id == id }) == true else { return error(404, "no image \(id)") }
            edit.images[language]?[type]?.removeAll { $0.id == id }
            return (HTTPResponse(status: .noContent), Data())
        case ("GET", "tracks", 1):
            return encoded(Tracks(tracks: edit.tracks))
        default:
            return error(404, "no route \(method) \(path)")
        }
    }

    private struct Listings: Encodable { let listings: [PlayListing] }
    private struct Images: Encodable { let images: [PlayImage] }
    private struct Uploaded: Encodable { let image: PlayImage }
    private struct Tracks: Encodable { let tracks: [PlayTrack] }

    static func image(_ image: Image) -> PlayImage {
        PlayImage(id: image.id, sha256: SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined())
    }

    /// Grants a token to an assertion signed by the test key, for the
    /// Publishing API's scope.
    private func token(_ body: Data) -> (HTTPResponse, Data) {
        let form = String(decoding: body, as: UTF8.self)
        guard let assertion = form.split(separator: "&").first(where: { $0.hasPrefix("assertion=") })?.dropFirst("assertion=".count)
        else { return error(400, "no assertion") }
        let parts = assertion.split(separator: ".").map(String.init)
        guard parts.count == 3, let signature = Self.base64URL(parts[2]), let claims = Self.base64URL(parts[1]),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData,
                                    signature as CFData, nil),
              let object = try? JSONSerialization.jsonObject(with: claims) as? [String: Any],
              object["scope"] as? String == "https://www.googleapis.com/auth/androidpublisher",
              object["iss"] as? String == Self.clientEmail
        else { return error(400, "invalid_grant") }
        counter += 1
        return json(["access_token": "token-\(counter)", "expires_in": 3600, "token_type": "Bearer"])
    }

    private func json(_ object: [String: Any]) -> (HTTPResponse, Data) {
        (HTTPResponse(status: .ok), try! JSONSerialization.data(withJSONObject: object))
    }

    private func encoded(_ value: some Encodable) -> (HTTPResponse, Data) {
        (HTTPResponse(status: .ok), try! JSONEncoder().encode(value))
    }

    private func error(_ status: Int, _ message: String) -> (HTTPResponse, Data) {
        (HTTPResponse(status: .init(code: status)), try! JSONSerialization.data(withJSONObject: ["error": ["code": status, "message": message]]))
    }

    private static func base64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: - The test key

    public static let clientEmail = "publisher@example.iam.gserviceaccount.com"

    /// One RSA key for every test, made once: PKCS #1, DER.
    static let pkcs1: Data = {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        return SecKeyCopyExternalRepresentation(SecKeyCreateRandomKey(attributes as CFDictionary, nil)!, nil)! as Data
    }()

    /// A service account's JSON key around the test key, as the Google
    /// Cloud console downloads one.
    public static var serviceAccountJSON: Data {
        let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let pkcs8 = der(0x30, der(0x02, Data([0])) + der(0x30, Data(rsaEncryption)) + der(0x04, pkcs1))
        let pem = "-----BEGIN PRIVATE KEY-----\n" + pkcs8.base64EncodedString(options: .lineLength64Characters) + "\n-----END PRIVATE KEY-----\n"
        let object: [String: String] = [
            "type": "service_account", "project_id": "example", "private_key_id": "abc", "private_key": pem,
            "client_email": clientEmail, "token_uri": "https://oauth2.example/token",
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    public static var credentials: PlayCredentials {
        try! PlayCredentials(json: serviceAccountJSON, source: "the test key")
    }

    /// A DER element of `tag` holding `contents`.
    private static func der(_ tag: UInt8, _ contents: Data) -> Data {
        let count = contents.count
        let length: [UInt8] = count < 0x80 ? [UInt8(count)]
            : count <= 0xFF ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
        return Data([tag] + length) + contents
    }
}
