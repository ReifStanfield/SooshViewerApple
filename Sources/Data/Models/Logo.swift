import Foundation

/// A logo from `GET /api/channels/logos/`.
///
/// Channels reference logos by id only, so these are fetched once into a
/// lookup map rather than requested per card.
struct Logo: Identifiable, Hashable, Sendable, Decodable {
    let id: Int
    let name: String
    let url: String

    /// Server-side cached copy. Preferred over `url`, which points at the
    /// upstream provider and may be slow or dead.
    let cacheURL: String?

    /// Best URL to render, cache first.
    var bestURL: URL? {
        if let cacheURL, !cacheURL.isEmpty { return URL(string: cacheURL) }
        return URL(string: url)
    }

    /// Declaring `init(from:)` inside the struct suppresses the memberwise
    /// init, so this one exists for `CachedLogo` to rebuild from disk.
    init(id: Int, name: String, url: String, cacheURL: String?) {
        self.id = id
        self.name = name
        self.url = url
        self.cacheURL = cacheURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url
        case cacheURL = "cache_url"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.looseInt(.id) ?? 0
        name = container.looseString(.name) ?? ""
        url = container.looseString(.url) ?? ""
        cacheURL = container.looseString(.cacheURL)
    }
}
