import CryptoKit
import Foundation

public enum ProjectCapabilityCommunitySourceError: Error, LocalizedError, Equatable {
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let message): return message
        }
    }
}

public struct ProjectCapabilityCommunitySource: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let url: String
    public let isEnabled: Bool
    public let addedAt: String?
    public let lastFetchedAt: String?
    public let lastContentHash: String?

    public init(
        id: String,
        name: String,
        url: String,
        isEnabled: Bool,
        addedAt: String? = nil,
        lastFetchedAt: String? = nil,
        lastContentHash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.addedAt = addedAt
        self.lastFetchedAt = lastFetchedAt
        self.lastContentHash = lastContentHash
    }

    public init(
        name: String,
        url: String,
        isEnabled: Bool = true,
        addedAt: String? = nil,
        lastFetchedAt: String? = nil,
        lastContentHash: String? = nil
    ) throws {
        let validated = try Self.validatedURL(url)
        let normalized = validated.absoluteString
        self.init(
            id: Self.id(for: normalized),
            name: name,
            url: normalized,
            isEnabled: isEnabled,
            addedAt: addedAt,
            lastFetchedAt: lastFetchedAt,
            lastContentHash: lastContentHash
        )
    }

    public static func validatedURL(_ raw: String) throws -> URL {
        guard raw.count <= 2048,
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              !blockedHost(host),
              let url = components.url else {
            throw ProjectCapabilityCommunitySourceError.invalidURL("社区源必须是有效的 HTTPS URL，且不能指向本机或私有地址")
        }
        return url
    }

    private static func blockedHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let first = parts[0]
        let second = parts[1]
        if first == 10 || first == 127 || first == 0 { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        return false
    }

    private static func id(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
