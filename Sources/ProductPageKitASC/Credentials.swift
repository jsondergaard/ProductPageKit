public import CryptoKit
import Foundation
public import ProductPageKitCore

/// An App Store Connect API key: App Store Connect ▸ Users and Access ▸
/// Integrations. It needs App Manager access.
public struct Credentials: Sendable {
    public let issuerID: String
    public let keyID: String
    public let privateKey: P256.Signing.PrivateKey

    public init(issuerID: String, keyID: String, privateKey: P256.Signing.PrivateKey) {
        self.issuerID = issuerID
        self.keyID = keyID
        self.privateKey = privateKey
    }

    /// `ASC_ISSUER_ID`, `ASC_KEY_ID` and `ASC_KEY_PATH`, the `.p8` file.
    public init(environment: Environment) throws {
        let names = ["ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_KEY_PATH"]
        let missing = names.filter { environment[$0] == nil }
        guard missing.isEmpty else { throw CredentialsError.missing(missing) }
        let path = NSString(string: environment["ASC_KEY_PATH"]!).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw CredentialsError.noKeyFile(path) }
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw CredentialsError.unreadableKey(path)
        }
        issuerID = environment["ASC_ISSUER_ID"]!
        keyID = environment["ASC_KEY_ID"]!
    }
}

public enum CredentialsError: Error, CustomStringConvertible {
    case missing([String])
    case noKeyFile(String)
    case unreadableKey(String)

    public var description: String {
        switch self {
        case .missing(let names):
            "Missing \(names.joined(separator: ", ")). Put them in the repository's .env or export them. The key needs App Manager access."
        case .noKeyFile(let path):
            "ASC_KEY_PATH does not exist: \(path)"
        case .unreadableKey(let path):
            "ASC_KEY_PATH is not an App Store Connect .p8 key: \(path)"
        }
    }
}
